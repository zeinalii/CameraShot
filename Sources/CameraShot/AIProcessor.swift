import Foundation

// MARK: - AIConfig

struct AIConfig {
    var enabled: Bool   = true
    var prompt:  String = "try to solve this question that you see on the screen."
    var model:   String = "claude-sonnet-4-5"
}

// MARK: - AIProcessor

/// Calls the Anthropic Messages API directly over HTTPS using URLSession.
/// No Python, no subprocesses, no external dependencies.
/// Limits concurrent requests to avoid pile-up at fast capture intervals.
final class AIProcessor {

    var onResult: ((String, URL) -> Void)?
    var onStreamChunk: ((String, URL) -> Void)?
    var onError:  ((String, URL?) -> Void)?

    private let config: AIConfig
    private let apiKey: String?
    private let session = URLSession(configuration: .ephemeral)
    private let limiter: RequestLimiter

    init(config: AIConfig, apiKey: String?, maxConcurrentRequests: Int = 1) {
        self.config = config
        self.apiKey = apiKey
        self.limiter = RequestLimiter(maxConcurrent: max(1, maxConcurrentRequests))
    }

    func process(imageURL: URL) {
        guard config.enabled else { return }
        Task {
            await limiter.acquire()
            defer { Task { await limiter.release() } }
            await run(imageURL: imageURL)
        }
    }

    // MARK: – Private

    private func run(imageURL: URL) async {
        guard let key = apiKey, !key.isEmpty else {
            finish(.error("No API key — add your Anthropic key in the API Keys tab.", imageURL))
            return
        }
        guard let imageData = try? Data(contentsOf: imageURL) else {
            finish(.error("Could not read screenshot at \(imageURL.lastPathComponent)", imageURL))
            return
        }

        let ext      = imageURL.pathExtension.lowercased()
        let mimeType = ext == "png" ? "image/png" : "image/jpeg"
        let b64      = imageData.base64EncodedString()

        let body: [String: Any] = [
            "model":      config.model,
            "max_tokens": 2048,
            "stream":     true,
            "system":     "Format your entire response in Markdown. Use ## headers, **bold**, `inline code`, fenced code blocks, and - bullet lists where appropriate. Never respond with plain paragraphs only.",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": mimeType, "data": b64]],
                    ["type": "text", "text": config.prompt],
                ],
            ]],
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            finish(.error("Failed to serialize request body.", imageURL)); return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key,              forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",     forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload

        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var errData = Data()
                for try await b in bytes { errData.append(b) }
                let msg = (try? JSONSerialization.jsonObject(with: errData) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                    ?? "HTTP \(status)"
                finish(.error("Anthropic error: \(msg)", imageURL)); return
            }
            var buffer = [UInt8]()
            var fullText = ""
            for try await byte in bytes {
                buffer.append(byte)
                if byte == 10 {
                    let line = String(bytes: buffer, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    buffer = []
                    if line.hasPrefix("data: ") {
                        let jsonStr = String(line.dropFirst(6))
                        guard !jsonStr.isEmpty,
                              let data = jsonStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        if type == "content_block_delta",
                           let delta = obj["delta"] as? [String: Any],
                           (delta["type"] as? String) == "text_delta",
                           let text = delta["text"] as? String {
                            fullText += text
                            let streamHandler = onStreamChunk
                            DispatchQueue.main.async {
                                streamHandler?(text, imageURL)
                            }
                        } else if type == "message_stop" {
                            break
                        } else if type == "error", let err = obj["error"] as? [String: Any] {
                            let msg = err["message"] as? String ?? "Stream error"
                            finish(.error(msg, imageURL)); return
                        }
                    }
                }
            }
            finish(.result(fullText, imageURL))
        } catch {
            finish(.error("Network error: \(error.localizedDescription)", imageURL))
        }
    }

    // MARK: – Helpers

    private enum Outcome { case result(String, URL); case error(String, URL?) }

    private func finish(_ outcome: Outcome) {
        let resultHandler = onResult
        let errorHandler = onError
        DispatchQueue.main.async {
            switch outcome {
            case .result(let text, let url):
                resultHandler?(text, url)
            case .error(let msg, let imageURL):
                errorHandler?(msg, imageURL)
            }
        }
    }
}

// MARK: - RequestLimiter

private actor RequestLimiter {
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent: Int

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        inFlight += 1
    }

    func release() {
        inFlight -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}

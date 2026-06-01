import Foundation

// MARK: - GeminiAPI

enum GeminiAPI {
    static let defaultModel = "gemini-3.5-flash"

    static func compatibleModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultModel }

        let lowercased = trimmed.lowercased()
        if lowercased == "gemini-3-5-flash" ||
            lowercased.hasPrefix("claude") ||
            lowercased.contains("sonnet") ||
            lowercased.contains("opus") ||
            lowercased.contains("haiku") {
            return defaultModel
        }

        return trimmed
    }

    static func streamURL(model: String, apiKey: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/v1beta/models/\(normalizedModel(model)):streamGenerateContent"
        components.queryItems = [
            URLQueryItem(name: "alt", value: "sse"),
        ]
        return components.url
    }

    static func textDelta(from object: [String: Any]) -> String? {
        guard let candidates = object["candidates"] as? [[String: Any]] else { return nil }
        let text = candidates.compactMap { candidate -> String? in
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return nil }
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }.joined()
        return text.isEmpty ? nil : text
    }

    static func googleSearchTools() -> [[String: Any]] {
        [["google_search": [String: Any]()] as [String: Any]]
    }

    static func errorMessage(from object: [String: Any]) -> String? {
        guard let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return errorMessage(from: object)
    }

    private static func normalizedModel(_ model: String) -> String {
        let name = compatibleModel(model)
        return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
    }
}

// MARK: - AIConfig

struct AIConfig {
    var enabled: Bool   = true
    var prompt:  String = "try to solve this question that you see on the screen."
    var model:   String = GeminiAPI.defaultModel
}

// MARK: - AIProcessor

/// Calls the Gemini Generate Content API directly over HTTPS using URLSession.
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
            finish(.error("No API key — add your Google Gemini key in the API Keys tab.", imageURL))
            return
        }
        guard let imageData = try? Data(contentsOf: imageURL) else {
            finish(.error("Could not read screenshot at \(imageURL.lastPathComponent)", imageURL))
            return
        }

        let ext      = imageURL.pathExtension.lowercased()
        let mimeType = ext == "png" ? "image/png" : "image/jpeg"
        let b64      = imageData.base64EncodedString()

        let userParts: [[String: Any]] = [
            ["inline_data": ["mime_type": mimeType, "data": b64]],
            ["text": config.prompt],
        ]
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [[
                    "text": "Format your entire response in Markdown. Use ## headers, **bold**, `inline code`, fenced code blocks, and - bullet lists where appropriate. Never respond with plain paragraphs only. If the question depends on current facts, recent events, prices, schedules, rules, or other information that may have changed, use Google Search grounding silently before answering. Do not mention search, search queries, sources, citations, or tool use unless the user explicitly asks for them. Show only the final answer.",
                ]],
            ],
            "contents": [[
                "role": "user",
                "parts": userParts,
            ]],
            "tools": GeminiAPI.googleSearchTools(),
            "generationConfig": [
                "maxOutputTokens": 2048,
                "thinkingConfig": [
                    "thinkingLevel": "high",
                ],
            ],
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            finish(.error("Failed to serialize request body.", imageURL)); return
        }
        guard let url = GeminiAPI.streamURL(model: config.model, apiKey: key) else {
            finish(.error("Failed to build Gemini request URL.", imageURL)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload

        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var errData = Data()
                for try await b in bytes { errData.append(b) }
                let msg = GeminiAPI.errorMessage(from: errData) ?? "HTTP \(status)"
                finish(.error("Gemini error: \(msg)", imageURL)); return
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
                        guard jsonStr != "[DONE]" else { break }
                        guard !jsonStr.isEmpty,
                              let data = jsonStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let msg = GeminiAPI.errorMessage(from: obj) {
                            finish(.error("Gemini error: \(msg)", imageURL)); return
                        }
                        if let text = GeminiAPI.textDelta(from: obj) {
                            fullText += text
                            let streamHandler = onStreamChunk
                            DispatchQueue.main.async {
                                streamHandler?(text, imageURL)
                            }
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

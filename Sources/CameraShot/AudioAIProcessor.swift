import Foundation

// MARK: - AudioAIProcessor

/// Sends the last chunk of live transcript text to Claude and streams the response back.
/// Mirrors AIProcessor but takes plain text instead of an image.
final class AudioAIProcessor: @unchecked Sendable {

    // MARK: – Callbacks (always on main thread)

    var onChunk: ((String) -> Void)?
    var onDone:  (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: – Init

    private let apiKey:       String
    private let systemPrompt: String
    private let session = URLSession(configuration: .ephemeral)
    private var inFlight = false

    init(apiKey: String, systemPrompt: String) {
        self.apiKey       = apiKey
        self.systemPrompt = systemPrompt
    }

    // MARK: – Public

    /// Sends `transcript` to Claude and streams the response via `onChunk` / `onDone` / `onError`.
    /// Returns `true` when the request is accepted, `false` when dropped (empty/in-flight).
    @discardableResult
    func query(transcript: String) -> Bool {
        guard !inFlight else { return false }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        inFlight = true
        Task { await run(transcript: transcript) }
        return true
    }

    // MARK: – Private

    private func run(transcript: String) async {
        defer { DispatchQueue.main.async { self.inFlight = false } }

        let body: [String: Any] = [
            "model":      "claude-sonnet-4-5",
            "max_tokens": 1024,
            "stream":     true,
            "system":     systemPrompt,
            "messages": [[
                "role": "user",
                "content": "Here is the recent transcript:\n\n\(transcript)\n\nPlease respond."
            ]],
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            fire { self.onError?("Failed to build request.") }; return
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = payload

        do {
            let (bytes, response) = try await session.bytes(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var errData = Data()
                for try await b in bytes { errData.append(b) }
                let msg = (try? JSONSerialization.jsonObject(with: errData) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                    ?? "HTTP \(status)"
                fire { self.onError?("Claude error: \(msg)") }; return
            }

            var buffer = [UInt8]()
            for try await byte in bytes {
                buffer.append(byte)
                if byte == 10 {  // newline
                    let line = String(bytes: buffer, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    buffer = []
                    guard line.hasPrefix("data: ") else { continue }
                    let jsonStr = String(line.dropFirst(6))
                    guard !jsonStr.isEmpty,
                          let data = jsonStr.data(using: .utf8),
                          let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let type = obj["type"] as? String else { continue }

                    if type == "content_block_delta",
                       let delta = obj["delta"] as? [String: Any],
                       (delta["type"] as? String) == "text_delta",
                       let text = delta["text"] as? String {
                        fire { self.onChunk?(text) }
                    } else if type == "message_stop" {
                        fire { self.onDone?() }
                        return
                    } else if type == "error",
                              let err = obj["error"] as? [String: Any] {
                        let msg = err["message"] as? String ?? "Stream error"
                        fire { self.onError?(msg) }; return
                    }
                }
            }
            fire { self.onDone?() }
        } catch {
            fire { self.onError?("Network error: \(error.localizedDescription)") }
        }
    }

    private func fire(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

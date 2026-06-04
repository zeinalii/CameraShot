import Foundation

// MARK: - AudioAIProcessor

/// Sends the last chunk of live transcript text to Gemini and streams the response back.
/// Mirrors AIProcessor but takes plain text instead of an image.
final class AudioAIProcessor: @unchecked Sendable {

    // MARK: – Callbacks (always on main thread)

    var onChunk: ((String) -> Void)?
    var onDone:  (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: – Init

    private let apiKey:       String
    private let model:        String
    private let systemPrompt: String
    private let session = URLSession(configuration: .ephemeral)
    private var inFlight = false

    init(apiKey: String, model: String = GeminiAPI.defaultModel, systemPrompt: String) {
        self.apiKey       = apiKey
        self.model        = model
        self.systemPrompt = systemPrompt
    }

    // MARK: – Public

    /// Sends `transcript` to Gemini and streams the response via `onChunk` / `onDone` / `onError`.
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

        let userParts: [[String: Any]] = [[
            "text": "Here is the recent transcript:\n\n\(transcript)\n\nPlease respond.",
        ]]
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [[
                    "text": "\(systemPrompt)\n\nIf the user question depends on current facts, recent events, prices, schedules, rules, or other information that may have changed, use Google Search grounding silently before answering. Do not mention search, search queries, sources, citations, or tool use unless the user explicitly asks for them. Show only the final answer.",
                ]],
            ],
            "contents": [[
                "role": "user",
                "parts": userParts,
            ]],
            "tools": GeminiAPI.googleSearchTools(),
            "generationConfig": [
                "maxOutputTokens": 1024,
                "thinkingConfig": [
                    "thinkingLevel": "high",
                ],
            ],
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            fire { self.onError?("Failed to build request.") }; return
        }
        guard let url = GeminiAPI.streamURL(model: model) else {
            fire { self.onError?("Failed to build Gemini request URL.") }; return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = payload

        do {
            let (bytes, response) = try await session.bytes(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var errData = Data()
                for try await b in bytes { errData.append(b) }
                let msg = GeminiAPI.errorMessage(from: errData) ?? "HTTP \(status)"
                fire { self.onError?("Gemini error: \(msg)") }; return
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
                    guard jsonStr != "[DONE]" else { break }
                    guard !jsonStr.isEmpty,
                          let data = jsonStr.data(using: .utf8),
                          let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    if let msg = GeminiAPI.errorMessage(from: obj) {
                        fire { self.onError?("Gemini error: \(msg)") }; return
                    }
                    if let text = GeminiAPI.textDelta(from: obj) {
                        fire { self.onChunk?(text) }
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

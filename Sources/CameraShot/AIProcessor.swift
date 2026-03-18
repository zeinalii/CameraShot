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
final class AIProcessor {

    var onResult: ((String, URL) -> Void)?
    var onError:  ((String) -> Void)?

    private let config: AIConfig
    private let apiKey: String?
    private let session = URLSession(configuration: .ephemeral)

    init(config: AIConfig, apiKey: String?) {
        self.config = config
        self.apiKey = apiKey
    }

    func process(imageURL: URL) {
        guard config.enabled else { return }
        Task { await run(imageURL: imageURL) }
    }

    // MARK: – Private

    private func run(imageURL: URL) async {
        guard let key = apiKey, !key.isEmpty else {
            finish(.error("No API key — add your Anthropic key in the API Keys tab."))
            return
        }
        guard let imageData = try? Data(contentsOf: imageURL) else {
            finish(.error("Could not read screenshot at \(imageURL.lastPathComponent)"))
            return
        }

        let ext      = imageURL.pathExtension.lowercased()
        let mimeType = ext == "png" ? "image/png" : "image/jpeg"
        let b64      = imageData.base64EncodedString()

        let body: [String: Any] = [
            "model":      config.model,
            "max_tokens": 2048,
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
            finish(.error("Failed to serialize request body.")); return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key,              forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",     forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                finish(.error("Invalid JSON response (HTTP \(status)).")); return
            }

            if status != 200 {
                let msg = (json["error"] as? [String: Any])?["message"] as? String
                            ?? "HTTP \(status)"
                finish(.error("Anthropic error: \(msg)")); return
            }

            guard
                let content = (json["content"] as? [[String: Any]])?.first,
                let text    = content["text"] as? String
            else {
                finish(.error("Unexpected response shape.")); return
            }

            finish(.result(text, imageURL))
        } catch {
            finish(.error("Network error: \(error.localizedDescription)"))
        }
    }

    // MARK: – Helpers

    private enum Outcome { case result(String, URL); case error(String) }

    private func finish(_ outcome: Outcome) {
        DispatchQueue.main.async { [weak self] in
            switch outcome {
            case .result(let text, let url): self?.onResult?(text, url)
            case .error(let msg):            self?.onError?(msg)
            }
        }
    }
}

import Foundation

// MARK: - GPTChatController

final class GPTChatController: @unchecked Sendable {
    static let model = "gpt-5.5"

    var onChunk: ((String) -> Void)?
    var onDone: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let stateLock = NSLock()

    private var previousResponseID: String?
    private var activeTask: Task<Void, Never>?
    private var generation = 0

    init(apiKey: String, model: String = GPTChatController.model) {
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func send(_ message: String, attachmentURL: URL? = nil) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let requestState: (generation: Int, previousResponseID: String?)?
        stateLock.lock()
        if activeTask != nil {
            requestState = nil
        } else {
            requestState = (generation, previousResponseID)
        }
        stateLock.unlock()

        guard let requestState else {
            fire { self.onError?("Chat is still responding. Wait for the current reply or restart the session.") }
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                self.fire { self.onStatus?("Sending message to GPT-5.5...") }
                let completedID = try await self.run(
                    message: trimmed,
                    attachmentURL: attachmentURL,
                    previousResponseID: requestState.previousResponseID
                )
                guard self.isCurrentGeneration(requestState.generation) else { return }
                self.locked {
                    self.previousResponseID = completedID
                    self.activeTask = nil
                }
                self.fire {
                    self.onStatus?("Ready.")
                    self.onDone?()
                }
            } catch is CancellationError {
                self.locked {
                    if self.generation == requestState.generation {
                        self.activeTask = nil
                    }
                }
            } catch {
                guard self.isCurrentGeneration(requestState.generation) else { return }
                self.locked { self.activeTask = nil }
                self.fire {
                    self.onStatus?("Chat failed.")
                    self.onError?(error.localizedDescription)
                }
            }
        }

        locked { activeTask = task }
    }

    func restart() {
        let task: Task<Void, Never>? = locked {
            generation += 1
            previousResponseID = nil
            let current = activeTask
            activeTask = nil
            return current
        }
        task?.cancel()
        fire { self.onStatus?("Chat session restarted.") }
    }

    func cancel() {
        let task: Task<Void, Never>? = locked {
            generation += 1
            previousResponseID = nil
            let current = activeTask
            activeTask = nil
            return current
        }
        task?.cancel()
    }

    private func run(message: String, attachmentURL: URL?, previousResponseID: String?) async throws -> String {
        var content: [[String: Any]] = [[
            "type": "input_text",
            "text": message,
        ]]
        if let attachmentURL {
            let attachment = try Self.imageAttachment(from: attachmentURL)
            content.append([
                "type": "input_image",
                "image_url": attachment.dataURL,
            ])
            DevLog.log(
                "Chat",
                "prepared image attachment file=\(attachmentURL.lastPathComponent) mime=\(attachment.mimeType) bytes=\(attachment.byteCount)"
            )
        }

        var body: [String: Any] = [
            "model": model,
            "instructions": Self.systemInstruction,
            "input": [[
                "role": "user",
                "content": content,
            ]],
            "stream": true,
            "store": true,
            "max_output_tokens": 4096,
            "reasoning": [
                "effort": "medium",
            ],
            "text": [
                "verbosity": "medium",
            ],
        ]
        if let previousResponseID {
            body["previous_response_id"] = previousResponseID
        }

        guard let payload = try? JSONSerialization.data(withJSONObject: body),
              let url = OpenAIAPI.responsesURL else {
            throw GPTChatError.requestBuildFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        DevLog.log(
            "Chat",
            "HTTP request model=\(model) previousResponseID=\(previousResponseID ?? "nil") payloadBytes=\(payload.count)"
        )
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        DevLog.log("Chat", "HTTP status=\(status)")
        guard status == 200 else {
            var errData = Data()
            for try await byte in bytes {
                guard errData.count < RetentionPolicy.httpErrorBodyLimitBytes else { break }
                errData.append(byte)
            }
            let message = OpenAIAPI.errorMessage(from: errData) ?? "HTTP \(status)"
            throw GPTChatError.http(status, message)
        }

        var emittedText = false
        var completedID: String?
        var completed = false
        var lineBuffer = [UInt8]()

        for try await byte in bytes {
            try Task.checkCancellation()
            lineBuffer.append(byte)
            guard lineBuffer.count <= RetentionPolicy.sseLineBufferLimitBytes else {
                throw GPTChatError.stream("SSE line exceeded the memory safety limit.")
            }
            guard byte == 10 else { continue }

            let line = String(bytes: lineBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lineBuffer = []
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }
            guard !jsonString.isEmpty,
                  let data = jsonString.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let type = object["type"] as? String
            if type == "error" || type == "response.failed" || type == "response.incomplete" {
                let message = OpenAIAPI.errorMessage(from: object) ?? "OpenAI chat stream failed."
                DevLog.log("Chat", "SSE failure type=\(type ?? "nil") message=\(message)")
                throw GPTChatError.stream(message)
            }

            if let text = OpenAIAPI.textDelta(from: object), !text.isEmpty {
                emittedText = true
                fire { self.onChunk?(text) }
            }

            if type == "response.created", completedID == nil {
                completedID = Self.responseID(from: object)
            }

            if type == "response.completed" {
                completed = true
                completedID = Self.responseID(from: object)
                DevLog.log("Chat", "SSE completed responseID=\(completedID ?? "nil")")
                break
            }
        }

        guard emittedText else {
            throw GPTChatError.emptyResponse
        }
        if !completed {
            DevLog.log("Chat", "SSE ended without response.completed; using responseID=\(completedID ?? "nil")")
        }
        guard let completedID else {
            throw GPTChatError.stream("Response finished without a reusable conversation ID.")
        }
        return completedID
    }

    private static func responseID(from object: [String: Any]) -> String? {
        if let response = object["response"] as? [String: Any],
           let id = response["id"] as? String {
            return id
        }
        return object["response_id"] as? String
    }

    private static func imageAttachment(from url: URL) throws -> (dataURL: String, mimeType: String, byteCount: Int) {
        let ext = url.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "png":
            mimeType = "image/png"
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        default:
            throw GPTChatError.unsupportedAttachment(url.lastPathComponent)
        }

        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                throw GPTChatError.unreadableAttachment(url.lastPathComponent)
            }
            return (
                dataURL: "data:\(mimeType);base64,\(data.base64EncodedString())",
                mimeType: mimeType,
                byteCount: data.count
            )
        } catch let error as GPTChatError {
            throw error
        } catch {
            throw GPTChatError.unreadableAttachment(url.lastPathComponent)
        }
    }

    private func isCurrentGeneration(_ value: Int) -> Bool {
        locked { generation == value }
    }

    private func locked<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    private func fire(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private static let systemInstruction =
        "You are ChatGPT inside the CameraShot app. Answer helpfully and directly. Format responses in Markdown when structure helps. Keep context across this chat session, and do not mention implementation details unless asked."
}

enum GPTChatError: LocalizedError {
    case emptyResponse
    case http(Int, String)
    case requestBuildFailed
    case stream(String)
    case unreadableAttachment(String)
    case unsupportedAttachment(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "GPT-5.5 returned an empty response."
        case .http(let status, let message):
            return "OpenAI chat HTTP \(status): \(message)"
        case .requestBuildFailed:
            return "Failed to build the OpenAI chat request."
        case .stream(let message):
            return message
        case .unreadableAttachment(let filename):
            return "Could not read screenshot attachment \(filename)."
        case .unsupportedAttachment(let filename):
            return "Screenshot attachment \(filename) is not a PNG or JPEG."
        }
    }
}

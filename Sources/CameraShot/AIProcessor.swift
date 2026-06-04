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

    static func streamURL(model: String) -> URL? {
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

// MARK: - OpenAIAPI

enum OpenAIAPI {
    static let fallbackModel = "gpt-5.3-codex"

    static var responsesURL: URL? {
        URL(string: "https://api.openai.com/v1/responses")
    }

    static func textDelta(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "response.output_text.delta" else { return nil }
        return object["delta"] as? String
    }

    static func errorMessage(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String
        }
        if let response = object["response"] as? [String: Any],
           let error = response["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return nil
    }

    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return errorMessage(from: object)
    }
}

// MARK: - AIConfig

struct AIConfig {
    var enabled: Bool   = true
    var prompt:  String = "try to solve this question that you see on the screen."
    var model:   String = GeminiAPI.defaultModel
}

// MARK: - Provider events/errors

enum AIProviderEvent {
    case textDelta(String)
    case completed
}

enum AIProviderError: LocalizedError {
    case emptyResponse(AIProviderID)
    case http(AIProviderID, Int, String)
    case requestBuildFailed(AIProviderID)
    case malformedStream(AIProviderID)
    case network(AIProviderID, String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse(let provider):
            return "\(provider.displayName) returned an empty response."
        case .http(let provider, let status, let message):
            return "\(provider.displayName) HTTP \(status): \(message)"
        case .requestBuildFailed(let provider):
            return "Failed to build \(provider.displayName) request."
        case .malformedStream(let provider):
            return "\(provider.displayName) returned a malformed stream."
        case .network(let provider, let message):
            return "\(provider.displayName) network error: \(message)"
        }
    }
}

protocol AIProviderClient: Sendable {
    var providerID: AIProviderID { get }
    func streamScreenshotAnalysis(
        imageData: Data,
        mimeType: String,
        prompt: String
    ) -> AsyncThrowingStream<AIProviderEvent, Error>
}

// MARK: - Provider clients

private final class GeminiProviderClient: AIProviderClient, @unchecked Sendable {
    let providerID: AIProviderID = .gemini

    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
    }

    func streamScreenshotAnalysis(
        imageData: Data,
        mimeType: String,
        prompt: String
    ) -> AsyncThrowingStream<AIProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    DevLog.log("Provider", "Gemini stream start bytes=\(imageData.count) mime=\(mimeType) model=\(self.model)")
                    let stream = try await self.openStream(imageData: imageData, mimeType: mimeType, prompt: prompt)
                    var emittedText = false
                    for try await event in stream {
                        switch event {
                        case .textDelta(let text):
                            if !text.isEmpty { emittedText = true }
                            continuation.yield(event)
                        case .completed:
                            break
                        }
                    }
                    guard emittedText else {
                        DevLog.log("Provider", "Gemini empty response")
                        throw AIProviderError.emptyResponse(self.providerID)
                    }
                    DevLog.log("Provider", "Gemini stream completed emittedText=1")
                    continuation.yield(.completed)
                    continuation.finish()
                } catch let error as AIProviderError {
                    DevLog.log("Provider", "Gemini stream failed error=\(error.localizedDescription)")
                    continuation.finish(throwing: error)
                } catch {
                    DevLog.log("Provider", "Gemini stream network failed error=\(error.localizedDescription)")
                    continuation.finish(throwing: AIProviderError.network(self.providerID, error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func openStream(
        imageData: Data,
        mimeType: String,
        prompt: String
    ) async throws -> AsyncThrowingStream<AIProviderEvent, Error> {
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [[
                    "text": Self.systemInstruction,
                ]],
            ],
            "contents": [[
                "role": "user",
                "parts": [
                    ["inline_data": ["mime_type": mimeType, "data": imageData.base64EncodedString()]],
                    ["text": prompt],
                ],
            ]],
            "tools": GeminiAPI.googleSearchTools(),
            "generationConfig": [
                "maxOutputTokens": 2048,
                "thinkingConfig": [
                    "thinkingLevel": "medium",
                ],
            ],
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body),
              let url = GeminiAPI.streamURL(model: model) else {
            throw AIProviderError.requestBuildFailed(providerID)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload

        DevLog.log("Provider", "Gemini HTTP request url=\(url.absoluteString) payloadBytes=\(payload.count)")
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        DevLog.log("Provider", "Gemini HTTP status=\(status)")
        guard status == 200 else {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let msg = GeminiAPI.errorMessage(from: errData) ?? "HTTP \(status)"
            throw AIProviderError.http(providerID, status, msg)
        }

        return Self.parseSSEBytes(bytes, providerID: providerID)
    }

    private static func parseSSEBytes(
        _ bytes: URLSession.AsyncBytes,
        providerID: AIProviderID
    ) -> AsyncThrowingStream<AIProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = [UInt8]()
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 10 {
                            let line = String(bytes: buffer, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            buffer = []
                            guard line.hasPrefix("data: ") else { continue }
                            let jsonStr = String(line.dropFirst(6))
                            guard jsonStr != "[DONE]" else { break }
                            guard !jsonStr.isEmpty,
                                  let data = jsonStr.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                continue
                            }
                            if let msg = GeminiAPI.errorMessage(from: obj) {
                                throw AIProviderError.http(providerID, 200, msg)
                            }
                            if let text = GeminiAPI.textDelta(from: obj) {
                                DevLog.log("Provider", "Gemini SSE delta chars=\(text.count)")
                                continuation.yield(.textDelta(text))
                            }
                        }
                    }
                    DevLog.log("Provider", "Gemini SSE completed")
                    continuation.yield(.completed)
                    continuation.finish()
                } catch let error as AIProviderError {
                    DevLog.log("Provider", "Gemini SSE failed error=\(error.localizedDescription)")
                    continuation.finish(throwing: error)
                } catch {
                    DevLog.log("Provider", "Gemini SSE network failed error=\(error.localizedDescription)")
                    continuation.finish(throwing: AIProviderError.network(providerID, error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    fileprivate static let systemInstruction =
        "Format your entire response in Markdown. Use ## headers, **bold**, `inline code`, fenced code blocks, and - bullet lists where appropriate. Never respond with plain paragraphs only. If the question depends on current facts, recent events, prices, schedules, rules, or other information that may have changed, use Google Search grounding silently before answering. Do not mention search, search queries, sources, citations, or tool use unless the user explicitly asks for them. Show only the final answer."
}

private final class OpenAIProviderClient: AIProviderClient, @unchecked Sendable {
    let providerID: AIProviderID = .openAI

    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String = OpenAIAPI.fallbackModel) {
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
    }

    func streamScreenshotAnalysis(
        imageData: Data,
        mimeType: String,
        prompt: String
    ) -> AsyncThrowingStream<AIProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    DevLog.log("Provider", "OpenAI stream start bytes=\(imageData.count) mime=\(mimeType) model=\(self.model)")
                    try await self.run(imageData: imageData, mimeType: mimeType, prompt: prompt, continuation: continuation)
                } catch let error as AIProviderError {
                    DevLog.log("Provider", "OpenAI stream failed error=\(error.localizedDescription)")
                    continuation.finish(throwing: error)
                } catch {
                    DevLog.log("Provider", "OpenAI stream network failed error=\(error.localizedDescription)")
                    continuation.finish(throwing: AIProviderError.network(self.providerID, error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        imageData: Data,
        mimeType: String,
        prompt: String,
        continuation: AsyncThrowingStream<AIProviderEvent, Error>.Continuation
    ) async throws {
        let imageURL = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
        let body: [String: Any] = [
            "model": model,
            "instructions": GeminiProviderClient.systemInstruction,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": prompt],
                    ["type": "input_image", "image_url": imageURL],
                ],
            ]],
            "stream": true,
            "max_output_tokens": 2048,
            "reasoning": [
                "effort": "medium",
            ],
            "text": [
                "verbosity": "low",
            ],
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body),
              let url = OpenAIAPI.responsesURL else {
            throw AIProviderError.requestBuildFailed(providerID)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        DevLog.log("Provider", "OpenAI HTTP request model=\(model) payloadBytes=\(payload.count)")
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        DevLog.log("Provider", "OpenAI HTTP status=\(status)")
        guard status == 200 else {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let msg = OpenAIAPI.errorMessage(from: errData) ?? "HTTP \(status)"
            throw AIProviderError.http(providerID, status, msg)
        }

        var emittedText = false
        var completed = false
        var buffer = [UInt8]()
        for try await byte in bytes {
            buffer.append(byte)
            if byte == 10 {
                let line = String(bytes: buffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                buffer = []
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard jsonStr != "[DONE]" else { break }
                guard !jsonStr.isEmpty,
                      let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let type = obj["type"] as? String
                if type == "error" || type == "response.failed" {
                    let msg = OpenAIAPI.errorMessage(from: obj) ?? "OpenAI stream failed."
                    DevLog.log("Provider", "OpenAI SSE failureEvent type=\(type ?? "nil") message=\(msg)")
                    throw AIProviderError.http(providerID, status, msg)
                }
                if let text = OpenAIAPI.textDelta(from: obj) {
                    emittedText = true
                    DevLog.log("Provider", "OpenAI SSE delta chars=\(text.count)")
                    continuation.yield(.textDelta(text))
                }
                if type == "response.completed" {
                    completed = true
                    DevLog.log("Provider", "OpenAI SSE completed event")
                    break
                }
            }
        }

        guard emittedText else {
            DevLog.log("Provider", "OpenAI empty response")
            throw AIProviderError.emptyResponse(providerID)
        }
        DevLog.log("Provider", "OpenAI stream completed emittedText=1 completedEvent=\(completed ? 1 : 0)")
        if !completed {
            continuation.yield(.completed)
        } else {
            continuation.yield(.completed)
        }
        continuation.finish()
    }
}

// MARK: - Callback box

private final class VisualAICallbackBox: @unchecked Sendable {
    var onProcessingStarted: ((URL, Int, Int) -> Void)?
    var onStatus: ((String, URL) -> Void)?
    var onStreamChunk: ((String, URL) -> Void)?
    var onReplaceResponse: ((String, URL) -> Void)?
    var onResult: ((String, URL) -> Void)?
    var onError: ((String, URL?) -> Void)?
    var onDiscard: ((URL) -> Void)?

    func processingStarted(imageURL: URL, retryIndex: Int, maxRetries: Int) {
        DispatchQueue.main.async {
            self.onProcessingStarted?(imageURL, retryIndex, maxRetries)
        }
    }

    func status(_ message: String, imageURL: URL) {
        DispatchQueue.main.async {
            self.onStatus?(message, imageURL)
        }
    }

    func stream(_ text: String, imageURL: URL) {
        DispatchQueue.main.async {
            self.onStreamChunk?(text, imageURL)
        }
    }

    func replace(_ text: String, imageURL: URL) {
        DispatchQueue.main.async {
            self.onReplaceResponse?(text, imageURL)
        }
    }

    func result(_ text: String, imageURL: URL) {
        DispatchQueue.main.async {
            self.onResult?(text, imageURL)
        }
    }

    func error(_ message: String, imageURL: URL?) {
        DispatchQueue.main.async {
            self.onError?(message, imageURL)
        }
    }

    func discard(imageURL: URL) {
        DispatchQueue.main.async {
            self.onDiscard?(imageURL)
        }
    }
}

// MARK: - AIProcessor

/// Latest-only visual AI processor with Gemini primary and optional OpenAI hedged fallback.
final class AIProcessor: @unchecked Sendable {
    var onProcessingStarted: ((URL, Int, Int) -> Void)? {
        get { callbacks.onProcessingStarted }
        set { callbacks.onProcessingStarted = newValue }
    }
    var onStatus: ((String, URL) -> Void)? {
        get { callbacks.onStatus }
        set { callbacks.onStatus = newValue }
    }
    var onResult: ((String, URL) -> Void)? {
        get { callbacks.onResult }
        set { callbacks.onResult = newValue }
    }
    var onStreamChunk: ((String, URL) -> Void)? {
        get { callbacks.onStreamChunk }
        set { callbacks.onStreamChunk = newValue }
    }
    var onReplaceResponse: ((String, URL) -> Void)? {
        get { callbacks.onReplaceResponse }
        set { callbacks.onReplaceResponse = newValue }
    }
    var onError: ((String, URL?) -> Void)? {
        get { callbacks.onError }
        set { callbacks.onError = newValue }
    }
    var onDiscard: ((URL) -> Void)? {
        get { callbacks.onDiscard }
        set { callbacks.onDiscard = newValue }
    }

    private let callbacks = VisualAICallbackBox()
    private let orchestrator: VisualAIOrchestrator

    init(config: AIConfig, credentials: AICredentials) {
        DevLog.log(
            "VisualAI",
            "AIProcessor init enabled=\(config.enabled ? 1 : 0) model=\(config.model) geminiKey=\((credentials.geminiAPIKey?.isEmpty == false) ? 1 : 0) openAIKey=\((credentials.openAIAPIKey?.isEmpty == false) ? 1 : 0)"
        )
        let geminiClient = credentials.geminiAPIKey.map {
            GeminiProviderClient(apiKey: $0, model: config.model)
        }
        let openAIClient = credentials.openAIAPIKey.map {
            OpenAIProviderClient(apiKey: $0)
        }
        orchestrator = VisualAIOrchestrator(
            config: config,
            geminiClient: geminiClient,
            openAIClient: openAIClient,
            callbacks: callbacks
        )
    }

    func process(imageURL: URL) {
        DevLog.log("VisualAI", "AIProcessor.process file=\(imageURL.lastPathComponent) exists=\(FileManager.default.fileExists(atPath: imageURL.path) ? 1 : 0)")
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            callbacks.error("Could not read screenshot at \(imageURL.lastPathComponent)", imageURL: imageURL)
            return
        }
        Task { await orchestrator.submitLatestScreenshot(imageURL) }
    }

    func retryLatestScreenshot() {
        DevLog.log("VisualAI", "AIProcessor.retryLatestScreenshot")
        Task { await orchestrator.retryLatestScreenshot() }
    }

    func cancel() {
        DevLog.log("VisualAI", "AIProcessor.cancel")
        Task { await orchestrator.cancel() }
    }
}

// MARK: - VisualAIOrchestrator

private actor VisualAIOrchestrator {
    private struct PendingImage: Sendable {
        let url: URL
        let generation: Int
    }

    private enum AttemptOutcome {
        case delivered
        case failed(String)
        case superseded
        case cancelled
    }

    private enum AttemptEvent {
        case providerDelta(AIProviderID, String)
        case providerCompleted(AIProviderID)
        case providerFailed(AIProviderID, String)
        case startOpenAI
        case firstTokenDeadline
        case completionDeadline
        case visibleStall(AIProviderID, Int)
        case superseded
        case cancelled
    }

    private final class AttemptControl: @unchecked Sendable {
        private let lock = NSLock()
        private let eventSink: AsyncStream<AttemptEvent>.Continuation
        private var tasks: [Task<Void, Never>] = []
        private var superseded = false
        private var cancelled = false
        private var closed = false

        init(eventSink: AsyncStream<AttemptEvent>.Continuation) {
            self.eventSink = eventSink
        }

        var isSuperseded: Bool {
            locked { superseded }
        }

        var isCancelled: Bool {
            locked { cancelled }
        }

        var isStopped: Bool {
            locked { superseded || cancelled || closed }
        }

        func addTask(_ task: Task<Void, Never>) {
            let shouldCancel = locked {
                guard !superseded, !cancelled, !closed else { return true }
                tasks.append(task)
                return false
            }
            if shouldCancel {
                task.cancel()
            }
        }

        func supersede() {
            DevLog.log("VisualAI", "AttemptControl.supersede")
            stop(yielding: .superseded) {
                superseded = true
            }
        }

        func cancel() {
            DevLog.log("VisualAI", "AttemptControl.cancel")
            stop(yielding: .cancelled) {
                cancelled = true
            }
        }

        func finish() {
            let tasksToCancel = locked { () -> [Task<Void, Never>] in
                guard !closed else { return [] }
                closed = true
                let snapshot = tasks
                tasks.removeAll()
                return snapshot
            }
            DevLog.log("VisualAI", "AttemptControl.finish cancelTasks=\(tasksToCancel.count)")
            tasksToCancel.forEach { $0.cancel() }
            eventSink.finish()
        }

        private func stop(yielding event: AttemptEvent, markStopped: () -> Void) {
            let tasksToCancel = locked { () -> [Task<Void, Never>]? in
                guard !closed else { return nil }
                markStopped()
                closed = true
                let snapshot = tasks
                tasks.removeAll()
                return snapshot
            }
            guard let tasksToCancel else { return }
            DevLog.log("VisualAI", "AttemptControl.stop event=\(event) cancelTasks=\(tasksToCancel.count)")
            tasksToCancel.forEach { $0.cancel() }
            eventSink.yield(event)
            eventSink.finish()
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private let config: AIConfig
    private let geminiClient: AIProviderClient?
    private let openAIClient: AIProviderClient?
    private let callbacks: VisualAICallbackBox

    private var generationCounter = 0
    private var latestScreenshotURL: URL?
    private var pendingImage: PendingImage?
    private var isRunning = false
    private var isCancelled = false
    private var activeAttempt: AttemptControl?

    private let maxRetries = 3
    private let retryBackoffs: [TimeInterval] = [0.5, 1.5, 3.0]

    init(
        config: AIConfig,
        geminiClient: AIProviderClient?,
        openAIClient: AIProviderClient?,
        callbacks: VisualAICallbackBox
    ) {
        self.config = config
        self.geminiClient = geminiClient
        self.openAIClient = openAIClient
        self.callbacks = callbacks
    }

    func submitLatestScreenshot(_ url: URL) {
        guard config.enabled, !isCancelled else { return }
        latestScreenshotURL = url
        enqueueScreenshot(url, reason: "capture")
    }

    func retryLatestScreenshot() {
        guard config.enabled, !isCancelled else { return }
        guard let latestScreenshotURL else {
            DevLog.log("VisualAI", "retryLatestScreenshot ignored: no latest screenshot")
            return
        }
        DevLog.log("VisualAI", "retryLatestScreenshot file=\(latestScreenshotURL.lastPathComponent)")
        enqueueScreenshot(latestScreenshotURL, reason: "manual-retry")
    }

    private func enqueueScreenshot(_ url: URL, reason: String) {
        generationCounter += 1
        pendingImage = PendingImage(url: url, generation: generationCounter)
        DevLog.log("VisualAI", "enqueueScreenshot reason=\(reason) gen=\(generationCounter) file=\(url.lastPathComponent) isRunning=\(isRunning ? 1 : 0)")
        if !isRunning {
            isRunning = true
            DevLog.log("VisualAI", "starting runLoop")
            Task { await self.runLoop() }
        } else {
            DevLog.log("VisualAI", "superseding active attempt for enqueued screenshot gen=\(generationCounter) reason=\(reason)")
            activeAttempt?.supersede()
        }
    }

    func cancel() {
        DevLog.log("VisualAI", "orchestrator cancel")
        isCancelled = true
        pendingImage = nil
        activeAttempt?.cancel()
    }

    private func runLoop() async {
        DevLog.log("VisualAI", "runLoop enter")
        while !isCancelled {
            guard let image = pendingImage else {
                DevLog.log("VisualAI", "runLoop idle no pending image")
                isRunning = false
                return
            }
            pendingImage = nil
            DevLog.log("VisualAI", "runLoop processing gen=\(image.generation) file=\(image.url.lastPathComponent)")
            await process(image)
        }
        DevLog.log("VisualAI", "runLoop exit cancelled")
        isRunning = false
    }

    private func process(_ image: PendingImage) async {
        var retryIndex = 0
        while retryIndex <= maxRetries, !isCancelled {
            DevLog.log("VisualAI", "process image gen=\(image.generation) file=\(image.url.lastPathComponent) retry=\(retryIndex)/\(maxRetries)")
            if retryIndex == 0 {
                callbacks.processingStarted(imageURL: image.url, retryIndex: retryIndex, maxRetries: maxRetries)
            } else {
                callbacks.status("Retry \(retryIndex) of \(maxRetries)", imageURL: image.url)
            }

            let outcome = await runAttempt(image: image, retryIndex: retryIndex)
            DevLog.log("VisualAI", "attempt outcome gen=\(image.generation) file=\(image.url.lastPathComponent) retry=\(retryIndex) outcome=\(outcome)")
            switch outcome {
            case .delivered:
                return
            case .superseded:
                if pendingImage?.url == image.url {
                    DevLog.log("VisualAI", "skip discard for same-url supersession file=\(image.url.lastPathComponent)")
                } else {
                    callbacks.discard(imageURL: image.url)
                }
                return
            case .cancelled:
                callbacks.discard(imageURL: image.url)
                return
            case .failed(let message):
                if pendingImage != nil {
                    callbacks.discard(imageURL: image.url)
                    return
                }
                guard retryIndex < maxRetries else {
                    callbacks.error(message, imageURL: image.url)
                    return
                }
                let backoff = retryBackoffs[min(retryIndex, retryBackoffs.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                if pendingImage != nil {
                    callbacks.discard(imageURL: image.url)
                    return
                }
                retryIndex += 1
            }
        }
    }

    private func runAttempt(image: PendingImage, retryIndex: Int) async -> AttemptOutcome {
        DevLog.log("VisualAI", "runAttempt start gen=\(image.generation) retry=\(retryIndex) file=\(image.url.lastPathComponent)")
        guard let imageData = try? Data(contentsOf: image.url) else {
            DevLog.log("VisualAI", "runAttempt failed reading image file=\(image.url.path)")
            return .failed("Could not read screenshot at \(image.url.lastPathComponent)")
        }

        guard let geminiClient else {
            DevLog.log("VisualAI", "runAttempt failed no Gemini client")
            return .failed("No Google Gemini API key is saved. Add it in the API Keys tab.")
        }

        let mimeType = image.url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        DevLog.log("VisualAI", "runAttempt image loaded bytes=\(imageData.count) mime=\(mimeType) openAIConfigured=\(openAIClient == nil ? 0 : 1)")
        var continuation: AsyncStream<AttemptEvent>.Continuation?
        let events = AsyncStream<AttemptEvent> { continuation = $0 }
        guard let eventSink = continuation else {
            DevLog.log("VisualAI", "runAttempt failed event stream init")
            return .failed("Failed to initialize AI request stream.")
        }

        let attemptControl = AttemptControl(eventSink: eventSink)
        activeAttempt = attemptControl
        defer {
            attemptControl.finish()
            if activeAttempt === attemptControl {
                activeAttempt = nil
            }
        }

        var startedProviders = Set<AIProviderID>()
        var providerText: [AIProviderID: String] = [:]
        var providerCompleted = Set<AIProviderID>()
        var providerFailed = Set<AIProviderID>()
        var visibleProvider: AIProviderID?
        var firstTextSeen = false
        var finished = false
        var stallToken = 0

        func hasNewerScreenshot() -> Bool {
            generationCounter > image.generation
        }

        func finishSuperseded() -> AttemptOutcome {
            DevLog.log("VisualAI", "finishSuperseded gen=\(image.generation) file=\(image.url.lastPathComponent)")
            finished = true
            attemptControl.finish()
            return .superseded
        }

        func finishCancelled() -> AttemptOutcome {
            DevLog.log("VisualAI", "finishCancelled gen=\(image.generation) file=\(image.url.lastPathComponent)")
            finished = true
            attemptControl.finish()
            return .cancelled
        }

        func startProvider(_ client: AIProviderClient) {
            guard !startedProviders.contains(client.providerID),
                  !finished,
                  !attemptControl.isStopped,
                  !hasNewerScreenshot() else { return }
            startedProviders.insert(client.providerID)
            DevLog.log("VisualAI", "provider start provider=\(client.providerID.rawValue) gen=\(image.generation) retry=\(retryIndex)")
            callbacks.status("\(client.providerID.displayName) started", imageURL: image.url)
            let task = Task {
                do {
                    for try await event in client.streamScreenshotAnalysis(
                        imageData: imageData,
                        mimeType: mimeType,
                        prompt: config.prompt
                    ) {
                        guard !Task.isCancelled else { return }
                        switch event {
                        case .textDelta(let text):
                            DevLog.log("VisualAI", "provider delta provider=\(client.providerID.rawValue) chars=\(text.count) gen=\(image.generation)")
                            eventSink.yield(.providerDelta(client.providerID, text))
                        case .completed:
                            DevLog.log("VisualAI", "provider completed provider=\(client.providerID.rawValue) gen=\(image.generation)")
                            eventSink.yield(.providerCompleted(client.providerID))
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    DevLog.log("VisualAI", "provider failed provider=\(client.providerID.rawValue) error=\(error.localizedDescription) gen=\(image.generation)")
                    eventSink.yield(.providerFailed(client.providerID, error.localizedDescription))
                }
            }
            attemptControl.addTask(task)
        }

        func startOpenAIIfAvailable() {
            guard let openAIClient,
                  !startedProviders.contains(openAIClient.providerID),
                  !finished,
                  !attemptControl.isStopped,
                  !hasNewerScreenshot() else {
                DevLog.log(
                    "VisualAI",
                    "startOpenAI skipped configured=\(openAIClient == nil ? 0 : 1) alreadyStarted=\(startedProviders.contains(.openAI) ? 1 : 0) finished=\(finished ? 1 : 0) stopped=\(attemptControl.isStopped ? 1 : 0) newer=\(hasNewerScreenshot() ? 1 : 0)"
                )
                return
            }
            DevLog.log("VisualAI", "startOpenAI")
            startProvider(openAIClient)
        }

        func completedProviderWithText() -> AIProviderID? {
            providerCompleted
                .filter { !(providerText[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .max { (providerText[$0] ?? "").count < (providerText[$1] ?? "").count }
        }

        func providerWithBestText(excluding excluded: AIProviderID? = nil) -> AIProviderID? {
            providerText
                .filter { provider, text in
                    provider != excluded && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .max { $0.value.count < $1.value.count }?
                .key
        }

        func scheduleVisibleStallCheck(for provider: AIProviderID) {
            stallToken += 1
            let token = stallToken
            let task = Task {
                try? await Task.sleep(nanoseconds: 11_000_000_000)
                guard !Task.isCancelled else { return }
                eventSink.yield(.visibleStall(provider, token))
            }
            attemptControl.addTask(task)
        }

        func finishDelivered(provider: AIProviderID, partial: Bool) -> AttemptOutcome {
            guard !attemptControl.isSuperseded, !hasNewerScreenshot() else {
                return finishSuperseded()
            }
            guard !attemptControl.isCancelled, !isCancelled else {
                return finishCancelled()
            }
            finished = true
            attemptControl.finish()
            let text = providerText[provider] ?? ""
            DevLog.log("VisualAI", "finishDelivered provider=\(provider.rawValue) partial=\(partial ? 1 : 0) chars=\(text.count) gen=\(image.generation)")
            if visibleProvider != provider {
                callbacks.replace(text, imageURL: image.url)
            }
            if partial {
                callbacks.status("Partial answer from \(provider.displayName)", imageURL: image.url)
                callbacks.result("## Partial answer\n\n\(text)", imageURL: image.url)
            } else {
                callbacks.status("Completed by \(provider.displayName)", imageURL: image.url)
                callbacks.result(text, imageURL: image.url)
            }
            return .delivered
        }

        func failAttempt(_ message: String) -> AttemptOutcome {
            if attemptControl.isSuperseded || hasNewerScreenshot() {
                return finishSuperseded()
            }
            if attemptControl.isCancelled || isCancelled {
                return finishCancelled()
            }
            finished = true
            attemptControl.finish()
            DevLog.log("VisualAI", "failAttempt gen=\(image.generation) retry=\(retryIndex) message=\(message) pendingNewer=\(pendingImage == nil ? 0 : 1)")
            return pendingImage != nil ? .superseded : .failed(message)
        }

        startProvider(geminiClient)

        attemptControl.addTask(Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            DevLog.log("VisualAI", "timer 8s startOpenAI gen=\(image.generation)")
            eventSink.yield(.startOpenAI)
        })
        attemptControl.addTask(Task {
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard !Task.isCancelled else { return }
            DevLog.log("VisualAI", "timer 18s firstTokenDeadline gen=\(image.generation)")
            eventSink.yield(.firstTokenDeadline)
        })

        for await event in events {
            DevLog.log("VisualAI", "attempt event gen=\(image.generation) event=\(event)")
            if attemptControl.isSuperseded || hasNewerScreenshot() {
                return finishSuperseded()
            }
            if attemptControl.isCancelled {
                return finishCancelled()
            }
            if isCancelled {
                return finishCancelled()
            }

            switch event {
            case .superseded:
                return finishSuperseded()

            case .cancelled:
                return finishCancelled()

            case .startOpenAI:
                if !firstTextSeen {
                    startOpenAIIfAvailable()
                } else {
                    DevLog.log("VisualAI", "startOpenAI timer ignored firstTextSeen=1 gen=\(image.generation)")
                }

            case .firstTokenDeadline:
                if !firstTextSeen {
                    return failAttempt("No AI provider produced text within 18 seconds.")
                }

            case .completionDeadline:
                if let completed = completedProviderWithText() {
                    return finishDelivered(provider: completed, partial: false)
                }
                if let best = providerWithBestText() {
                    return finishDelivered(provider: best, partial: true)
                }
                return failAttempt("AI providers did not produce a usable answer.")

            case .visibleStall(let provider, let token):
                guard token == stallToken, visibleProvider == provider, !finished else { break }
                if let completed = completedProviderWithText(), completed != provider {
                    callbacks.status("Switched to \(completed.displayName) after stall", imageURL: image.url)
                    visibleProvider = completed
                    return finishDelivered(provider: completed, partial: false)
                }
                if let backup = providerWithBestText(excluding: provider),
                   (providerText[backup] ?? "").count > (providerText[provider] ?? "").count {
                    callbacks.status("Switched to \(backup.displayName) after stall", imageURL: image.url)
                    visibleProvider = backup
                    callbacks.replace(providerText[backup] ?? "", imageURL: image.url)
                    scheduleVisibleStallCheck(for: backup)
                }

            case .providerDelta(let provider, let text):
                providerText[provider, default: ""] += text
                let accumulated = providerText[provider] ?? ""
                let usable = !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard usable else { break }

                if !firstTextSeen {
                    firstTextSeen = true
                    visibleProvider = provider
                    DevLog.log("VisualAI", "first text provider=\(provider.rawValue) chars=\(accumulated.count) gen=\(image.generation)")
                    callbacks.status("Streaming from \(provider.displayName)", imageURL: image.url)
                    callbacks.stream(accumulated, imageURL: image.url)
                    scheduleVisibleStallCheck(for: provider)
                    attemptControl.addTask(Task {
                        try? await Task.sleep(nanoseconds: 23_000_000_000)
                        guard !Task.isCancelled else { return }
                        DevLog.log("VisualAI", "timer 23s completionDeadline gen=\(image.generation)")
                        eventSink.yield(.completionDeadline)
                    })
                } else if visibleProvider == nil {
                    visibleProvider = provider
                    DevLog.log("VisualAI", "visible provider set provider=\(provider.rawValue) chars=\(accumulated.count) gen=\(image.generation)")
                    callbacks.status("Switched to \(provider.displayName)", imageURL: image.url)
                    callbacks.replace(accumulated, imageURL: image.url)
                    scheduleVisibleStallCheck(for: provider)
                } else if visibleProvider == provider {
                    DevLog.log("VisualAI", "visible chunk provider=\(provider.rawValue) chars=\(text.count) total=\(accumulated.count) gen=\(image.generation)")
                    callbacks.stream(text, imageURL: image.url)
                    scheduleVisibleStallCheck(for: provider)
                } else {
                    DevLog.log("VisualAI", "backup chunk buffered provider=\(provider.rawValue) chars=\(text.count) total=\(accumulated.count) gen=\(image.generation)")
                }

            case .providerCompleted(let provider):
                let text = providerText[provider] ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    providerFailed.insert(provider)
                    if provider == .gemini && !firstTextSeen {
                        startOpenAIIfAvailable()
                    }
                    if providerFailed.count == startedProviders.count && !firstTextSeen {
                        return failAttempt("AI providers returned empty responses.")
                    }
                    break
                }

                providerCompleted.insert(provider)
                if visibleProvider == nil {
                    firstTextSeen = true
                    visibleProvider = provider
                    callbacks.replace(text, imageURL: image.url)
                }
                if visibleProvider == provider {
                    return finishDelivered(provider: provider, partial: false)
                }

            case .providerFailed(let provider, let message):
                providerFailed.insert(provider)
                callbacks.status("\(provider.displayName) failed: \(message)", imageURL: image.url)
                if provider == .gemini && !firstTextSeen {
                    startOpenAIIfAvailable()
                }

                if visibleProvider == provider {
                    if let completed = completedProviderWithText(), completed != provider {
                        visibleProvider = completed
                        callbacks.status("Switched to \(completed.displayName)", imageURL: image.url)
                        return finishDelivered(provider: completed, partial: false)
                    }
                    if let backup = providerWithBestText(excluding: provider) {
                        visibleProvider = backup
                        callbacks.status("Switched to \(backup.displayName)", imageURL: image.url)
                        callbacks.replace(providerText[backup] ?? "", imageURL: image.url)
                        scheduleVisibleStallCheck(for: backup)
                    } else {
                        visibleProvider = nil
                    }
                }

                if providerFailed.count == startedProviders.count && !firstTextSeen {
                    return failAttempt(message)
                }
            }
        }

        if attemptControl.isSuperseded || hasNewerScreenshot() {
            return finishSuperseded()
        }
        if attemptControl.isCancelled || isCancelled {
            return finishCancelled()
        }
        return .failed("AI attempt ended unexpectedly.")
    }
}

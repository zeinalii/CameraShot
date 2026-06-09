import Foundation
import ScreenCaptureKit

// MARK: - RealtimeAudioAIController

final class RealtimeAudioAIController: NSObject, @unchecked Sendable {
    enum Mode {
        case passiveSystemAudio
        case pushToTalkSystemAudio
    }

    enum PassiveState {
        case starting
        case listening
        case sending
        case waiting
        case responding
        case paused
        case reconnecting
        case unavailable
    }

    var onChunk: ((String) -> Void)?
    var onDone: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onPassiveState: ((PassiveState) -> Void)?

    private let apiKey: String
    private let systemPrompt: String
    private let mode: Mode
    private let model: String
    private let session = URLSession(configuration: .ephemeral)
    private let stateLock = NSLock()
    private let sendStateQueue = DispatchQueue(label: "camerashot.realtime.send-state")

    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var stopped = false
    private var didSendSessionUpdate = false
    private var responseInFlight = false
    private var realtimeReady = false
    private var reconnectAttempt = 0
    private var rotationWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var inFlightPassiveAudioBytes = 0
    private var droppedPassiveAudioChunks = 0
    private var audioAppendEventCount = 0
    private var audioAppendByteCount = 0

    private var scStream: SCStream?
    private var passiveAudioPaused = false
    private var passiveCaptureToken = 0
    private var passiveCaptureActive = false
    private var passiveSampleBufferCount = 0
    private var passiveSampleByteCount = 0
    private var passiveDroppedBeforeReady = 0
    private var passiveLastSampleLogAt: CFAbsoluteTime = 0

    private var isRecordingPushToTalk = false
    private var recordedPushToTalkAudio = Data()
    private var pushToTalkLimitReached = false
    private var pushToTalkSystemCaptureToken = 0
    private var instantSampleBufferCount = 0
    private var instantSampleByteCount = 0
    private var instantLastSampleLogAt: CFAbsoluteTime = 0
    private let recordingQueue = DispatchQueue(label: "camerashot.instant-voice.recording")

    private let maxAudioEventChunkBytes = 512 * 1024
    private let maxPassiveInFlightAudioBytes = 1_500_000
    private let maxPushToTalkAudioBytes = 24_000 * 2 * 180
    private let sessionRotationInterval: TimeInterval = 55 * 60
    private let rotationRetryInterval: TimeInterval = 30
    private let maxReconnectAttempts = 8

    init(
        apiKey: String,
        systemPrompt: String,
        mode: Mode,
        model: String = RealtimeAudioConfig.model
    ) {
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.mode = mode
        self.model = model
    }

    func start() async throws {
        log("start model=\(model)")
        notifyPassiveState(.starting)
        try connectWebSocket()
        if mode == .passiveSystemAudio {
            passiveCaptureToken += 1
            try await startPassiveSystemAudioCapture(token: passiveCaptureToken)
        }
        log("start complete")
    }

    func stop() {
        log("stop requested")
        rotationWorkItem?.cancel()
        rotationWorkItem = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        receiveTask?.cancel()
        receiveTask = nil
        let task = locked {
            stopped = true
            realtimeReady = false
            didSendSessionUpdate = false
            responseInFlight = false
            let current = wsTask
            wsTask = nil
            return current
        }
        task?.cancel(with: .goingAway, reason: nil)
        clearPassiveSendBacklog()
        stopSystemAudioCapture(reason: "controller stop")
        log("stop complete")
    }

    func beginPushToTalk() {
        guard mode == .pushToTalkSystemAudio else {
            log("beginPushToTalk ignored wrong-mode")
            return
        }
        guard !isStopped else {
            log("beginPushToTalk ignored stopped")
            return
        }
        guard !isRecordingPushToTalk else {
            log("beginPushToTalk ignored already-recording")
            return
        }
        guard isRealtimeReady else {
            log("beginPushToTalk ignored realtime-not-ready")
            fire { self.onStatus?("Realtime is reconnecting. Try again in a moment.") }
            return
        }
        log("beginPushToTalk start")
        isRecordingPushToTalk = true
        pushToTalkSystemCaptureToken += 1
        let token = pushToTalkSystemCaptureToken
        instantSampleBufferCount = 0
        instantSampleByteCount = 0
        instantLastSampleLogAt = 0
        recordingQueue.sync {
            recordedPushToTalkAudio.removeAll(keepingCapacity: true)
            pushToTalkLimitReached = false
        }
        if hasResponseInFlight {
            sendEvent(["type": "response.cancel"])
        }
        sendEvent(["type": "input_audio_buffer.clear"])
        fire { self.onStatus?("Starting system audio capture...") }
        Task { [weak self] in
            await self?.startPushToTalkSystemAudioCapture(token: token)
        }
    }

    func endPushToTalk() {
        guard mode == .pushToTalkSystemAudio else {
            log("endPushToTalk ignored wrong-mode")
            return
        }
        guard isRecordingPushToTalk else {
            log("endPushToTalk ignored not-recording")
            return
        }
        isRecordingPushToTalk = false
        pushToTalkSystemCaptureToken += 1
        stopSystemAudioCapture(reason: "instant release")

        let audio = recordingQueue.sync { recordedPushToTalkAudio }
        recordingQueue.async { [weak self] in
            self?.recordedPushToTalkAudio.removeAll(keepingCapacity: true)
        }

        guard audio.count > 1_000 else {
            log("endPushToTalk too-short system-audio-bytes=\(audio.count)")
            fire { self.onStatus?("Hold a little longer to capture audio.") }
            return
        }

        guard isRealtimeReady else {
            log("endPushToTalk ignored realtime-not-ready system-audio-bytes=\(audio.count)")
            fire { self.onStatus?("Realtime is reconnecting. Try again in a moment.") }
            return
        }

        log("endPushToTalk sending system-audio-bytes=\(audio.count)")
        sendAudioAppend(audio, live: false)
        sendEvent(["type": "input_audio_buffer.commit"])
        sendEvent([
            "type": "response.create",
            "response": [
                "output_modalities": ["text"],
            ],
        ])
    }

    func setPassiveAudioPaused(_ paused: Bool) {
        guard mode == .passiveSystemAudio else {
            log("setPassiveAudioPaused ignored wrong-mode paused=\(paused ? 1 : 0)")
            return
        }
        guard passiveAudioPaused != paused else {
            log("setPassiveAudioPaused unchanged paused=\(paused ? 1 : 0)")
            return
        }

        passiveAudioPaused = paused
        passiveCaptureToken += 1
        let token = passiveCaptureToken

        if paused {
            log("passive audio paused")
            stopSystemAudioCapture(reason: "passive pause")
            clearPassiveSendBacklog()
            notifyPassiveState(.paused)
            if hasResponseInFlight {
                sendEvent(["type": "response.cancel"])
                locked { responseInFlight = false }
                fire { self.onDone?() }
            }
            sendEvent(["type": "input_audio_buffer.clear"])
            fire { self.onStatus?("Audio AI paused.") }
            return
        }

        log("passive audio resuming token=\(token)")
        guard !isStopped else {
            log("passive audio resume ignored stopped")
            return
        }
        notifyPassiveState(.starting)
        fire { self.onStatus?("Audio AI resuming...") }
        Task { [weak self] in
            await self?.resumePassiveSystemAudioCapture(token: token)
        }
    }

    func forcePassiveTurnEnd() {
        guard mode == .passiveSystemAudio else {
            log("forcePassiveTurnEnd ignored wrong-mode")
            return
        }
        guard !isStopped else {
            log("forcePassiveTurnEnd ignored stopped")
            return
        }
        guard !passiveAudioPaused else {
            log("forcePassiveTurnEnd ignored paused")
            fire { self.onStatus?("Audio AI is paused.") }
            return
        }
        guard isRealtimeReady else {
            log("forcePassiveTurnEnd ignored realtime-not-ready")
            fire { self.onStatus?("Realtime is reconnecting. Try again in a moment.") }
            return
        }

        if hasResponseInFlight {
            log("forcePassiveTurnEnd cancelling active response before manual commit")
            sendEvent(["type": "response.cancel"])
            locked { responseInFlight = false }
            fire { self.onDone?() }
        }

        log("forcePassiveTurnEnd commit-and-create")
        notifyPassiveState(.sending)
        fire { self.onStatus?("Audio AI manual turn end.") }
        sendEvent(["type": "input_audio_buffer.commit"])
        sendEvent([
            "type": "response.create",
            "response": [
                "output_modalities": ["text"],
            ],
        ])
    }

    private func connectWebSocket() throws {
        guard currentWebSocketTask == nil else {
            log("connectWebSocket skipped existing-task")
            return
        }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else {
            throw RealtimeAudioAIError.invalidURL
        }

        log("connectWebSocket url=wss://api.openai.com/v1/realtime model=\(model)")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: req)
        locked {
            wsTask = task
            stopped = false
            didSendSessionUpdate = false
            responseInFlight = false
            realtimeReady = false
        }
        clearPassiveSendBacklog()
        task.resume()
        sendSessionUpdate()
        scheduleSessionRotation()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        log("connectWebSocket resumed")
    }

    private func sendSessionUpdate() {
        let shouldSend = locked {
            guard !stopped, !didSendSessionUpdate else { return false }
            didSendSessionUpdate = true
            return true
        }
        guard shouldSend else { return }

        log("send session.update turnDetection=\(mode == .passiveSystemAudio ? "semantic_vad" : "manual") promptChars=\(systemPrompt.count)")
        let turnDetection: Any
        switch mode {
        case .passiveSystemAudio:
            turnDetection = [
                "type": "semantic_vad",
                "eagerness": "medium",
                "create_response": true,
                "interrupt_response": true,
            ]
        case .pushToTalkSystemAudio:
            turnDetection = NSNull()
        }

        sendEvent([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "instructions": systemPrompt,
                "output_modalities": ["text"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000,
                        ],
                        "turn_detection": turnDetection,
                    ],
                ],
                "reasoning": [
                    "effort": "low",
                ],
            ],
        ])
    }

    private func sendAudioAppend(_ pcm16: Data, live: Bool) {
        guard !pcm16.isEmpty, !isStopped else { return }
        if live, mode == .passiveSystemAudio, passiveAudioPaused {
            return
        }
        if live, !isRealtimeReady {
            notePassiveAudioDroppedBeforeReady(bytes: pcm16.count)
            return
        }

        let eventStartCount = audioAppendEventCount
        var offset = 0
        while offset < pcm16.count {
            let end = min(offset + maxAudioEventChunkBytes, pcm16.count)
            let chunk = pcm16.subdata(in: offset..<end)
            if live, !reservePassiveAudioBytes(chunk.count) {
                offset = end
                continue
            }
            sendEvent([
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString(),
            ], reportErrors: !live) { [weak self] error in
                guard let self else { return }
                if live {
                    self.releasePassiveAudioBytes(chunk.count)
                    if error != nil {
                        self.scheduleReconnect(reason: "passive audio send failed")
                    }
                }
            }
            audioAppendEventCount += 1
            audioAppendByteCount += chunk.count
            offset = end
        }
        if !live || audioAppendEventCount == eventStartCount + 1 && audioAppendEventCount % 100 == 1 {
            log("sent audio append live=\(live ? 1 : 0) bytes=\(pcm16.count) totalEvents=\(audioAppendEventCount) totalBytes=\(audioAppendByteCount)")
        }
    }

    private func sendEvent(
        _ event: [String: Any],
        reportErrors: Bool = true,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard !isStopped, let wsTask = currentWebSocketTask else {
            log("send skipped event=\(eventType(event)) reason=no-active-websocket")
            completion?(nil)
            return
        }
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            log("send skipped event=\(eventType(event)) reason=invalid-json")
            completion?(nil)
            return
        }
        let type = eventType(event)
        if type != "input_audio_buffer.append" {
            log("send event=\(type) bytes=\(data.count)")
        }
        wsTask.send(.string(text)) { [weak self] error in
            guard let self else { return }
            completion?(error)
            guard let error, !self.isStopped else { return }
            self.log("send failed event=\(type) error=\(error.localizedDescription)")
            self.scheduleReconnect(reason: "send failed")
            if reportErrors {
                self.fire { self.onError?("Realtime send failed: \(error.localizedDescription)") }
            }
        }
    }

    private func receiveLoop() async {
        log("receiveLoop start")
        while !isStopped {
            guard let task = currentWebSocketTask else { break }
            do {
                let message = try await task.receive()
                guard task === currentWebSocketTask else { continue }
                switch message {
                case .string(let text):
                    handleServerMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleServerMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                guard !isStopped else { return }
                log("receiveLoop lost error=\(error.localizedDescription)")
                notifyPassiveState(.reconnecting)
                fire { self.onError?("Realtime connection lost: \(error.localizedDescription)") }
                scheduleReconnect(reason: "connection lost")
                break
            }
        }
        log("receiveLoop exit stopped=\(isStopped ? 1 : 0)")
    }

    private func handleServerMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            log("server message ignored invalid-json chars=\(raw.count)")
            return
        }

        log("server event \(serverEventSummary(type: type, object: obj))")

        switch type {
        case "response.created":
            locked { responseInFlight = true }
            notifyPassiveState(.waiting)
        case "response.output_text.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                notifyPassiveState(.responding)
                fire { self.onChunk?(delta) }
            }
        case "response.done":
            locked { responseInFlight = false }
            if !passiveAudioPaused {
                notifyPassiveState(.listening)
            }
            fire { self.onDone?() }
        case "response.cancelled":
            locked { responseInFlight = false }
        case "input_audio_buffer.speech_started":
            if !passiveAudioPaused {
                notifyPassiveState(.listening)
            }
            fire { self.onStatus?("Listening...") }
        case "input_audio_buffer.speech_stopped":
            if !passiveAudioPaused {
                notifyPassiveState(.waiting)
            }
            fire { self.onStatus?("Thinking...") }
        case "session.updated":
            locked {
                realtimeReady = true
                reconnectAttempt = 0
            }
            if mode == .passiveSystemAudio, passiveCaptureActive, !passiveAudioPaused {
                notifyPassiveState(.listening)
            }
            fire { self.onStatus?("Realtime ready.") }
        case "error":
            let msg = errorMessage(from: obj) ?? "Realtime API error."
            log("server error message=\(msg)")
            notifyPassiveState(passiveStateAfterServerError())
            fire { self.onError?(msg) }
        default:
            if type.hasSuffix("_error") || type.contains("error") {
                let msg = errorMessage(from: obj) ?? "Realtime API error: \(type)"
                log("server error-like event=\(type) message=\(msg)")
                notifyPassiveState(passiveStateAfterServerError())
                fire { self.onError?(msg) }
            }
        }
    }

    private func errorMessage(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return object["message"] as? String
    }

    private func startPassiveSystemAudioCapture(token: Int) async throws {
        let stream = try await startSystemAudioCapture { [weak self] in
            guard let self else { return false }
            return !self.isStopped
                && self.mode == .passiveSystemAudio
                && !self.passiveAudioPaused
                && token == self.passiveCaptureToken
        }
        guard !isStopped,
              mode == .passiveSystemAudio,
              !passiveAudioPaused,
              token == passiveCaptureToken else {
            log("passive system audio capture started stale token=\(token) current=\(passiveCaptureToken) paused=\(passiveAudioPaused ? 1 : 0)")
            stopSystemAudioCapture(stream: stream, reason: "stale passive capture")
            return
        }
        passiveCaptureActive = true
        log("passive system audio capture ready token=\(token)")
        notifyPassiveState(.listening)
        fire { self.onStatus?("Audio AI listening.") }
    }

    private func resumePassiveSystemAudioCapture(token: Int) async {
        do {
            try await startPassiveSystemAudioCapture(token: token)
        } catch {
            if error is CancellationError {
                log("passive system audio capture cancelled before activation token=\(token) current=\(passiveCaptureToken)")
                return
            }
            guard token == passiveCaptureToken, !passiveAudioPaused else {
                log("passive system audio capture stale failure token=\(token) error=\(error.localizedDescription)")
                return
            }
            log("passive system audio capture resume failed error=\(error.localizedDescription)")
            fire { self.onError?("Audio AI resume failed: \(error.localizedDescription)") }
        }
    }

    private func startSystemAudioCapture(shouldActivate: (() -> Bool)? = nil) async throws -> SCStream {
        log("system audio capture setup begin")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        log("system audio shareable displays=\(content.displays.count) windows=\(content.windows.count)")
        guard let display = content.displays.first else {
            throw RealtimeAudioAIError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio        = true
        cfg.sampleRate           = 24_000
        cfg.channelCount         = 1
        cfg.width                = 2
        cfg.height               = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        if let shouldActivate, !shouldActivate() {
            throw CancellationError()
        }

        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        scStream = stream
        do {
            try stream.addStreamOutput(self, type: .audio,
                                       sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
        } catch {
            if stream === scStream {
                scStream = nil
            }
            throw error
        }
        log("system audio capture started displayID=\(display.displayID) sampleRate=\(cfg.sampleRate) channels=\(cfg.channelCount)")
        return stream
    }

    private func startPushToTalkSystemAudioCapture(token: Int) async {
        do {
            let stream = try await startSystemAudioCapture { [weak self] in
                guard let self else { return false }
                return !self.isStopped
                    && self.mode == .pushToTalkSystemAudio
                    && self.isRecordingPushToTalk
                    && token == self.pushToTalkSystemCaptureToken
            }
            guard !isStopped,
                  mode == .pushToTalkSystemAudio,
                  isRecordingPushToTalk,
                  token == pushToTalkSystemCaptureToken else {
                log("instant system audio capture started after release token=\(token) current=\(pushToTalkSystemCaptureToken)")
                stopSystemAudioCapture(stream: stream, reason: "stale instant capture")
                return
            }
            log("instant system audio capture ready token=\(token)")
            fire { self.onStatus?("Recording system audio...") }
        } catch {
            if error is CancellationError {
                log("instant system audio capture cancelled before activation token=\(token) current=\(pushToTalkSystemCaptureToken)")
                return
            }
            guard token == pushToTalkSystemCaptureToken else {
                log("instant system audio capture stale failure token=\(token) error=\(error.localizedDescription)")
                return
            }
            isRecordingPushToTalk = false
            log("instant system audio capture failed error=\(error.localizedDescription)")
            fire { self.onError?("Failed to capture system audio: \(error.localizedDescription)") }
        }
    }

    private func stopSystemAudioCapture(stream target: SCStream? = nil, reason: String) {
        let stream: SCStream
        if let target {
            stream = target
            if target === scStream {
                scStream = nil
            }
        } else {
            guard let current = scStream else { return }
            stream = current
            scStream = nil
        }
        if mode == .passiveSystemAudio {
            passiveCaptureActive = false
        }
        log("system audio capture stopping reason=\(reason)")
        stream.stopCapture { [weak self] error in
            guard let error else { return }
            self?.log("system audio capture stop failed error=\(error.localizedDescription)")
        }
    }

    private func appendPushToTalkSystemAudio(_ data: Data) {
        recordingQueue.async { [weak self] in
            guard let self else { return }
            let remaining = self.maxPushToTalkAudioBytes - self.recordedPushToTalkAudio.count
            if remaining > 0 {
                self.recordedPushToTalkAudio.append(data.prefix(remaining))
            }
            guard data.count > remaining, !self.pushToTalkLimitReached else { return }
            self.pushToTalkLimitReached = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRecordingPushToTalk else { return }
                self.onStatus?("Instant Voice reached 3 minutes; sending captured system audio.")
                self.endPushToTalk()
            }
        }
    }

    private func pcm16FromSampleBuffer(_ buf: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(buf) else { return nil }
        var total: Int = 0
        var ptr: UnsafeMutablePointer<CChar>? = nil
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &total,
                                          dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let base = ptr else { return nil }

        let floatCount = total / MemoryLayout<Float32>.size
        return base.withMemoryRebound(to: Float32.self, capacity: floatCount) { fp in
            pcm16FromFloatSamples(fp, count: floatCount)
        }
    }

    private func pcm16FromFloatSamples(_ samples: UnsafePointer<Float32>, count: Int) -> Data {
        var out = Data(count: count * MemoryLayout<Int16>.size)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let clipped = max(-1, min(1, samples[i]))
                dst[i] = Int16(max(-32_768, min(32_767, Int32(clipped * 32_767))))
            }
        }
        return out
    }

    private func fire(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func notifyPassiveState(_ state: PassiveState) {
        guard mode == .passiveSystemAudio else { return }
        fire { self.onPassiveState?(state) }
    }

    private func passiveStateAfterServerError() -> PassiveState {
        if passiveAudioPaused { return .paused }
        if passiveCaptureActive, isRealtimeReady { return .listening }
        return .unavailable
    }

    private var modeLabel: String {
        switch mode {
        case .passiveSystemAudio: return "passive"
        case .pushToTalkSystemAudio: return "instant"
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        DevLog.log("RealtimeAudio", "\(modeLabel): \(message())")
    }

    private func eventType(_ event: [String: Any]) -> String {
        (event["type"] as? String) ?? "unknown"
    }

    private func serverEventSummary(type: String, object: [String: Any]) -> String {
        switch type {
        case "response.output_text.delta":
            return "\(type) chars=\((object["delta"] as? String)?.count ?? 0)"
        case "error":
            return "\(type) message=\(errorMessage(from: object) ?? "nil")"
        case "response.done":
            return "\(type)"
        case "session.created", "session.updated":
            if let session = object["session"] as? [String: Any],
               let id = session["id"] as? String {
                return "\(type) sessionID=\(id)"
            }
            return type
        default:
            return type
        }
    }

    private var isStopped: Bool {
        locked { stopped }
    }

    private var isRealtimeReady: Bool {
        locked { realtimeReady }
    }

    private var hasResponseInFlight: Bool {
        locked { responseInFlight }
    }

    private var currentWebSocketTask: URLSessionWebSocketTask? {
        locked { wsTask }
    }

    private func locked<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    private func scheduleSessionRotation(after delay: TimeInterval? = nil) {
        guard !isStopped else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleSessionRotation(after: delay)
            }
            return
        }
        rotationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.rotateSessionIfIdle()
        }
        rotationWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (delay ?? sessionRotationInterval),
            execute: item
        )
    }

    private func rotateSessionIfIdle() {
        guard !isStopped else { return }
        if mode == .pushToTalkSystemAudio, isRecordingPushToTalk {
            scheduleSessionRotation(after: rotationRetryInterval)
            return
        }
        restartConnection(reason: "scheduled session refresh")
    }

    private func scheduleReconnect(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleReconnect(reason: reason)
            }
            return
        }
        guard !isStopped, reconnectWorkItem == nil else { return }
        notifyPassiveState(.reconnecting)
        let attempt = locked {
            reconnectAttempt += 1
            return reconnectAttempt
        }
        guard attempt <= maxReconnectAttempts else {
            fire { self.onError?("Realtime could not reconnect after \(self.maxReconnectAttempts) attempts.") }
            return
        }

        let delay = min(30, pow(2.0, Double(max(0, attempt - 1))))
        fire { self.onStatus?("Realtime reconnecting in \(Int(delay))s...") }
        let item = DispatchWorkItem { [weak self] in
            self?.reconnectWorkItem = nil
            self?.restartConnection(reason: reason)
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func restartConnection(reason: String) {
        guard !isStopped else { return }
        log("restartConnection reason=\(reason)")
        notifyPassiveState(.reconnecting)
        fire { self.onStatus?("Realtime reconnecting (\(reason))...") }
        receiveTask?.cancel()
        receiveTask = nil
        rotationWorkItem?.cancel()
        rotationWorkItem = nil

        let oldTask = locked {
            realtimeReady = false
            didSendSessionUpdate = false
            responseInFlight = false
            let current = wsTask
            wsTask = nil
            return current
        }
        oldTask?.cancel(with: .goingAway, reason: nil)
        clearPassiveSendBacklog()

        do {
            try connectWebSocket()
        } catch {
            log("restartConnection failed error=\(error.localizedDescription)")
            fire { self.onError?("Realtime reconnect failed: \(error.localizedDescription)") }
            scheduleReconnect(reason: reason)
        }
    }

    private func reservePassiveAudioBytes(_ bytes: Int) -> Bool {
        var accepted = false
        var shouldReportDrop = false
        sendStateQueue.sync {
            if inFlightPassiveAudioBytes + bytes <= maxPassiveInFlightAudioBytes {
                inFlightPassiveAudioBytes += bytes
                accepted = true
            } else {
                droppedPassiveAudioChunks += 1
                shouldReportDrop = droppedPassiveAudioChunks == 1 || droppedPassiveAudioChunks % 100 == 0
            }
        }
        if shouldReportDrop {
            log("dropping passive audio due to send backpressure droppedChunks=\(droppedPassiveAudioChunks) inFlightBytes=\(inFlightPassiveAudioBytes)")
            fire { self.onStatus?("Realtime is catching up; dropping live audio briefly.") }
        }
        return accepted
    }

    private func releasePassiveAudioBytes(_ bytes: Int) {
        sendStateQueue.async {
            self.inFlightPassiveAudioBytes = max(0, self.inFlightPassiveAudioBytes - bytes)
        }
    }

    private func clearPassiveSendBacklog() {
        sendStateQueue.async {
            self.inFlightPassiveAudioBytes = 0
            self.droppedPassiveAudioChunks = 0
        }
    }

    private func notePassiveSample(bytes: Int) {
        passiveSampleBufferCount += 1
        passiveSampleByteCount += bytes
        let now = CFAbsoluteTimeGetCurrent()
        if passiveSampleBufferCount == 1 || now - passiveLastSampleLogAt >= 10 {
            passiveLastSampleLogAt = now
            log("passive audio samples=\(passiveSampleBufferCount) bytes=\(passiveSampleByteCount) ready=\(isRealtimeReady ? 1 : 0)")
        }
    }

    private func notePassiveAudioDroppedBeforeReady(bytes: Int) {
        passiveDroppedBeforeReady += 1
        if passiveDroppedBeforeReady == 1 || passiveDroppedBeforeReady % 100 == 0 {
            log("dropping passive audio before session.updated drops=\(passiveDroppedBeforeReady) lastBytes=\(bytes)")
        }
    }

    private func noteInstantSample(bytes: Int) {
        instantSampleBufferCount += 1
        instantSampleByteCount += bytes
        let now = CFAbsoluteTimeGetCurrent()
        if instantSampleBufferCount == 1 || now - instantLastSampleLogAt >= 5 {
            instantLastSampleLogAt = now
            log("instant system audio samples=\(instantSampleBufferCount) bytes=\(instantSampleByteCount)")
        }
    }
}

extension RealtimeAudioAIController: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, !isStopped else { return }
        guard stream === scStream else { return }
        guard let pcm16 = pcm16FromSampleBuffer(sampleBuffer) else { return }
        switch mode {
        case .passiveSystemAudio:
            guard !passiveAudioPaused else { return }
            notePassiveSample(bytes: pcm16.count)
            sendAudioAppend(pcm16, live: true)
        case .pushToTalkSystemAudio:
            guard isRecordingPushToTalk else { return }
            noteInstantSample(bytes: pcm16.count)
            appendPushToTalkSystemAudio(pcm16)
        }
    }
}

enum RealtimeAudioAIError: LocalizedError {
    case invalidURL, noDisplay

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid OpenAI Realtime URL"
        case .noDisplay:  return "No display found for system audio capture"
        }
    }
}

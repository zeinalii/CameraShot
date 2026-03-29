import Foundation
import ScreenCaptureKit

// MARK: - TranscriptionController

/// Connects to a local faster-whisper WebSocket server, streams system audio,
/// and returns live transcripts via callbacks (no AI, no playback).
final class TranscriptionController: NSObject {

    // MARK: – Callbacks (always called on the main thread)

    /// Fired for every transcript message. Second argument is `true` when `is_final` from the server.
    var onTranscript: ((String, Bool) -> Void)?
    /// Fired on any connection or audio error.
    var onError: ((String) -> Void)?

    // MARK: – Init

    private let config: VoiceConfig

    init(config: VoiceConfig) {
        self.config = config
    }

    // MARK: – Control

    func start() async throws {
        try connectWebSocket()
        try await startSystemAudioCapture()
    }

    func stop() {
        stopped = true
        receiveTask?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        scStream?.stopCapture { _ in }
        scStream = nil
    }

    // MARK: – Private state

    private var wsTask: URLSessionWebSocketTask?
    private let urlSession = URLSession(configuration: .ephemeral)
    private var receiveTask: Task<Void, Never>?
    private var stopped = false

    private var scStream: SCStream?

    // MARK: – WebSocket

    private func connectWebSocket() throws {
        guard let url = URL(string: config.serverURL) else {
            throw TranscriptionError.invalidURL
        }
        let req = URLRequest(url: url)
        wsTask = urlSession.webSocketTask(with: req)
        wsTask?.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    private func sendAudioChunk(_ pcm16: Data) {
        guard !stopped, !pcm16.isEmpty else { return }
        wsTask?.send(.data(pcm16)) { _ in }
    }

    // MARK: – Receive loop

    private func receiveLoop() async {
        while !stopped {
            guard let task = wsTask else { break }
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let s): handleMessage(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { handleMessage(s) }
                @unknown default: break
                }
            } catch {
                guard !stopped else { return }
                fire { [weak self] in
                    self?.onError?("Connection lost: \(error.localizedDescription)")
                }
                break
            }
        }
    }

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == "transcript",
              let text = obj["text"] as? String else { return }

        let isFinal = obj["is_final"] as? Bool ?? true
        fire { [weak self] in self?.onTranscript?(text, isFinal) }
    }

    // MARK: – System audio capture (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw TranscriptionError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio        = true
        cfg.sampleRate           = 24_000
        cfg.channelCount         = 1
        cfg.width                = 2
        cfg.height               = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        scStream = stream
        try stream.addStreamOutput(self, type: .audio,
                                   sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
    }

    // MARK: – Helpers

    private func fire(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

// MARK: - SCStreamOutput

extension TranscriptionController: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, !stopped else { return }
        guard let pcm16 = pcm16FromSampleBuffer(sampleBuffer) else { return }
        sendAudioChunk(pcm16)
    }

    /// ScreenCaptureKit delivers Float32 PCM; convert to Int16 for the server.
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
            var out = Data(count: floatCount * 2)
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self)
                for i in 0..<floatCount {
                    dst[i] = Int16(max(-32_768, min(32_767, Int32(fp[i] * 32_767))))
                }
            }
            return out
        }
    }
}

// MARK: - TranscriptionError

enum TranscriptionError: LocalizedError {
    case invalidURL, noDisplay
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid transcription server URL"
        case .noDisplay:  return "No display found for system audio capture"
        }
    }
}

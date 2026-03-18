import ScreenCaptureKit
import CoreImage
import ImageIO
import Metal
import Foundation

// MARK: - ScreenTarget

enum ScreenTarget {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

// MARK: - ScreenCaptureController

final class ScreenCaptureController: NSObject {

    // MARK: – Public

    var onScreenshotSaved: ((URL, Int) -> Void)?
    /// Throttled preview frames (~10 fps) delivered on the main thread.
    var onPreviewFrame: ((CGImage) -> Void)?

    // MARK: – Private

    private let target: ScreenTarget

    private let captureQueue = DispatchQueue(label: "shot.screen.capture", qos: .userInteractive)
    private let saveQueue    = DispatchQueue(label: "shot.screen.save",    qos: .utility)

    private let interval:    TimeInterval
    private let jpegQuality: Double

    private var lastSaveTime:    CFAbsoluteTime = 0
    private var lastPreviewTime: CFAbsoluteTime = 0
    private var saveCount = 0

    /// Rolling buffer — oldest file deleted once count exceeds maxFiles.
    private var savedFiles: [URL] = []
    private let maxFiles    = 30

    private let outputDir: URL
    private let ciContext: CIContext
    private var stream: SCStream?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: – Init

    init(target: ScreenTarget, interval: TimeInterval, jpegQuality: Double = 0.92, outputDir: URL) {
        self.target      = target
        self.interval    = interval
        self.jpegQuality = jpegQuality
        self.outputDir   = outputDir

        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: mtlDevice, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        }

        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        super.init()
    }

    // MARK: – Control

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter:    SCContentFilter
        let cfgWidth:  Int
        let cfgHeight: Int

        switch target {

        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenCaptureError.targetNotFound
            }
            let scale = screenScale(forDisplayID: id)
            filter    = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            cfgWidth  = Int(Double(display.width)  * scale)
            cfgHeight = Int(Double(display.height) * scale)

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ScreenCaptureError.targetNotFound
            }
            let scale = screenScale(forWindowFrame: window.frame)
            filter    = SCContentFilter(desktopIndependentWindow: window)
            cfgWidth  = max(100, Int(window.frame.width  * scale))
            cfgHeight = max(100, Int(window.frame.height * scale))
        }

        let config = SCStreamConfiguration()
        config.width                = cfgWidth
        config.height               = cfgHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth           = 3
        config.pixelFormat          = kCVPixelFormatType_32BGRA
        config.showsCursor          = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        Task { try? await stream?.stopCapture() }
    }

    // MARK: – Helpers

    private func screenScale(forDisplayID id: CGDirectDisplayID) -> Double {
        Double(NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        })?.backingScaleFactor ?? 1.0)
    }

    private func screenScale(forWindowFrame frame: CGRect) -> Double {
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        return Double(NSScreen.screens.first(where: { $0.frame.contains(mid) })?.backingScaleFactor ?? 1.0)
    }

    // MARK: – Errors

    enum ScreenCaptureError: LocalizedError {
        case targetNotFound

        var errorDescription: String? {
            "The selected display or window could not be found. It may have been closed or disconnected."
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureController: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Screen capture stopped: \(error.localizedDescription)\n", stderr)
    }
}

// MARK: - SCStreamOutput

extension ScreenCaptureController: SCStreamOutput {

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = CFAbsoluteTimeGetCurrent()

        // Throttled preview (~10 fps).
        if now - lastPreviewTime >= 0.10 {
            lastPreviewTime = now
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                DispatchQueue.main.async { [weak self] in self?.onPreviewFrame?(cg) }
            }
        }

        guard now - lastSaveTime >= interval else { return }
        lastSaveTime = now

        saveQueue.async { [weak self, pixelBuffer] in self?.persistFrame(pixelBuffer) }
    }

    private func persistFrame(_ pixelBuffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }

        let usePNG = jpegQuality >= 1.0
        let prefix = if case .window = target { "win" } else { "scr" }
        let ts     = dateFormatter.string(from: Date())
        let url    = outputDir.appendingPathComponent("\(prefix)_\(ts).\(usePNG ? "png" : "jpg")")
        let uti    = usePNG ? "public.png" : "public.jpeg"

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else { return }
        let props: CFDictionary? = usePNG ? nil : [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(dest, cg, props)
        guard CGImageDestinationFinalize(dest) else { return }

        // Rolling buffer: keep only the last `maxFiles` screenshots.
        savedFiles.append(url)
        if savedFiles.count > maxFiles {
            let oldest = savedFiles.removeFirst()
            try? FileManager.default.removeItem(at: oldest)
        }

        saveCount += 1
        let n = saveCount
        print("[\(n)] Saved: \(url.lastPathComponent)")
        DispatchQueue.main.async { [weak self] in self?.onScreenshotSaved?(url, n) }
    }
}

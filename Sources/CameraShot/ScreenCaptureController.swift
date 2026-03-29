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

/// Takes one-shot screenshots at a fixed interval using ScreenCaptureKit.
final class ScreenCaptureController: NSObject {

    // MARK: – Public

    var onScreenshotSaved: ((URL, Int) -> Void)?
    /// Capture gate from app flow-control (e.g. AI queue backpressure).
    var shouldCaptureFrame: (() -> Bool)?

    // MARK: – Private

    private let target:      ScreenTarget
    private let saveQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "shot.screen.save"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let interval:    TimeInterval
    private let jpegQuality: Double
    private var saveCount  = 0
    private let changeFilter = FrameChangeFilter(minimumChangedRatio: 0.03)
    private var savedFiles:  [URL] = []
    private let maxFiles   = 30
    private let outputDir:   URL
    private let ciContext:   CIContext

    private var captureTask: Task<Void, Never>?
    private var sleepTask:   Task<Void, Error>?
    private var immediateRequested = false

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
        let filter = try await buildFilter()
        captureTask = Task { [weak self] in
            await self?.captureLoop(filter: filter)
        }
    }

    func stop() {
        captureTask?.cancel()
        sleepTask?.cancel()
        captureTask = nil
        sleepTask   = nil
    }

    /// Wakes the interval sleep so the next screenshot fires immediately.
    func requestImmediateCapture() {
        immediateRequested = true
        sleepTask?.cancel()
    }

    // MARK: – Capture loop

    private func captureLoop(filter: SCContentFilter) async {
        while !Task.isCancelled {
            if shouldCaptureFrame?() ?? true {
                await takeScreenshot(filter: filter)
            }

            // Skip sleep if an immediate capture was requested before we got here.
            guard !immediateRequested else {
                immediateRequested = false
                continue
            }

            let st = Task { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            sleepTask = st
            try? await st.value
        }
    }

    private func takeScreenshot(filter: SCContentFilter) async {
        let config = SCStreamConfiguration()
        config.showsCursor = true
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(filter.contentRect.width * scale))
        config.height = max(1, Int(filter.contentRect.height * scale))

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            saveQueue.addOperation(PersistImageOperation(controller: self, image: image))
        } catch {
            fputs("Screenshot failed: \(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: – Persistence

    fileprivate func persistImage(_ cgImage: CGImage) {
        guard changeFilter.shouldAccept(cgImage) else {
            print("Skipped: frame difference below 3%")
            return
        }

        let usePNG = jpegQuality >= 1.0
        let prefix = if case .window = target { "win" } else { "scr" }
        let ts     = dateFormatter.string(from: Date())
        let url    = outputDir.appendingPathComponent("\(prefix)_\(ts).\(usePNG ? "png" : "jpg")")
        let uti    = usePNG ? "public.png" : "public.jpeg"

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else { return }
        let props: CFDictionary? = usePNG ? nil : [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(dest, cgImage, props)
        guard CGImageDestinationFinalize(dest) else { return }

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

    // MARK: – Filter builder

    private func buildFilter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenCaptureError.targetNotFound
            }
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ScreenCaptureError.targetNotFound
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    // MARK: – Helpers

    enum ScreenCaptureError: LocalizedError {
        case targetNotFound
        var errorDescription: String? {
            "The selected display or window could not be found. It may have been closed or disconnected."
        }
    }

}

private final class PersistImageOperation: Operation, @unchecked Sendable {
    private weak var controller: ScreenCaptureController?
    private let image: CGImage

    init(controller: ScreenCaptureController, image: CGImage) {
        self.controller = controller
        self.image = image
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }
        controller?.persistImage(image)
    }
}

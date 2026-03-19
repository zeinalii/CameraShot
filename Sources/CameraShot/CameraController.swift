import AVFoundation
import CoreImage
import ImageIO
import Metal
import Foundation

final class CameraController: NSObject {

    // MARK: - Public

    let session: AVCaptureSession

    /// Invoked on the main thread after each screenshot is saved.
    var onScreenshotSaved: ((URL, Int) -> Void)?
    /// Capture gate from app flow-control (e.g. AI queue backpressure).
    var shouldCaptureFrame: (() -> Bool)?

    // MARK: - Private

    private let captureQueue = DispatchQueue(label: "shot.capture", qos: .userInteractive)
    private let saveQueue    = DispatchQueue(label: "shot.save",    qos: .utility)

    private let interval:     TimeInterval
    private let jpegQuality:  Double
    private var lastSaveTime: CFAbsoluteTime = 0
    private var saveCount     = 0
    private let changeFilter  = FrameChangeFilter(minimumChangedRatio: 0.03)

    /// Rolling buffer — oldest file is deleted once this exceeds maxFiles.
    private var savedFiles:   [URL] = []
    private let maxFiles      = 30

    private let outputDir: URL
    private let ciContext: CIContext

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Init

    init(device: AVCaptureDevice, interval: TimeInterval, jpegQuality: Double = 0.92, outputDir: URL) {
        self.interval    = interval
        self.jpegQuality = jpegQuality
        self.outputDir   = outputDir

        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: mtlDevice, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        }

        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        session = AVCaptureSession()
        super.init()
        configureSession(device: device)
    }

    // MARK: - Control

    func start() { captureQueue.async { self.session.startRunning() } }
    func stop()  { session.stopRunning() }
    /// Allows next frame to bypass interval timing gate once.
    func requestImmediateCapture() {
        captureQueue.async { [weak self] in
            self?.lastSaveTime = 0
        }
    }

    // MARK: - Session setup

    private func configureSession(device: AVCaptureDevice) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for preset in [AVCaptureSession.Preset.hd4K3840x2160, .hd1920x1080, .high] {
            if session.canSetSessionPreset(preset) { session.sessionPreset = preset; break }
        }

        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        configureDevice(device)
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do { try device.lockForConfiguration() } catch { return }
        defer { device.unlockForConfiguration() }

        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
        if device.isFocusModeSupported(.continuousAutoFocus)              { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure)        { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSaveTime >= interval else { return }
        guard shouldCaptureFrame?() ?? true else { return }
        lastSaveTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        saveQueue.async { [weak self, pixelBuffer] in self?.persistFrame(pixelBuffer) }
    }

    private func persistFrame(_ pixelBuffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        guard changeFilter.shouldAccept(cg) else {
            print("Skipped: frame difference below 3%")
            return
        }

        let usePNG = jpegQuality >= 1.0
        let ts     = dateFormatter.string(from: Date())
        let url    = outputDir.appendingPathComponent("frame_\(ts).\(usePNG ? "png" : "jpg")")
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

import AppKit
import AVFoundation
import CryptoKit

// MARK: - CaptureSource

enum CaptureSource {
    case camera(AVCaptureDevice)
    case display(id: CGDirectDisplayID, name: String)
    case window(id: CGWindowID, name: String)
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var setupCtrl:   SetupWindowController?
    private var cameraCtrl:  CameraController?
    private var screenCtrl:  ScreenCaptureController?
    private var captureCtrl: CaptureWindowController?
    private var aiProcessor: AIProcessor?
    private var aiPaused = false
    /// Max number of concurrent AI responses; set to 1 for strict response-paced capture.
    private let responseQueueLimit = 1
    private let responseFlowStateQueue = DispatchQueue(label: "camerashot.response-flow.state")
    private var responseFlowEnabled = false
    private var inFlightResponses = 0

    // MARK: – Session key (derived from passphrase, held only in RAM)
    private var sessionKey:       SymmetricKey?
    private var sessionSalt:      Data?
    private var sessionAPIKey:    String?

    // MARK: – Voice / Audio AI controllers
    private var voiceCtrl:    TranscriptionController?
    private var audioAIProc:  AudioAIProcessor?

    func applicationDidFinishLaunching(_ _: Notification) {
        buildMenu()
        requestCameraPermission { [weak self] in self?.autoUnlock() }
    }

    /// Keep the app running when windows close so Stop can return to setup reliably.
    func applicationShouldTerminateAfterLastWindowClosed(_ _: NSApplication) -> Bool { false }

    // MARK: – Auto-unlock

    /// Derives the session key from the active passphrase (machine UUID by default).
    /// If an encrypted key file exists, tries to decrypt it immediately — no window shown.
    private func autoUnlock() {
        let passphrase = PassphraseManager.activePassphrase

        if EncryptedKeyStore.fileExists() {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let (apiKey, key, salt) = try EncryptedKeyStore.load(passphrase: passphrase)
                    DispatchQueue.main.async { [weak self] in
                        self?.sessionKey       = key
                        self?.sessionSalt      = salt
                        self?.sessionAPIKey    = apiKey
                        self?.showSetup()
                    }
                } catch {
                    EncryptedKeyStore.delete()
                    DispatchQueue.main.async { [weak self] in
                        self?.initFreshSession(passphrase: passphrase)
                        self?.showSetup()
                    }
                }
            }
        } else {
            initFreshSession(passphrase: passphrase)
            showSetup()
        }
    }

    private func initFreshSession(passphrase: String) {
        let salt    = EncryptedKeyStore.generateSalt()
        sessionKey  = EncryptedKeyStore.deriveKey(passphrase: passphrase, salt: salt)
        sessionSalt = salt
        sessionAPIKey = nil
    }

    // MARK: – Menu

    private func buildMenu() {
        let bar  = NSMenu()
        let item = NSMenuItem()
        let menu = NSMenu(title: "CameraShot")
        menu.addItem(withTitle: "Settings…",       action: #selector(openSettings),               keyEquivalent: ",")
        menu.addItem(withTitle: "AI Responses…",   action: #selector(showAIResults),              keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CameraShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        bar.addItem(item)
        NSApp.mainMenu = bar
    }

    @objc private func openSettings() {
        cameraCtrl?.stop(); screenCtrl?.stop()
        captureCtrl?.close()
        cameraCtrl = nil; screenCtrl = nil; captureCtrl = nil
        aiProcessor = nil
        voiceCtrl?.stop(); voiceCtrl = nil
        audioAIProc = nil
        configureResponseFlow(enabled: false)
        showSetup()
    }

    @objc private func showAIResults() {
        captureCtrl?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: – Setup window

    private func showSetup() {
        let wc = SetupWindowController()

        wc.saveAPIKey = { [weak self] raw in
            guard let key = self?.sessionKey, let salt = self?.sessionSalt else {
                throw SetupError.noSession
            }
            try EncryptedKeyStore.save(raw, key: key, salt: salt)
            self?.sessionAPIKey = raw
        }

        wc.onStart = { [weak self] source, interval, quality, outputDir, aiConfig, voiceConfig in
            self?.startCapture(source: source, interval: interval, quality: quality,
                               outputDir: outputDir, aiConfig: aiConfig, voiceConfig: voiceConfig)
        }
        setupCtrl = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: – AI

    private func makeAIProcessor(config: AIConfig, window: CaptureWindowController) -> AIProcessor? {
        guard config.enabled else { return nil }
        let proc = AIProcessor(
            config: config,
            apiKey: sessionAPIKey,
            maxConcurrentRequests: responseQueueLimit
        )
        proc.onResult = { [weak self, weak window] text, url in
            self?.releaseResponseSlot()
            window?.appendResult(response: text, imageURL: url)
        }
        proc.onStreamChunk = { [weak window] chunk, url in window?.appendStreamingChunk(chunk, imageURL: url) }
        proc.onError = { [weak self, weak window] msg, imageURL in
            self?.releaseResponseSlot()
            window?.appendError(msg, imageURL: imageURL)
        }
        return proc
    }

    // MARK: – Capture

    private func startCapture(
        source: CaptureSource, interval: TimeInterval,
        quality: Double, outputDir: URL, aiConfig: AIConfig, voiceConfig: VoiceConfig
    ) {
        configureResponseFlow(enabled: aiConfig.enabled)
        clearPreviousScreenshots(in: outputDir)

        switch source {
        case .camera(let device):
            let ctrl = CameraController(device: device, interval: interval,
                                        jpegQuality: quality, outputDir: outputDir)
            ctrl.shouldCaptureFrame = { [weak self] in
                self?.canCaptureNextFrame() ?? false
            }
            let wc = CaptureWindowController(name: device.localizedName, interval: interval)
            aiProcessor = makeAIProcessor(config: aiConfig, window: wc)
            ctrl.onScreenshotSaved = { [weak self, weak wc] url, n in
                wc?.updateStatus(filename: url.lastPathComponent, count: n)
                self?.handleNewScreenshot(url, window: wc)
            }
            wc.onPauseAI = { [weak self] paused in self?.aiPaused = paused }
            wc.onStop = { [weak self, weak ctrl, weak wc] in
                ctrl?.stop()
                self?.aiProcessor = nil
                self?.aiPaused = false
                self?.voiceCtrl?.stop(); self?.voiceCtrl = nil
                self?.audioAIProc = nil
                self?.configureResponseFlow(enabled: false)
                self?.showSetup()
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async { wc?.close() }
            }
            cameraCtrl = ctrl; screenCtrl = nil; captureCtrl = wc
            setupCtrl?.close(); wc.showWindow(nil); ctrl.start()

        case .display(let id, let name):
            launchScreenCapture(target: .display(id), name: name,
                                interval: interval, quality: quality, outputDir: outputDir,
                                aiConfig: aiConfig, voiceConfig: voiceConfig)
        case .window(let id, let name):
            launchScreenCapture(target: .window(id), name: name,
                                interval: interval, quality: quality, outputDir: outputDir,
                                aiConfig: aiConfig, voiceConfig: voiceConfig)
        }

        startVoiceControllerIfNeeded(config: voiceConfig)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startVoiceControllerIfNeeded(config: VoiceConfig) {
        guard config.enabled else { return }

        // Transcription controller
        let vc = TranscriptionController(config: config)
        vc.onTranscript = { [weak self] text in
            self?.captureCtrl?.appendTranscript(text)
        }
        vc.onError = { [weak self] msg in
            self?.captureCtrl?.appendAudioError(msg)
        }
        voiceCtrl = vc
        Task { [weak vc, weak self] in
            do { try await vc?.start() }
            catch {
                await MainActor.run { [weak self] in
                    self?.captureCtrl?.appendAudioError(
                        "Voice setup failed: \(error.localizedDescription)")
                }
            }
        }

        // Audio AI processor — requires Anthropic key
        guard let apiKey = sessionAPIKey, !apiKey.isEmpty else { return }
        let proc = AudioAIProcessor(apiKey: apiKey, systemPrompt: config.audioAIPrompt)
        proc.onChunk = { [weak self] chunk in self?.captureCtrl?.appendAudioAIChunk(chunk) }
        proc.onDone  = { [weak self] in self?.captureCtrl?.finalizeAudioAI() }
        proc.onError = { [weak self] msg in self?.captureCtrl?.appendAudioAIError(msg) }
        audioAIProc = proc

        // Wire the Ask AI button + interval timer
        captureCtrl?.audioAITokenLimit = config.transcriptTokenLimit
        captureCtrl?.onAudioAIRequest = { [weak proc] transcript in
            proc?.query(transcript: transcript)
        }
        captureCtrl?.startAudioAITimer()
    }

    private func launchScreenCapture(
        target: ScreenTarget, name: String,
        interval: TimeInterval, quality: Double, outputDir: URL,
        aiConfig: AIConfig, voiceConfig: VoiceConfig
    ) {
        let ctrl = ScreenCaptureController(target: target, interval: interval,
                                           jpegQuality: quality, outputDir: outputDir)
        ctrl.shouldCaptureFrame = { [weak self] in
            self?.canCaptureNextFrame() ?? false
        }
        let wc = CaptureWindowController(name: name, interval: interval)
        aiProcessor = makeAIProcessor(config: aiConfig, window: wc)
        ctrl.onScreenshotSaved = { [weak self, weak wc] url, n in
            wc?.updateStatus(filename: url.lastPathComponent, count: n)
            self?.handleNewScreenshot(url, window: wc)
        }
        wc.onPauseAI = { [weak self] paused in self?.aiPaused = paused }
        wc.onStop = { [weak self, weak ctrl, weak wc] in
            ctrl?.stop()
            self?.aiProcessor = nil
            self?.aiPaused = false
            self?.voiceCtrl?.stop(); self?.voiceCtrl = nil
            self?.configureResponseFlow(enabled: false)
            self?.showSetup()
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { wc?.close() }
        }
        screenCtrl = ctrl; cameraCtrl = nil; captureCtrl = wc
        setupCtrl?.close(); wc.showWindow(nil)
        Task { [weak self] in
            do { try await ctrl.start() }
            catch { await MainActor.run { [weak self] in self?.showScreenCaptureError(error) } }
        }
    }

    private func handleNewScreenshot(_ url: URL, window: CaptureWindowController?) {
        guard let proc = aiProcessor, !aiPaused else { return }
        guard reserveResponseSlotIfPossible() else { return }
        window?.markProcessingStarted(imageURL: url)
        proc.process(imageURL: url)
    }

    // MARK: – Response pacing / capture flow

    private func configureResponseFlow(enabled: Bool) {
        responseFlowStateQueue.sync {
            responseFlowEnabled = enabled
            inFlightResponses = 0
        }
    }

    private func canCaptureNextFrame() -> Bool {
        responseFlowStateQueue.sync {
            !responseFlowEnabled || inFlightResponses < responseQueueLimit
        }
    }

    private func reserveResponseSlotIfPossible() -> Bool {
        responseFlowStateQueue.sync {
            guard responseFlowEnabled else { return true }
            guard inFlightResponses < responseQueueLimit else { return false }
            inFlightResponses += 1
            return true
        }
    }

    private func releaseResponseSlot() {
        var shouldTriggerCapture = false
        responseFlowStateQueue.sync {
            guard responseFlowEnabled else { return }
            inFlightResponses = max(0, inFlightResponses - 1)
            shouldTriggerCapture = inFlightResponses < responseQueueLimit
        }
        guard shouldTriggerCapture else { return }
        cameraCtrl?.requestImmediateCapture()
        screenCtrl?.requestImmediateCapture()
    }

    private func clearPreviousScreenshots(in outputDir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let files = try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            let ext = file.pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg" || ext == "png" else { continue }
            let name = file.lastPathComponent.lowercased()
            let isCaptureFile = name.hasPrefix("frame_") || name.hasPrefix("scr_") || name.hasPrefix("win_")
            guard isCaptureFile else { continue }
            try? fm.removeItem(at: file)
        }
    }

    // MARK: – Permissions / errors

    private func requestCameraPermission(then action: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: action()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { action() } else { self?.showCameraDeniedAndQuit() }
                }
            }
        default: showCameraDeniedAndQuit()
        }
    }

    private func showCameraDeniedAndQuit() {
        let alert = NSAlert()
        alert.messageText = "Camera Access Required"
        alert.informativeText = "CameraShot needs camera access to capture from your camera. Please enable it in System Settings → Privacy & Security → Camera, then relaunch."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
            )
        }
        NSApp.terminate(nil)
    }

    private func showScreenCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText     = "Screen Capture Failed"
        alert.informativeText = "\(error.localizedDescription)\n\nOpen System Settings → Privacy & Security → Screen Recording and enable CameraShot, then relaunch."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
    }
}

// MARK: - SetupError

enum SetupError: LocalizedError {
    case noSession
    var errorDescription: String? {
        "Session not initialised — restart the app."
    }
}

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

    // MARK: – Session key (derived from passphrase, held only in RAM)
    private var sessionKey:    SymmetricKey?
    private var sessionSalt:   Data?
    private var sessionAPIKey: String?   // decrypted API key for this launch

    func applicationDidFinishLaunching(_ _: Notification) {
        buildMenu()
        requestCameraPermission { [weak self] in self?.autoUnlock() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ _: NSApplication) -> Bool { true }

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
                        self?.sessionKey    = key
                        self?.sessionSalt   = salt
                        self?.sessionAPIKey = apiKey
                        self?.showSetup()
                    }
                } catch {
                    // Passphrase was changed externally or file is corrupt.
                    // Wipe the stale file and start fresh.
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

        wc.onStart = { [weak self] source, interval, quality, outputDir, aiConfig in
            self?.startCapture(source: source, interval: interval, quality: quality,
                               outputDir: outputDir, aiConfig: aiConfig)
        }
        setupCtrl = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: – AI

    private func makeAIProcessor(config: AIConfig, window: CaptureWindowController) -> AIProcessor? {
        guard config.enabled else { return nil }
        let proc = AIProcessor(config: config, apiKey: sessionAPIKey)
        proc.onResult = { [weak window] text, url in window?.appendResult(response: text, imageURL: url) }
        proc.onError  = { [weak window] msg        in window?.appendError(msg) }
        return proc
    }

    // MARK: – Capture

    private func startCapture(
        source: CaptureSource, interval: TimeInterval,
        quality: Double, outputDir: URL, aiConfig: AIConfig
    ) {
        switch source {
        case .camera(let device):
            let ctrl = CameraController(device: device, interval: interval,
                                        jpegQuality: quality, outputDir: outputDir)
            let wc   = CaptureWindowController(source: .camera(ctrl.session),
                                               name: device.localizedName, interval: interval)
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
                wc?.close()
                self?.showSetup()
            }
            cameraCtrl = ctrl; screenCtrl = nil; captureCtrl = wc
            setupCtrl?.close(); wc.showWindow(nil); ctrl.start()

        case .display(let id, let name):
            launchScreenCapture(target: .display(id), name: name,
                                interval: interval, quality: quality, outputDir: outputDir,
                                aiConfig: aiConfig)
        case .window(let id, let name):
            launchScreenCapture(target: .window(id), name: name,
                                interval: interval, quality: quality, outputDir: outputDir,
                                aiConfig: aiConfig)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func launchScreenCapture(
        target: ScreenTarget, name: String,
        interval: TimeInterval, quality: Double, outputDir: URL,
        aiConfig: AIConfig
    ) {
        let ctrl = ScreenCaptureController(target: target, interval: interval,
                                           jpegQuality: quality, outputDir: outputDir)
        let wc   = CaptureWindowController(source: .screen, name: name, interval: interval)
        aiProcessor = makeAIProcessor(config: aiConfig, window: wc)
        ctrl.onScreenshotSaved = { [weak self, weak wc] url, n in
            wc?.updateStatus(filename: url.lastPathComponent, count: n)
            self?.handleNewScreenshot(url, window: wc)
        }
        ctrl.onPreviewFrame = { [weak wc] img in wc?.updatePreviewImage(img) }
        wc.onPauseAI = { [weak self] paused in self?.aiPaused = paused }
        wc.onStop = { [weak self, weak ctrl, weak wc] in
            ctrl?.stop()
            self?.aiProcessor = nil
            self?.aiPaused = false
            wc?.close()
            self?.showSetup()
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
        window?.markProcessingStarted()
        proc.process(imageURL: url)
    }

    // MARK: – Permissions / errors

    private func requestCameraPermission(then action: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: action()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? action() : NSApp.terminate(nil) }
            }
        default: NSApp.terminate(nil)
        }
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

import AppKit
import AVFoundation
import CryptoKit
import Darwin

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
    private var sessionKey:       SymmetricKey?
    private var sessionSalt:      Data?
    private var sessionCredentials = AICredentials()

    // MARK: – Realtime Audio controllers
    private var passiveAudioCtrl: RealtimeAudioAIController?
    private var instantVoiceCtrl: RealtimeAudioAIController?
    private var instantVoice2Ctrl: RealtimeAudioAIController?
    private var chatCtrl: GPTChatController?
    private var windowPrivacyObserversInstalled = false
    private var documentsScopeURL: URL?
    private static let documentsAccessBookmarkKey = "documentsAccessBookmark"

    func applicationDidFinishLaunching(_ _: Notification) {
        installGlobalWindowPrivacyProtection()
        buildMenu()
        ensureDocumentsAccess { [weak self] in
            self?.requestCameraPermission { [weak self] in self?.autoUnlock() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureCtrl?.closeCurrentSession()
        aiProcessor?.cancel()
        cameraCtrl?.stop()
        screenCtrl?.stop()
        passiveAudioCtrl?.stop()
        instantVoiceCtrl?.stop()
        instantVoice2Ctrl?.stop()
        chatCtrl?.cancel()
        documentsScopeURL?.stopAccessingSecurityScopedResource()
        documentsScopeURL = nil
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
                    let (credentials, key, salt) = try EncryptedKeyStore.load(passphrase: passphrase)
                    DispatchQueue.main.async { [weak self] in
                        self?.sessionKey       = key
                        self?.sessionSalt      = salt
                        self?.sessionCredentials = credentials
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
        sessionCredentials = AICredentials()
    }

    // MARK: – Menu

    private func ensureDocumentsAccess(completion: @escaping () -> Void) {
        _ = restoreDocumentsAccessIfAvailable()
        completion()
    }

    private func restoreDocumentsAccessIfAvailable() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.documentsAccessBookmarkKey) else { return false }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard urlCoversDocumentsAccess(url) else {
                UserDefaults.standard.removeObject(forKey: Self.documentsAccessBookmarkKey)
                return false
            }
            guard url.startAccessingSecurityScopedResource() else {
                UserDefaults.standard.removeObject(forKey: Self.documentsAccessBookmarkKey)
                return false
            }
            documentsScopeURL?.stopAccessingSecurityScopedResource()
            documentsScopeURL = url
            if stale {
                persistDocumentsBookmark(for: url)
            }
            return true
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.documentsAccessBookmarkKey)
            return false
        }
    }

    private func persistDocumentsBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.documentsAccessBookmarkKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.documentsAccessBookmarkKey)
        }
    }

    private func promptForDocumentsAccess(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles       = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL         = preferredDocumentsDirectory().deletingLastPathComponent()
        panel.prompt               = "Grant Access"
        panel.message              = "Allow CameraShot to access your Documents folder. This is requested once and reused on next launches."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { completion(false); return }
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            guard self.urlCoversDocumentsAccess(url) else {
                NSLog("Documents access selection does not cover ~/Documents: %@", url.path)
                completion(false)
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                completion(false)
                return
            }
            self.documentsScopeURL?.stopAccessingSecurityScopedResource()
            self.documentsScopeURL = url
            self.persistDocumentsBookmark(for: url)
            completion(true)
        }
    }

    private func preferredDocumentsDirectory() -> URL {
        let homePath: String
        if let pw = getpwuid(getuid()), let cHome = pw.pointee.pw_dir {
            homePath = String(cString: cHome)
        } else if let home = NSHomeDirectoryForUser(NSUserName()) {
            homePath = home
        } else {
            homePath = NSHomeDirectory()
        }
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .standardizedFileURL
    }

    private func urlCoversDocumentsAccess(_ selectedURL: URL) -> Bool {
        let selectedPath = selectedURL.standardizedFileURL.resolvingSymlinksInPath().path
        let documentsPath = preferredDocumentsDirectory().resolvingSymlinksInPath().path
        return selectedPath == documentsPath || documentsPath.hasPrefix(selectedPath + "/")
    }

    private func installGlobalWindowPrivacyProtection() {
        guard !windowPrivacyObserversInstalled else { return }
        windowPrivacyObserversInstalled = true
        protectAllAppWindows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidAppear(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidAppear(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    @objc private func windowDidAppear(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        protectWindowFromCapture(window)
    }

    private func protectAllAppWindows() {
        NSApp.windows.forEach(protectWindowFromCapture(_:))
    }

    private func protectWindowFromCapture(_ window: NSWindow) {
        window.sharingType = .none
        (window.childWindows ?? []).forEach { $0.sharingType = .none }
    }

    private func buildMenu() {
        let bar  = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "CameraShot")
        appMenu.addItem(withTitle: "Settings…",       action: #selector(openSettings),               keyEquivalent: ",")
        appMenu.addItem(withTitle: "AI Responses…",   action: #selector(showAIResults),              keyEquivalent: "r")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit CameraShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = makeEditMenu()
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    @objc private func openSettings() {
        cameraCtrl?.stop(); screenCtrl?.stop()
        captureCtrl?.closeCurrentSession()
        captureCtrl?.close()
        aiProcessor?.cancel()
        cameraCtrl = nil; screenCtrl = nil; captureCtrl = nil
        aiProcessor = nil
        passiveAudioCtrl?.stop(); passiveAudioCtrl = nil
        instantVoiceCtrl?.stop(); instantVoiceCtrl = nil
        instantVoice2Ctrl?.stop(); instantVoice2Ctrl = nil
        chatCtrl?.cancel(); chatCtrl = nil
        showSetup()
    }

    @objc private func showAIResults() {
        captureCtrl?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: – Setup window

    private func showSetup() {
        let wc = SetupWindowController()

        wc.credentialStatus = { [weak self] in
            guard let credentials = self?.sessionCredentials else {
                return AICredentialStatus(hasGeminiKey: false, hasOpenAIKey: false)
            }
            return AICredentialStatus(
                hasGeminiKey: credentials.hasGeminiKey,
                hasOpenAIKey: credentials.hasOpenAIKey
            )
        }

        wc.saveAPIKey = { [weak self] provider, raw in
            guard let key = self?.sessionKey, let salt = self?.sessionSalt else {
                throw SetupError.noSession
            }
            guard var credentials = self?.sessionCredentials else {
                throw SetupError.noSession
            }
            credentials.setKey(raw, for: provider)
            try EncryptedKeyStore.save(credentials, key: key, salt: salt)
            self?.sessionCredentials = credentials
        }

        wc.removeAPIKey = { [weak self] provider in
            guard let key = self?.sessionKey, let salt = self?.sessionSalt else {
                throw SetupError.noSession
            }
            guard var credentials = self?.sessionCredentials else {
                throw SetupError.noSession
            }
            credentials.setKey(nil, for: provider)
            try EncryptedKeyStore.save(credentials, key: key, salt: salt)
            self?.sessionCredentials = credentials
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
        DevLog.log(
            "VisualAI",
            "makeAIProcessor enabled=\(config.enabled ? 1 : 0) model=\(config.model) geminiKey=\((sessionCredentials.geminiAPIKey?.isEmpty == false) ? 1 : 0) openAIKey=\((sessionCredentials.openAIAPIKey?.isEmpty == false) ? 1 : 0)"
        )
        guard config.enabled else {
            DevLog.log("VisualAI", "makeAIProcessor skipped because visual AI disabled")
            return nil
        }
        let proc = AIProcessor(
            config: config,
            credentials: sessionCredentials
        )
        proc.onProcessingStarted = { [weak window] url, retryIndex, maxRetries in
            window?.markProcessingStarted(imageURL: url, retryIndex: retryIndex, maxRetries: maxRetries)
        }
        proc.onStatus = { [weak window] status, url in
            window?.updateVisualStatus(status, imageURL: url)
        }
        proc.onStreamChunk = { [weak window] chunk, url in
            window?.appendStreamingChunk(chunk, imageURL: url)
        }
        proc.onReplaceResponse = { [weak window] text, url in
            window?.replaceStreamingContent(text, imageURL: url)
        }
        proc.onResult = { [weak window] text, url in
            window?.appendResult(response: text, imageURL: url)
        }
        proc.onError = { [weak window] msg, imageURL in
            window?.appendError(msg, imageURL: imageURL)
        }
        proc.onDiscard = { [weak window] url in
            window?.discardStreamingEntry(imageURL: url)
        }
        return proc
    }

    private func wireChatCallbacks(for window: CaptureWindowController) {
        window.onChatSend = { [weak self, weak window] message, attachmentURL in
            guard let self else { return }
            guard let chatCtrl = self.chatCtrl else {
                window?.appendChatError("No OpenAI API key is saved. Add it in the API Keys tab, then restart capture.")
                return
            }
            DevLog.log("Chat", "send requested chars=\(message.count) attachment=\(attachmentURL?.lastPathComponent ?? "nil")")
            chatCtrl.send(message, attachmentURL: attachmentURL)
        }
        window.onChatRestart = { [weak self, weak window] in
            DevLog.log("Chat", "restart requested from window")
            self?.chatCtrl?.restart()
            window?.setChatResponding(false)
        }
    }

    private func configureChatControllerForCurrentCapture() {
        let captureWindow = captureCtrl
        guard let apiKey = sessionCredentials.openAIAPIKey, !apiKey.isEmpty else {
            DevLog.log("Chat", "disabled: missing OpenAI API key")
            chatCtrl?.cancel()
            chatCtrl = nil
            captureWindow?.setChatAvailable(false)
            return
        }

        let chat = GPTChatController(apiKey: apiKey)
        chat.onChunk = { [weak captureWindow] chunk in
            captureWindow?.appendChatAssistantChunk(chunk)
        }
        chat.onDone = { [weak captureWindow] in
            captureWindow?.finalizeChatAssistant()
        }
        chat.onError = { [weak captureWindow] message in
            captureWindow?.appendChatError(message)
        }
        chat.onStatus = { message in
            DevLog.log("Chat", "status=\(message)")
        }
        chatCtrl = chat
        captureWindow?.setChatAvailable(true)
        DevLog.log("Chat", "enabled model=\(GPTChatController.model)")
    }

    // MARK: – Capture

    private func startCapture(
        source: CaptureSource, interval: TimeInterval,
        quality: Double, outputDir: URL, aiConfig: AIConfig, voiceConfig: RealtimeAudioConfig
    ) {
        clearPreviousScreenshots(in: outputDir)

        switch source {
        case .camera(let device):
            let ctrl = CameraController(device: device, interval: interval,
                                        jpegQuality: quality, outputDir: outputDir)
            if let error = ctrl.configurationError {
                showCameraCaptureError(error)
                return
            }
            ctrl.shouldCaptureFrame = { true }
            let wc = CaptureWindowController(name: device.localizedName, interval: interval)
            wireChatCallbacks(for: wc)
            aiProcessor = makeAIProcessor(config: aiConfig, window: wc)
            ctrl.onScreenshotSaved = { [weak self, weak wc] url, n in
                DevLog.log("Capture", "camera onScreenshotSaved count=\(n) file=\(url.lastPathComponent)")
                wc?.updateStatus(filename: url.lastPathComponent, count: n)
                wc?.noteLatestScreenshot(url)
                self?.handleNewScreenshot(url)
            }
            wc.onPauseAI = { [weak self] paused in self?.aiPaused = paused }
            wc.onAudioAIPauseChanged = { [weak self] paused in
                DevLog.log("RealtimeAudio", "passive pause changed paused=\(paused ? 1 : 0)")
                self?.passiveAudioCtrl?.setPassiveAudioPaused(paused)
            }
            wc.onRetryAI = { [weak self] in
                DevLog.log("VisualAI", "manual retry requested from camera window")
                self?.aiProcessor?.retryLatestScreenshot()
            }
            wc.onStop = { [weak self, weak ctrl, weak wc] in
                let stoppedWindow = wc
                ctrl?.stop()
                stoppedWindow?.closeCurrentSession()
                stoppedWindow?.close()
                guard let self else { return }
                self.aiProcessor?.cancel()
                self.aiProcessor = nil
                self.aiPaused = false
                self.passiveAudioCtrl?.stop(); self.passiveAudioCtrl = nil
                self.instantVoiceCtrl?.stop(); self.instantVoiceCtrl = nil
                self.instantVoice2Ctrl?.stop(); self.instantVoice2Ctrl = nil
                self.chatCtrl?.cancel(); self.chatCtrl = nil
                self.captureCtrl = nil
                self.showSetup()
                NSApp.activate(ignoringOtherApps: true)
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

        startRealtimeAudioControllersIfNeeded(config: voiceConfig)
        configureChatControllerForCurrentCapture()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startRealtimeAudioControllersIfNeeded(config: RealtimeAudioConfig) {
        DevLog.log(
            "RealtimeAudio",
            "start requested passiveEnabled=\(config.passiveEnabled ? 1 : 0) instantEnabled=\(config.instantEnabled ? 1 : 0) instant2Enabled=\(config.instant2Enabled ? 1 : 0) openAIKey=\((sessionCredentials.openAIAPIKey?.isEmpty == false) ? 1 : 0) passivePromptChars=\(config.passiveSystemPrompt.count) instantPromptChars=\(config.instantSystemPrompt.count) instant2PromptChars=\(config.instant2SystemPrompt.count)"
        )
        if config.instantEnabled {
            captureCtrl?.setInstantVoiceStarting()
        } else {
            captureCtrl?.setInstantVoiceAvailable(false)
        }
        if config.instant2Enabled {
            captureCtrl?.setInstantVoice2Starting()
        } else {
            captureCtrl?.setInstantVoice2Available(false)
        }
        if !config.passiveEnabled {
            captureCtrl?.updateAudioAIState(.unavailable)
        }
        guard config.enabled else {
            DevLog.log("RealtimeAudio", "start skipped: both Realtime audio checkboxes are off")
            return
        }
        guard let apiKey = sessionCredentials.openAIAPIKey, !apiKey.isEmpty else {
            DevLog.log("RealtimeAudio", "start failed: missing OpenAI API key")
            captureCtrl?.setInstantVoiceAvailable(false)
            captureCtrl?.setInstantVoice2Available(false)
            if config.passiveEnabled {
                captureCtrl?.updateAudioAIState(.unavailable)
                captureCtrl?.appendAudioAIError("No OpenAI API key is saved. Add it in the API Keys tab.")
            }
            if config.instantEnabled {
                captureCtrl?.appendInstantVoiceError("No OpenAI API key is saved. Add it in the API Keys tab.")
            }
            if config.instant2Enabled {
                captureCtrl?.appendInstantVoice2Error("No OpenAI API key is saved. Add it in the API Keys tab.")
            }
            return
        }

        let captureWindow = captureCtrl

        if config.passiveEnabled {
            let passive = RealtimeAudioAIController(
                apiKey: apiKey,
                systemPrompt: config.passiveSystemPrompt,
                mode: .passiveSystemAudio
            )
            passive.onChunk = { [weak captureWindow] chunk in captureWindow?.appendAudioAIChunk(chunk) }
            passive.onDone  = { [weak captureWindow] in captureWindow?.finalizeAudioAI() }
            passive.onError = { [weak captureWindow] msg in captureWindow?.appendAudioAIError(msg) }
            passive.onStatus = { msg in DevLog.log("RealtimeAudio", "passive status=\(msg)") }
            passive.onAudioLevel = { [weak captureWindow] level in
                captureWindow?.updateSystemAudioLevel(level)
            }
            passive.onPassiveState = { [weak captureWindow] state in
                DevLog.log("RealtimeAudio", "passive state=\(state)")
                captureWindow?.updateAudioAIState(state)
            }
            passiveAudioCtrl = passive
            captureCtrl?.onAudioAIManualTurnEnd = { [weak passive] in
                DevLog.log("RealtimeAudio", "passive manual turn-end requested")
                passive?.forcePassiveTurnEnd()
            }

            Task { [weak passive] in
                do { try await passive?.start() }
                catch {
                    DevLog.log("RealtimeAudio", "passive start failed error=\(error.localizedDescription)")
                    await MainActor.run {
                        captureWindow?.updateAudioAIState(.unavailable)
                        captureWindow?.appendAudioAIError(
                            "Passive Realtime setup failed: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            passiveAudioCtrl = nil
            captureCtrl?.onAudioAIManualTurnEnd = nil
        }

        if config.instantEnabled {
            let instant = RealtimeAudioAIController(
                apiKey: apiKey,
                systemPrompt: config.instantSystemPrompt,
                mode: .pushToTalkSystemAudio
            )
            instant.onChunk = { [weak captureWindow] chunk in captureWindow?.appendInstantVoiceChunk(chunk) }
            instant.onDone  = { [weak captureWindow] in captureWindow?.finalizeInstantVoice() }
            instant.onError = { [weak captureWindow] msg in captureWindow?.appendInstantVoiceError(msg) }
            instant.onStatus = { msg in DevLog.log("RealtimeAudio", "instant status=\(msg)") }
            instant.onReadyChanged = { [weak captureWindow] ready in
                DevLog.log("RealtimeAudio", "instant ready=\(ready ? 1 : 0)")
                if ready {
                    captureWindow?.setInstantVoiceAvailable(true)
                } else {
                    captureWindow?.setInstantVoiceStarting()
                }
            }
            instantVoiceCtrl = instant

            captureCtrl?.onInstantVoiceHoldChanged = { [weak instant] isHolding in
                DevLog.log("RealtimeAudio", "instant hold changed active=\(isHolding ? 1 : 0)")
                if isHolding {
                    instant?.beginPushToTalk()
                } else {
                    instant?.endPushToTalk()
                }
            }

            Task { [weak instant] in
                do { try await instant?.start() }
                catch {
                    DevLog.log("RealtimeAudio", "instant start failed error=\(error.localizedDescription)")
                    await MainActor.run {
                        captureWindow?.setInstantVoiceAvailable(false)
                        captureWindow?.appendInstantVoiceError(
                            "Instant Voice setup failed: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            instantVoiceCtrl = nil
            captureCtrl?.onInstantVoiceHoldChanged = nil
        }

        if config.instant2Enabled {
            let instant2 = RealtimeAudioAIController(
                apiKey: apiKey,
                systemPrompt: config.instant2SystemPrompt,
                mode: .pushToTalkSystemAudio
            )
            instant2.onChunk = { [weak captureWindow] chunk in captureWindow?.appendInstantVoice2Chunk(chunk) }
            instant2.onDone  = { [weak captureWindow] in captureWindow?.finalizeInstantVoice2() }
            instant2.onError = { [weak captureWindow] msg in captureWindow?.appendInstantVoice2Error(msg) }
            instant2.onStatus = { msg in DevLog.log("RealtimeAudio", "instant2 status=\(msg)") }
            instant2.onReadyChanged = { [weak captureWindow] ready in
                DevLog.log("RealtimeAudio", "instant2 ready=\(ready ? 1 : 0)")
                if ready {
                    captureWindow?.setInstantVoice2Available(true)
                } else {
                    captureWindow?.setInstantVoice2Starting()
                }
            }
            instantVoice2Ctrl = instant2

            captureCtrl?.onInstantVoice2HoldChanged = { [weak instant2] isHolding in
                DevLog.log("RealtimeAudio", "instant2 hold changed active=\(isHolding ? 1 : 0)")
                if isHolding {
                    instant2?.beginPushToTalk()
                } else {
                    instant2?.endPushToTalk()
                }
            }

            Task { [weak instant2] in
                do { try await instant2?.start() }
                catch {
                    DevLog.log("RealtimeAudio", "instant2 start failed error=\(error.localizedDescription)")
                    await MainActor.run {
                        captureWindow?.setInstantVoice2Available(false)
                        captureWindow?.appendInstantVoice2Error(
                            "Instant Audio2 setup failed: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            instantVoice2Ctrl = nil
            captureCtrl?.onInstantVoice2HoldChanged = nil
        }
    }

    private func launchScreenCapture(
        target: ScreenTarget, name: String,
        interval: TimeInterval, quality: Double, outputDir: URL,
        aiConfig: AIConfig, voiceConfig: RealtimeAudioConfig
    ) {
        let ctrl = ScreenCaptureController(target: target, interval: interval,
                                           jpegQuality: quality, outputDir: outputDir)
        ctrl.shouldCaptureFrame = { true }
        let wc = CaptureWindowController(name: name, interval: interval)
        wireChatCallbacks(for: wc)
        aiProcessor = makeAIProcessor(config: aiConfig, window: wc)
        ctrl.onScreenshotSaved = { [weak self, weak wc] url, n in
            DevLog.log("Capture", "screen onScreenshotSaved count=\(n) file=\(url.lastPathComponent)")
            wc?.updateStatus(filename: url.lastPathComponent, count: n)
            wc?.noteLatestScreenshot(url)
            self?.handleNewScreenshot(url)
        }
        wc.onPauseAI = { [weak self] paused in self?.aiPaused = paused }
        wc.onAudioAIPauseChanged = { [weak self] paused in
            DevLog.log("RealtimeAudio", "passive pause changed paused=\(paused ? 1 : 0)")
            self?.passiveAudioCtrl?.setPassiveAudioPaused(paused)
        }
        wc.onRetryAI = { [weak self] in
            DevLog.log("VisualAI", "manual retry requested from screen window")
            self?.aiProcessor?.retryLatestScreenshot()
        }
        wc.onStop = { [weak self, weak ctrl, weak wc] in
            let stoppedWindow = wc
            ctrl?.stop()
            stoppedWindow?.closeCurrentSession()
            stoppedWindow?.close()
            guard let self else { return }
            self.aiProcessor?.cancel()
            self.aiProcessor = nil
            self.aiPaused = false
            self.passiveAudioCtrl?.stop(); self.passiveAudioCtrl = nil
            self.instantVoiceCtrl?.stop(); self.instantVoiceCtrl = nil
            self.instantVoice2Ctrl?.stop(); self.instantVoice2Ctrl = nil
            self.chatCtrl?.cancel(); self.chatCtrl = nil
            self.captureCtrl = nil
            self.showSetup()
            NSApp.activate(ignoringOtherApps: true)
        }
        screenCtrl = ctrl; cameraCtrl = nil; captureCtrl = wc
        setupCtrl?.close(); wc.showWindow(nil)
        Task { [weak self] in
            do { try await ctrl.start() }
            catch { await MainActor.run { [weak self] in self?.showScreenCaptureError(error) } }
        }
    }

    private func handleNewScreenshot(_ url: URL) {
        DevLog.log("VisualAI", "handleNewScreenshot file=\(url.lastPathComponent) aiPaused=\(aiPaused ? 1 : 0) hasProcessor=\(aiProcessor == nil ? 0 : 1)")
        guard let proc = aiProcessor else {
            DevLog.log("VisualAI", "handleNewScreenshot ignored: no AI processor file=\(url.lastPathComponent)")
            return
        }
        guard !aiPaused else {
            DevLog.log("VisualAI", "handleNewScreenshot ignored: AI paused file=\(url.lastPathComponent)")
            return
        }
        DevLog.log("VisualAI", "handleNewScreenshot submitting file=\(url.lastPathComponent)")
        proc.process(imageURL: url)
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
        alert.window.sharingType = .none
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

    private func showCameraCaptureError(_ message: String) {
        let alert = NSAlert()
        alert.window.sharingType = .none
        alert.messageText = "Camera Capture Failed"
        alert.informativeText = "\(message)\n\nQuit apps that may be using the camera, then try again. If this is an iPhone/Continuity Camera, make sure it is awake and selected in the camera menu."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showScreenCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.window.sharingType = .none
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

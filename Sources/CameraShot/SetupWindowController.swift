import AppKit
import AVFoundation
import ScreenCaptureKit

// MARK: - SetupWindowController

final class SetupWindowController: NSWindowController {

    var onStart:    ((CaptureSource, TimeInterval, Double, URL, AIConfig) -> Void)?
    /// Encrypt and persist the raw API key using the current session.
    var saveAPIKey: ((String) throws -> Void)?

    // MARK: – Types

    private enum TabPage { case capture, prompts, apiKeys }

    private enum SourceType { case camera, screen }

    /// Stored in each popup menu item's representedObject.
    private enum CaptureTarget {
        case display(id: CGDirectDisplayID, name: String)
        case window(id: CGWindowID, appName: String, title: String, scWindow: SCWindow?)
    }

    // MARK: – State

    private var activePage:  TabPage   = .capture
    private var sourceType:  SourceType = .screen
    private var cameras: [AVCaptureDevice] = []

    /// Default save folder; no security-scoped bookmark needed (entitlement grants access).
    private static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraShot")
    }

    private var selectedOutputDir: URL = SetupWindowController.defaultOutputDirectory

    /// When non-nil, we have called startAccessingSecurityScopedResource and may write to this folder (sandbox).
    private var securityScopedOutputURL: URL?

    private static let screenshotOutputBookmarkKey = "screenshotOutputBookmark"

    private var previewSession: AVCaptureSession?
    private let previewQueue = DispatchQueue(label: "setup.preview", qos: .userInteractive)

    // MARK: – Outlets — shared

    private weak var tabControl: NSSegmentedControl!
    private weak var startButton: NSButton!

    // MARK: – Outlets — Capture tab

    private weak var captureStack:   NSStackView!
    private weak var livePreview:    DualPreviewView!
    private weak var sourceSegment:  NSSegmentedControl!
    private weak var pickerLabel:    NSTextField!
    private weak var cameraPopup:    NSPopUpButton!
    private weak var screenPopup:    NSPopUpButton!
    private weak var intervalSlider: NSSlider!
    private weak var intervalLabel:  NSTextField!
    private weak var qualityControl: NSSegmentedControl!
    private weak var folderField:    NSTextField!

    // MARK: – Outlets — Prompts tab

    private weak var promptsStack:       NSStackView!
    private weak var aiEnabledCheckbox:  NSButton!
    private weak var modelField:         NSTextField!
    private      var promptTextView:     NSTextView!   // strong: NSTextView inside scroll

    // MARK: – Outlets — API Keys tab

    private weak var apiKeysStack:   NSStackView!
    private weak var apiKeyField:    NSTextField!
    private weak var keyStatusLabel: NSTextField!

    // MARK: – Init

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title  = "CameraShot"
        win.center()
        win.isMovableByWindowBackground = true
        super.init(window: win)
        buildUI()
        refreshCameraList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if sourceType == .camera { startCameraPreview() } else { loadScreenContent() }
    }

    deinit { stopCameraPreview() }

    // MARK: – UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }
        restoreSavedOutputFolder()

        let fx = NSVisualEffectView()
        fx.material = .windowBackground; fx.blendingMode = .behindWindow
        fx.state    = .active; fx.autoresizingMask = [.width, .height]
        fx.frame    = content.bounds
        content.addSubview(fx)

        let root = vstack(spacing: 0)
        root.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        root.alignment  = .centerX
        fx.addSubview(root); pin(root, to: fx)

        // ── Header ───────────────────────────────────────────────
        let header = hstack(spacing: 8); header.alignment = .centerY
        if let img = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
            iv.contentTintColor = .controlAccentColor
            header.addArrangedSubview(iv)
        }
        header.addArrangedSubview(plainLabel("CameraShot", size: 22, weight: .bold))
        root.addArrangedSubview(header)
        root.setCustomSpacing(16, after: header)

        // ── Tab bar ──────────────────────────────────────────────
        let tabs = NSSegmentedControl(
            labels: ["Capture", "Prompts", "API Keys"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged)
        )
        tabs.selectedSegment = 0
        tabs.segmentStyle    = .automatic
        tabControl = tabs
        root.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalToConstant: 300).isActive = true
        root.setCustomSpacing(20, after: tabs)

        // ── Capture tab content ──────────────────────────────────
        root.addArrangedSubview(buildCaptureStack())
        root.setCustomSpacing(20, after: captureStack)

        // ── Prompts tab content (hidden initially) ───────────────
        root.addArrangedSubview(buildPromptsStack())
        root.setCustomSpacing(20, after: promptsStack)

        // ── API Keys tab content (hidden initially) ───────────────
        root.addArrangedSubview(buildApiKeysStack())
        root.setCustomSpacing(20, after: apiKeysStack)

        // ── Start button (always visible) ────────────────────────
        let btn = NSButton(title: "Start Capture", target: self, action: #selector(startTapped))
        btn.bezelStyle    = .rounded
        btn.controlSize   = .large
        btn.keyEquivalent = "\r"
        startButton = btn
        root.addArrangedSubview(btn)
        btn.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }

    // MARK: – Capture stack

    private func buildCaptureStack() -> NSStackView {
        let s = vstack(spacing: 0)
        s.alignment = .centerX

        // Source selector
        let seg = NSSegmentedControl(
            labels: ["Camera", "Screen"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(sourceChanged)
        )
        seg.selectedSegment = 1
        sourceSegment = seg
        s.addArrangedSubview(seg)
        seg.widthAnchor.constraint(equalToConstant: 200).isActive = true
        s.setCustomSpacing(16, after: seg)

        // Live preview
        let pv = DualPreviewView(); livePreview = pv
        s.addArrangedSubview(pv)
        NSLayoutConstraint.activate([
            pv.widthAnchor.constraint(equalToConstant:  376),
            pv.heightAnchor.constraint(equalToConstant: 168),
        ])
        s.setCustomSpacing(18, after: pv)

        // Picker label
        let pl = sectionLabel("Source"); pickerLabel = pl
        s.addArrangedSubview(pl); s.setCustomSpacing(5, after: pl)

        // Camera popup (hidden by default — screen is default)
        let camPop = NSPopUpButton(frame: .zero, pullsDown: false)
        camPop.target = self; camPop.action = #selector(cameraChanged)
        camPop.isHidden = true
        cameraPopup = camPop
        s.addArrangedSubview(camPop)
        camPop.widthAnchor.constraint(equalToConstant: 376).isActive = true

        // Screen popup (visible by default)
        let scrPop = NSPopUpButton(frame: .zero, pullsDown: false)
        scrPop.target = self; scrPop.action = #selector(screenSelectionChanged)
        screenPopup = scrPop
        s.addArrangedSubview(scrPop)
        scrPop.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(18, after: scrPop)

        // Interval
        let intRow = hstack(spacing: 0)
        intRow.addArrangedSubview(sectionLabel("Interval"))
        intRow.addArrangedSubview(hFlex())
        let valLbl = plainLabel("5s", size: 12, weight: .semibold)
        valLbl.textColor = .controlAccentColor; intervalLabel = valLbl
        intRow.addArrangedSubview(valLbl)
        s.addArrangedSubview(intRow)
        intRow.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(5, after: intRow)

        let slider = NSSlider(value: 5, minValue: 1, maxValue: 60,
                              target: self, action: #selector(intervalChanged))
        slider.isContinuous = true; intervalSlider = slider
        s.addArrangedSubview(slider)
        slider.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(4, after: slider)

        let tickRow = hstack(spacing: 0)
        let lo = plainLabel("1s",  size: 10, weight: .regular); lo.textColor = .tertiaryLabelColor
        let hi = plainLabel("60s", size: 10, weight: .regular); hi.textColor = .tertiaryLabelColor
        tickRow.addArrangedSubview(lo); tickRow.addArrangedSubview(hFlex()); tickRow.addArrangedSubview(hi)
        s.addArrangedSubview(tickRow)
        tickRow.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(18, after: tickRow)

        // Quality
        s.addArrangedSubview(sectionLabel("Output Quality"))
        s.setCustomSpacing(5, after: s.arrangedSubviews.last!)
        let qs = NSSegmentedControl(labels: ["Good  75%", "High  92%", "Max 100%"],
                                    trackingMode: .selectOne, target: nil, action: nil)
        qs.selectedSegment = 1; qualityControl = qs
        s.addArrangedSubview(qs)
        qs.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(18, after: qs)

        // Save folder
        s.addArrangedSubview(sectionLabel("Save Folder"))
        s.setCustomSpacing(5, after: s.arrangedSubviews.last!)

        let folderRow = hstack(spacing: 8)
        let ff = NSTextField(labelWithString: abbreviatedPath(selectedOutputDir))
        ff.lineBreakMode = .byTruncatingMiddle
        ff.textColor = .secondaryLabelColor
        ff.font = .systemFont(ofSize: 12)
        ff.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ff.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderField = ff
        folderRow.addArrangedSubview(ff)

        let browseBtn = NSButton(title: "Browse…", target: self, action: #selector(browseTapped))
        browseBtn.bezelStyle = .rounded
        browseBtn.setContentHuggingPriority(.required, for: .horizontal)
        folderRow.addArrangedSubview(browseBtn)

        s.addArrangedSubview(folderRow)
        folderRow.widthAnchor.constraint(equalToConstant: 376).isActive = true

        captureStack = s
        return s
    }

    // MARK: – Prompts stack

    private func buildPromptsStack() -> NSStackView {
        let s = vstack(spacing: 0)
        s.alignment = .centerX
        s.isHidden = true

        // Enable toggle
        let checkbox = NSButton(checkboxWithTitle: "Enable AI Processing",
                                target: self, action: #selector(aiToggled))
        checkbox.state = .on
        aiEnabledCheckbox = checkbox
        s.addArrangedSubview(checkbox)
        checkbox.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(22, after: checkbox)

        // Model
        s.addArrangedSubview(sectionLabel("Model"))
        s.setCustomSpacing(5, after: s.arrangedSubviews.last!)

        let mf = NSTextField(string: "claude-sonnet-4-5")
        mf.font = .systemFont(ofSize: 13)
        mf.placeholderString = "e.g. claude-sonnet-4-5, claude-3-5-sonnet-20241022"
        modelField = mf
        s.addArrangedSubview(mf)
        mf.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(18, after: mf)

        // Prompt
        s.addArrangedSubview(sectionLabel("Prompt"))
        s.setCustomSpacing(5, after: s.arrangedSubviews.last!)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller   = true
        scroll.autohidesScrollers    = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 376),
            scroll.heightAnchor.constraint(equalToConstant: 160),
        ])

        let tv = NSTextView()
        tv.font    = .systemFont(ofSize: 13)
        tv.string  = "try to solve this question that you see on the screen."
        tv.isEditable   = true
        tv.isSelectable = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        promptTextView = tv

        s.addArrangedSubview(scroll)
        s.setCustomSpacing(14, after: scroll)

        promptsStack = s
        return s
    }

    // MARK: – API Keys stack

    private func buildApiKeysStack() -> NSStackView {
        let s = vstack(spacing: 0)
        s.alignment = .centerX
        s.isHidden  = true

        // Title row
        let titleRow = hstack(spacing: 8); titleRow.alignment = .centerY
        if let img = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            iv.contentTintColor = .controlAccentColor
            titleRow.addArrangedSubview(iv)
        }
        titleRow.addArrangedSubview(plainLabel("Anthropic API Key", size: 15, weight: .semibold))
        s.addArrangedSubview(titleRow)
        s.setCustomSpacing(6, after: titleRow)

        let desc = NSTextField(wrappingLabelWithString:
            "Your key is encrypted with AES-256-GCM using your machine passphrase (UUID). " +
            "It is never stored as plain text — only decrypted in memory while the app is running.")
        desc.font      = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        s.addArrangedSubview(desc)
        desc.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(20, after: desc)

        // Plain editable text field — typing, Cmd+V, and right-click Paste all work normally.
        // The value is cleared from the field immediately after saving.
        s.addArrangedSubview(sectionLabel("API Key"))
        s.setCustomSpacing(5, after: s.arrangedSubviews.last!)

        let field = NSTextField(frame: .zero)
        field.placeholderString  = "sk-ant-api03-..."
        field.font               = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isEditable         = true
        field.isSelectable       = true
        field.isBezeled          = true
        field.bezelStyle         = .roundedBezel
        apiKeyField = field
        s.addArrangedSubview(field)
        field.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(10, after: field)

        // Save row
        let saveRow = hstack(spacing: 10); saveRow.alignment = .centerY
        let saveBtn = NSButton(title: "Save Key", target: self, action: #selector(saveKeyTapped))
        saveBtn.bezelStyle = .rounded
        saveRow.addArrangedSubview(saveBtn)

        let sl = NSTextField(labelWithString: "")
        sl.font          = .systemFont(ofSize: 12)
        sl.textColor     = .secondaryLabelColor
        sl.lineBreakMode = .byWordWrapping
        keyStatusLabel   = sl
        saveRow.addArrangedSubview(sl)
        s.addArrangedSubview(saveRow)
        saveRow.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(10, after: saveRow)

        // Remove button
        let removeBtn = NSButton(title: "Remove Saved Key", target: self, action: #selector(removeKeyTapped))
        removeBtn.bezelStyle       = .inline
        removeBtn.font             = .systemFont(ofSize: 11)
        removeBtn.contentTintColor = .systemRed
        s.addArrangedSubview(removeBtn)
        removeBtn.widthAnchor.constraint(equalToConstant: 376).isActive = true
        s.setCustomSpacing(22, after: removeBtn)

        
        apiKeysStack = s
        refreshKeyStatus()
        return s
    }

    private func refreshKeyStatus() {
        guard let sl = keyStatusLabel else { return }
        if EncryptedKeyStore.fileExists() {
            sl.stringValue = "✓ Key saved & encrypted"
            sl.textColor   = .systemGreen
        } else {
            sl.stringValue = "No key saved"
            sl.textColor   = .secondaryLabelColor
        }
    }

    @objc private func saveKeyTapped() {
        let raw = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            keyStatusLabel.stringValue = "Paste your key above first"
            keyStatusLabel.textColor   = .systemOrange
            return
        }
        guard let handler = saveAPIKey else {
            keyStatusLabel.stringValue = "⚠ Restart the app and enter your passphrase first"
            keyStatusLabel.textColor   = .systemRed
            return
        }
        do {
            try handler(raw)
            apiKeyField.stringValue    = ""
            keyStatusLabel.stringValue = "✓ Key saved & encrypted"
            keyStatusLabel.textColor   = .systemGreen
        } catch {
            keyStatusLabel.stringValue = "⚠ \(error.localizedDescription)"
            keyStatusLabel.textColor   = .systemRed
        }
    }

    @objc private func removeKeyTapped() {
        EncryptedKeyStore.delete()
        apiKeyField.stringValue    = ""
        keyStatusLabel.stringValue = "No key saved"
        keyStatusLabel.textColor   = .secondaryLabelColor
    }

    // MARK: – Tab switching

    @objc private func tabChanged() {
        let seg = tabControl.selectedSegment
        let page: TabPage = seg == 0 ? .capture : seg == 1 ? .prompts : .apiKeys
        guard page != activePage else { return }
        activePage = page
        captureStack.isHidden  = page != .capture
        promptsStack.isHidden  = page != .prompts
        apiKeysStack.isHidden  = page != .apiKeys

        // Refresh status label whenever the API Keys tab is shown.
        if page == .apiKeys { refreshKeyStatus() }
    }

    // MARK: – Folder picker

    private func abbreviatedPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
    }

    @objc private func browseTapped() {
        promptForSaveFolder { _ in }
    }

    private func restoreSavedOutputFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.screenshotOutputBookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { return }
            securityScopedOutputURL?.stopAccessingSecurityScopedResource()
            securityScopedOutputURL = url
            selectedOutputDir = url
            if stale {
                persistOutputBookmark(for: url)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.screenshotOutputBookmarkKey)
        }
    }

    private func persistOutputBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.screenshotOutputBookmarkKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.screenshotOutputBookmarkKey)
        }
    }

    /// Opens the folder picker. If user picks a folder, grants security-scoped access and calls completion(true). On cancel, completion(false).
    private func promptForSaveFolder(completion: @escaping (Bool) -> Void) {
        guard let win = window else { completion(false); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles       = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL         = selectedOutputDir
        panel.prompt               = "Choose"
        panel.message              = "Choose a folder to save screenshots into. The app needs your permission to write here."
        panel.beginSheetModal(for: win) { [weak self] response in
            guard let self else { completion(false); return }
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            self.securityScopedOutputURL?.stopAccessingSecurityScopedResource()
            self.securityScopedOutputURL = nil
            _ = url.startAccessingSecurityScopedResource()
            self.securityScopedOutputURL = url
            self.selectedOutputDir = url
            self.persistOutputBookmark(for: url)
            self.folderField?.stringValue = self.abbreviatedPath(url)
            completion(true)
        }
    }

    // MARK: – Camera

    private func refreshCameraList() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types += [.external, .continuityCamera] }
        else                         { types.append(.externalUnknown) }
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
        cameraPopup.removeAllItems()
        cameras.forEach { cameraPopup.addItem(withTitle: $0.localizedName) }
        startButton?.isEnabled = !cameras.isEmpty
    }

    private func startCameraPreview() {
        guard sourceType == .camera, !cameras.isEmpty else { return }
        let device = cameras[max(0, cameraPopup.indexOfSelectedItem)]
        previewQueue.async { [weak self] in self?.runCameraPreview(for: device) }
    }

    private func runCameraPreview(for device: AVCaptureDevice) {
        previewSession?.stopRunning()
        let session = AVCaptureSession()
        session.sessionPreset = .hd1920x1080
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        DispatchQueue.main.async { [weak self] in self?.livePreview.showCamera(session: session) }
        previewSession = session
        session.startRunning()
    }

    private func stopCameraPreview() {
        let session = previewSession
        previewSession = nil
        previewQueue.async {
            session?.stopRunning()
        }
    }

    // MARK: – Screen (unified displays + windows)

    private func loadScreenContent() {
        screenPopup.menu?.removeAllItems()
        screenPopup.addItem(withTitle: "Loading…")
        startButton.isEnabled = false

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                buildScreenMenu(displays: content.displays, windows: content.windows)
            } catch {
                screenPopup.menu?.removeAllItems()
                screenPopup.addItem(withTitle: "⚠  Grant access: System Settings → Screen Recording")
                startButton.isEnabled = false
            }
        }
    }

    private func buildScreenMenu(displays: [SCDisplay], windows: [SCWindow]) {
        screenPopup.menu?.removeAllItems()

        // ── Displays ─────────────────────────────────────────────
        screenPopup.menu?.addItem(makeSectionHeader("DISPLAYS"))

        for (i, d) in displays.enumerated() {
            let nsName = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID
            })?.localizedName ?? "Display \(i + 1)"
            let item = makePickerItem(
                title:  "\(nsName)  (\(d.width) × \(d.height))",
                symbol: "display",
                target: CaptureTarget.display(id: d.displayID, name: nsName)
            )
            screenPopup.menu?.addItem(item)
        }

        // ── Windows (excluding Dock and system chrome) ────────────
        let systemBundles: Set<String> = [
            "com.apple.dock",
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.WindowManager",
        ]

        let filtered = windows
            .filter {
                guard let app = $0.owningApplication else { return false }
                return $0.isOnScreen
                    && !($0.title ?? "").isEmpty
                    && $0.frame.width  > 80
                    && $0.frame.height > 60
                    && $0.windowLayer  == 0
                    && !systemBundles.contains(app.bundleIdentifier)
            }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }

        if !filtered.isEmpty {
            screenPopup.menu?.addItem(.separator())
            screenPopup.menu?.addItem(makeSectionHeader("WINDOWS"))

            var lastApp = ""
            for w in filtered {
                let appName = w.owningApplication?.applicationName ?? "Unknown"
                let title   = w.title ?? "Untitled"

                if appName != lastApp {
                    lastApp = appName
                    screenPopup.menu?.addItem(makeSectionHeader("  " + appName))
                }

                let item = makePickerItem(
                    title:  "      \(title)",
                    symbol: "macwindow",
                    target: CaptureTarget.window(id: w.windowID, appName: appName, title: title, scWindow: w)
                )
                screenPopup.menu?.addItem(item)
            }
        }

        let firstSelectable = screenPopup.menu?.items.first { $0.isEnabled && $0.representedObject != nil }
        if let item = firstSelectable { screenPopup.select(item) }
        startButton.isEnabled = firstSelectable != nil
        updateScreenThumbnail()
    }

    private func makeSectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        item.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        item.isEnabled = false
        return item
    }

    private func makePickerItem(title: String, symbol: String, target: CaptureTarget) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = target
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let sized = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                img.draw(in: rect); return true
            }
            item.image = sized
        }
        return item
    }

    private func updateScreenThumbnail() {
        guard let target = screenPopup.selectedItem?.representedObject as? CaptureTarget else { return }
        switch target {
        case .display(let id, _):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let img = CGDisplayCreateImage(id) else { return }
                DispatchQueue.main.async { self?.livePreview.showImage(img) }
            }
        case .window(let id, _, _, let scWindow):
            if #available(macOS 14.2, *), let scWindow = scWindow {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] img, _ in
                    guard let img else { return }
                    DispatchQueue.main.async { self?.livePreview.showImage(img) }
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let img = CGWindowListCreateImage(
                        .null, .optionIncludingWindow, id,
                        [.boundsIgnoreFraming, .bestResolution]
                    )
                    guard let img else { return }
                    DispatchQueue.main.async { self?.livePreview.showImage(img) }
                }
            }
        }
    }

    // MARK: – Actions

    @objc private func sourceChanged() {
        let newType: SourceType = sourceSegment.selectedSegment == 0 ? .camera : .screen
        guard newType != sourceType else { return }
        sourceType = newType

        if newType == .camera {
            cameraPopup.isHidden = false; screenPopup.isHidden = true
            pickerLabel.stringValue = "Camera"
            startButton.isEnabled   = !cameras.isEmpty
            startCameraPreview()
        } else {
            stopCameraPreview(); livePreview.clear()
            cameraPopup.isHidden = true; screenPopup.isHidden = false
            pickerLabel.stringValue = "Source"
            loadScreenContent()
        }
    }

    @objc private func cameraChanged()          { startCameraPreview() }
    @objc private func screenSelectionChanged() { updateScreenThumbnail() }
    @objc private func intervalChanged()        { intervalLabel.stringValue = "\(Int(intervalSlider.doubleValue))s" }
    @objc private func aiToggled()              { /* state read on start */ }

    // MARK: – Start

    @objc private func startTapped() {
        let iv      = intervalSlider.doubleValue
        let qmap:   [Double] = [0.75, 0.92, 1.0]
        let quality = qmap[qualityControl.selectedSegment]

        let aiEnabled = aiEnabledCheckbox.state == .on
        let aiConfig = AIConfig(
            enabled: aiEnabled,
            prompt:  promptTextView.string.isEmpty
                         ? "try to solve this question that you see on the screen."
                         : promptTextView.string,
            model:   modelField.stringValue.isEmpty ? "claude-sonnet-4-5" : modelField.stringValue
        )

        if aiEnabled && !EncryptedKeyStore.fileExists() {
            let alert = NSAlert()
            alert.messageText = "API Key Required"
            alert.informativeText = "AI processing is enabled but no API key is saved. Open the \"API Keys\" tab, enter your Anthropic API key, and click \"Save Key\" before starting capture."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if securityScopedOutputURL == nil && selectedOutputDir != Self.defaultOutputDirectory {
            promptForSaveFolder { [weak self] granted in
                guard granted else { return }
                self?.startTapped()
            }
            return
        }

        if selectedOutputDir == Self.defaultOutputDirectory {
            try? FileManager.default.createDirectory(at: selectedOutputDir, withIntermediateDirectories: true)
        }

        switch sourceType {
        case .camera:
            guard !cameras.isEmpty else { return }
            let device = cameras[max(0, cameraPopup.indexOfSelectedItem)]
            previewQueue.async { [weak self] in self?.previewSession?.stopRunning() }
            onStart?(.camera(device), iv, quality, selectedOutputDir, aiConfig)

        case .screen:
            guard let target = screenPopup.selectedItem?.representedObject as? CaptureTarget else { return }
            switch target {
            case .display(let id, let name):
                onStart?(.display(id: id, name: name), iv, quality, selectedOutputDir, aiConfig)
            case .window(let id, let appName, let title, _):
                onStart?(.window(id: id, name: "\(appName)  —  \(title)"), iv, quality, selectedOutputDir, aiConfig)
            }
        }
    }

    // MARK: – Layout helpers

    private func vstack(spacing: CGFloat) -> NSStackView {
        let s = NSStackView(); s.orientation = .vertical; s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false; return s
    }
    private func hstack(spacing: CGFloat) -> NSStackView {
        let s = NSStackView(); s.orientation = .horizontal; s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false; return s
    }
    private func plainLabel(_ t: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let f = NSTextField(labelWithString: t); f.font = .systemFont(ofSize: size, weight: weight); return f
    }
    private func sectionLabel(_ t: String) -> NSTextField {
        let f = plainLabel(t, size: 11, weight: .semibold); f.textColor = .secondaryLabelColor; return f
    }
    private func hFlex() -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); return v
    }
    private func pin(_ child: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo:  parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo:      parent.topAnchor),
            child.bottomAnchor.constraint(equalTo:   parent.bottomAnchor),
        ])
    }
}

// MARK: - DualPreviewView

private final class DualPreviewView: NSView {
    private var captureLayer: AVCaptureVideoPreviewLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius    = 10
        layer?.masksToBounds   = true
        layer?.borderWidth     = 0.5
        layer?.borderColor     = NSColor.white.withAlphaComponent(0.1).cgColor
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func showCamera(session: AVCaptureSession) {
        layer?.contents = nil
        captureLayer?.removeFromSuperlayer()
        let cl = AVCaptureVideoPreviewLayer(session: session)
        cl.videoGravity = .resizeAspect; cl.frame = bounds
        cl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(cl); captureLayer = cl
    }

    func showImage(_ image: CGImage) {
        captureLayer?.removeFromSuperlayer(); captureLayer = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contentsGravity = .resizeAspect; layer?.contents = image
        CATransaction.commit()
    }

    func clear() {
        captureLayer?.removeFromSuperlayer(); captureLayer = nil; layer?.contents = nil
    }

    override func layout() {
        super.layout()
        guard let cl = captureLayer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cl.frame = bounds; CATransaction.commit()
    }
}

import AppKit
import Darwin
import WebKit

// MARK: - CaptureWindowController

final class CaptureWindowController: NSWindowController {

    // MARK: – AI

    private var webView: WKWebView!
    private var aiPageReady = false
    private var pendingEntries: [(header: String, body: String, isError: Bool)] = []
    private weak var spinner:  NSProgressIndicator!
    private weak var aiStatus: NSTextField!
    private weak var countLabel: NSTextField!
    private var pendingCount = 0 { didSet { updateAIStatus() } }
    private var nextStreamingEntryId = 0
    private var entryIdByImageURL: [URL: Int] = [:]

    // MARK: – Toolbar

    private weak var pauseButton: NSButton!
    private weak var stopButton:  NSButton!
    private var aiPaused = false

    /// Called when AI is paused (`true`) or resumed (`false`).
    var onPauseAI: ((Bool) -> Void)?
    /// Called when the user clicks Stop — stops capture entirely.
    var onStop: (() -> Void)?

    // MARK: – Content tab (Visual / Transcript / Audio AI / Opencode / File Explore)

    private enum ContentTab: Int {
        case visual = 0
        case transcript = 1
        case audioAI = 2
        case opencode = 3
    }

    private weak var contentTabControl: NSSegmentedControl!
    private var activeContentTab = ContentTab.visual.rawValue
    private var fileExploreTabIndex: Int?

    // Visual-tab buttons
    private weak var zoomOutBtn:    NSButton!
    private weak var zoomInBtn:     NSButton!
    private weak var visualClearBtn: NSButton!

    // Transcript-tab buttons
    private weak var audioClearBtn: NSButton!

    // Audio AI-tab buttons
    private weak var audioAIAskBtn:    NSButton!
    private weak var audioAIClearBtn:  NSButton!
    private weak var audioAIZoomOutBtn: NSButton!
    private weak var audioAIZoomInBtn:  NSButton!

    // Opencode tab controls
    private weak var opencodeContainerView: NSView!
    private weak var opencodeSourceDirField: NSTextField!
    private weak var opencodeWorkingDirField: NSTextField!
    private var opencodeInitialPromptTextView: NSTextView!
    private weak var opencodeStatusLabel: NSTextField!
    private weak var opencodeStartButton: NSButton!
    private weak var opencodeSendField: NSTextField!
    private weak var opencodeSendButton: NSButton!
    private var opencodeChatTextView: NSTextView!
    private var opencodeActiveSessionID: String?
    private var opencodeActiveWorkingURL: URL?
    private var opencodeCommandToken: Int = 0
    private var opencodeIsBusy = false
    private let opencodeDefaultAttachURL = "http://127.0.0.1:4096"
    private var opencodeEventStreamClient: OpencodeEventStreamClient?
    private var opencodeStreamingAssistantMessageID: String?
    private var opencodeStreamingAssistantText: String = ""
    private var opencodeStreamingAssistantRange: NSRange?
    private var opencodeToolStatusByPartID: [String: String] = [:]
    private var opencodeSourceScopeURL: URL?
    private var opencodeWorkingScopeURL: URL?

    // File Explore tab controls
    private weak var fileExploreContainerView: NSView!
    private weak var fileExploreRootLabel: NSTextField!
    private weak var fileExploreOutlineView: NSOutlineView!
    private weak var fileExploreSidebarScrollView: NSScrollView!
    private var fileExplorePreviewWebView: WKWebView!
    private weak var fileExploreZoomOutButton: NSButton!
    private weak var fileExploreZoomInButton: NSButton!
    private var fileExplorePreviewReady = false
    private var fileExploreRootNode: FileExploreNode?
    private var fileExploreCurrentRootURL: URL?
    private var fileExplorePendingRender: (kind: String, content: String)?
    private var fileExploreRealtimeRefreshTimer: Timer?
    private var fileExploreTreeSnapshot: [String: FileExploreTreeSnapshotEntry] = [:]
    private var fileExploreSelectedFileURL: URL?
    private var fileExploreSelectedFingerprint: String?

    // Transcript feed
    private weak var audioScrollView: NSScrollView!
    private var audioTextView:        NSTextView!   // strong (inside scrollview)
    private var transcriptBuffer:     String = ""   // last N chars for Audio AI

    // Audio AI feed
    private var audioAIWebView:      WKWebView!     // strong
    private var audioAIPageReady     = false
    private var audioAINextEntryId   = 0
    private var audioAICurrentEntry: Int?           // nil = no active streaming entry
    private var audioAIStreamingText = ""

    // Audio AI callbacks / timer
    var onAudioAIRequest: ((String) -> Void)?
    var audioAITokenLimit: Int = 500          // ~4 chars per token
    private var audioAITimer: Timer?
    private let captureInterval: TimeInterval
    private var lastSentTranscript: String = ""

    // MARK: – Init

    init(name: String, interval: TimeInterval) {
        self.captureInterval = interval
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let w: CGFloat = 1280, h: CGFloat = 760
        let origin = NSPoint(x: screen.visibleFrame.midX - w / 2,
                             y: screen.visibleFrame.midY - h / 2)
        let win = NSWindow(
            contentRect: NSRect(x: origin.x, y: origin.y, width: w, height: h),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.sharingType = .none
        win.title           = "CameraShot  ·  \(name)"
        win.minSize         = NSSize(width: 700, height: 440)
        win.isMovableByWindowBackground = true
        super.init(window: win)
        buildUI(name: name, interval: interval)
    }

    deinit {
        audioAITimer?.invalidate()
        stopOpencodeEventStream()
        stopFileExploreRealtimeRefresh()
        opencodeSourceScopeURL?.stopAccessingSecurityScopedResource()
        opencodeWorkingScopeURL?.stopAccessingSecurityScopedResource()
    }

    /// Call this once voice input is confirmed enabled to start the auto-trigger timer.
    func startAudioAITimer() {
        audioAITimer?.invalidate()
        audioAITimer = Timer.scheduledTimer(withTimeInterval: captureInterval,
                                            repeats: true) { [weak self] _ in
            self?.triggerAudioAI()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: – Public

    func updateStatus(filename: String, count: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.countLabel.stringValue = "saved \(count)"
        }
    }

    // MARK: – Public — AI results

    func markProcessingStarted(imageURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingCount += 1
            let entryId = nextStreamingEntryId
            nextStreamingEntryId += 1
            entryIdByImageURL[imageURL] = entryId
            startStreamingEntry(imageURL: imageURL, entryId: entryId)
        }
    }

    func appendStreamingChunk(_ chunk: String, imageURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let entryId = entryIdByImageURL[imageURL],
                  let js = jsLiteral(chunk) else { return }
            webView.evaluateJavaScript("appendStreamingChunk(\(entryId), \(js))", completionHandler: nil)
        }
    }

    func endStreamingWithResult(fullMarkdown: String, imageURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingCount = max(0, pendingCount - 1)
            guard let entryId = entryIdByImageURL.removeValue(forKey: imageURL) else { return }
            guard let js = jsLiteral(fullMarkdown) else { return }
            webView.evaluateJavaScript("endStreamingEntry(\(entryId), \(js))", completionHandler: nil)
        }
    }

    func appendResult(response: String, imageURL: URL) {
        endStreamingWithResult(fullMarkdown: response, imageURL: imageURL)
    }

    func appendError(_ message: String, imageURL: URL? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingCount = max(0, pendingCount - 1)
            if let imageURL,
               let entryId = entryIdByImageURL.removeValue(forKey: imageURL),
               let js = jsLiteral(message) {
                webView.evaluateJavaScript("endStreamingEntryAsError(\(entryId), \(js))", completionHandler: nil)
                return
            }
            let header = "[\(Self.timeString())]  Error"
            appendEntry(header: header, body: message, isError: true)
        }
    }

    // MARK: – Public — Transcript feed

    /// Appends each server message permanently (no partial vs final distinction).
    func appendTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let ts = audioTextView.textStorage else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
            ts.append(NSAttributedString(string: text + "\n", attributes: attrs))
            transcriptBuffer += text + "\n"
            let cap = audioAITokenLimit * 4
            if transcriptBuffer.count > cap * 2 {
                transcriptBuffer = String(transcriptBuffer.suffix(cap))
            }
            scrollAudioToBottom()
        }
    }

    // MARK: – Public — Audio AI feed

    /// Streams a chunk of Claude's response into the Audio AI WebView.
    func appendAudioAIChunk(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, audioAIPageReady else { return }
            // Start a new streaming entry on the first chunk
            if audioAICurrentEntry == nil {
                let entryId = audioAINextEntryId
                audioAINextEntryId += 1
                audioAICurrentEntry = entryId
                audioAIStreamingText = ""
                let preview = String(transcriptBuffer.suffix(100))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let header = "[\(Self.timeString())]\n…\(preview)"
                if let hJS = jsLiteral(header) {
                    audioAIWebView.evaluateJavaScript(
                        "startStreamingEntry(\(hJS), null, \(entryId))",
                        completionHandler: nil)
                }
            }
            guard let entryId = audioAICurrentEntry, let tJS = jsLiteral(text) else { return }
            audioAIStreamingText += text
            audioAIWebView.evaluateJavaScript(
                "appendStreamingChunk(\(entryId), \(tJS))",
                completionHandler: nil)
        }
    }

    /// Finalizes the current Audio AI streaming entry, rendering full markdown.
    func finalizeAudioAI() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let entryId = audioAICurrentEntry,
                  let mdJS = jsLiteral(audioAIStreamingText) else { return }
            audioAIWebView.evaluateJavaScript(
                "endStreamingEntry(\(entryId), \(mdJS))",
                completionHandler: nil)
            audioAICurrentEntry = nil
            audioAIStreamingText = ""
        }
    }

    /// Appends an error entry to the Audio AI tab.
    func appendAudioAIError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, audioAIPageReady else { return }
            // Close any open entry first
            if let entryId = audioAICurrentEntry, let mdJS = jsLiteral(audioAIStreamingText) {
                audioAIWebView.evaluateJavaScript(
                    "endStreamingEntry(\(entryId), \(mdJS))", completionHandler: nil)
                audioAICurrentEntry = nil; audioAIStreamingText = ""
            }
            let entryId = audioAINextEntryId; audioAINextEntryId += 1
            let header = "[\(Self.timeString())]"
            if let hJS = jsLiteral(header) {
                audioAIWebView.evaluateJavaScript(
                    "startStreamingEntry(\(hJS), null, \(entryId))", completionHandler: nil)
            }
            if let errJS = jsLiteral("⚠ \(message)") {
                audioAIWebView.evaluateJavaScript(
                    "endStreamingEntry(\(entryId), \(errJS))", completionHandler: nil)
            }
        }
    }

    @objc private func audioAIZoomIn()  { audioAIWebView.evaluateJavaScript("adjustZoom(1)",  completionHandler: nil) }
    @objc private func audioAIZoomOut() { audioAIWebView.evaluateJavaScript("adjustZoom(-1)", completionHandler: nil) }

    @objc private func askAITapped() { triggerAudioAI() }

    private func triggerAudioAI() {
        let full    = transcriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return }
        // Trim to the configured token limit before sending
        let current = String(full.suffix(audioAITokenLimit * 4))

        // Skip if fewer than 3% of characters are new since the last send
        let newChars = current.count - lastSentTranscript.count
        let base = max(lastSentTranscript.count, 1)
        guard lastSentTranscript.isEmpty || Double(newChars) / Double(base) >= 0.03 else { return }

        lastSentTranscript = current
        onAudioAIRequest?(current)
    }

    /// Appends a red error entry to the audio feed.
    func appendAudioError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let attrStr = NSAttributedString(
                string: "⚠ \(message)\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: NSColor.systemRed])
            audioTextView.textStorage?.append(attrStr)
            scrollAudioToBottom()
        }
    }

    private func scrollAudioToBottom() {
        guard let ts = audioTextView.textStorage else { return }
        audioTextView.scrollRangeToVisible(NSRange(location: ts.length, length: 0))
    }

    // MARK: – UI construction

    private func buildUI(name: String, interval: TimeInterval) {
        guard let root = window?.contentView else { return }

        let toolbar = makeToolbar(name: name, interval: interval)
        root.addSubview(toolbar)

        let aiPane = buildAIPane()
        root.addSubview(aiPane)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            aiPane.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            aiPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            aiPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            aiPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func makeToolbar(name: String, interval: TimeInterval) -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: name)
        title.font          = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor     = NSColor(white: 0.55, alpha: 1)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(title)

        let cl = NSTextField(labelWithString: "saved 0")
        cl.font      = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cl.textColor = NSColor(white: 0.45, alpha: 1)
        cl.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(cl)
        countLabel = cl

        let spin = NSProgressIndicator()
        spin.style = .spinning; spin.controlSize = .small
        spin.isDisplayedWhenStopped = false
        spin.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(spin); spinner = spin

        let sl = NSTextField(labelWithString: "")
        sl.font      = .systemFont(ofSize: 11)
        sl.textColor = NSColor(white: 0.55, alpha: 1)
        sl.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(sl); aiStatus = sl

        let pauseBtn = NSButton(title: "⏸  Pause AI", target: self, action: #selector(pauseAITapped))
        pauseBtn.bezelStyle = .rounded
        pauseBtn.controlSize = .small
        pauseBtn.contentTintColor = .systemYellow
        pauseBtn.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(pauseBtn)
        pauseButton = pauseBtn

        let stopBtn = NSButton(title: "■  Stop", target: self, action: #selector(stopTapped))
        stopBtn.bezelStyle = .rounded
        stopBtn.controlSize = .small
        stopBtn.contentTintColor = .systemRed
        stopBtn.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stopBtn)
        stopButton = stopBtn

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            cl.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 12),
            cl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            stopBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            stopBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            pauseBtn.trailingAnchor.constraint(equalTo: stopBtn.leadingAnchor, constant: -8),
            pauseBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            spin.trailingAnchor.constraint(equalTo: sl.leadingAnchor, constant: -5),
            spin.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            sl.trailingAnchor.constraint(equalTo: pauseBtn.leadingAnchor, constant: -12),
            sl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    @objc private func pauseAITapped() {
        aiPaused = !aiPaused
        if aiPaused {
            pauseButton.title = "▶  Resume AI"
            pauseButton.contentTintColor = .systemGreen
        } else {
            pauseButton.title = "⏸  Pause AI"
            pauseButton.contentTintColor = .systemYellow
        }
        onPauseAI?(aiPaused)
    }

    @objc private func stopTapped() {
        stopButton.isEnabled  = false
        pauseButton.isEnabled = false
        onStop?()
    }

    private func buildAIPane() -> NSView {
        // ── WebView (Visual tab) ─────────────────────────────────
        let config = WKWebViewConfiguration()
        let handler = CopyCodeHandler(pageReady: { [weak self] in
            DispatchQueue.main.async {
                self?.aiPageReady = true
                self?.flushPendingEntries()
            }
        })
        config.userContentController.add(handler, name: "copyCode")
        config.userContentController.add(handler, name: "pageReady")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.wantsLayer = true
        wv.layer?.backgroundColor = NSColor.clear.cgColor
        wv.navigationDelegate = self
        webView = wv

        // ── Transcript feed ────────────────────────────────────────
        let tv = NSTextView()
        tv.isEditable         = false
        tv.isSelectable       = true
        tv.drawsBackground    = false
        tv.textContainerInset = NSSize(width: 16, height: 16)
        tv.autoresizingMask   = [.width]
        tv.textContainer?.widthTracksTextView = true
        audioTextView = tv

        let sv = NSScrollView()
        sv.documentView          = tv
        sv.hasVerticalScroller   = true
        sv.autohidesScrollers    = true
        sv.hasHorizontalScroller = false
        sv.drawsBackground       = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.isHidden = true   // hidden until Transcript tab is selected
        audioScrollView = sv

        // ── Audio AI feed (WKWebView — same renderer as Visual) ──────
        let aiCfg = WKWebViewConfiguration()
        let aiHandler = CopyCodeHandler(pageReady: { [weak self] in
            DispatchQueue.main.async {
                self?.audioAIPageReady = true
            }
        })
        aiCfg.userContentController.add(aiHandler, name: "copyCode")
        aiCfg.userContentController.add(aiHandler, name: "pageReady")

        let aiWV = WKWebView(frame: .zero, configuration: aiCfg)
        aiWV.translatesAutoresizingMaskIntoConstraints = false
        aiWV.wantsLayer = true
        aiWV.layer?.backgroundColor = NSColor.clear.cgColor
        aiWV.isHidden = true
        audioAIWebView = aiWV

        // ── Opencode tab content ───────────────────────────────────
        let opencodeView = NSView()
        opencodeView.translatesAutoresizingMaskIntoConstraints = false
        opencodeView.isHidden = true
        opencodeContainerView = opencodeView

        let sourceLabel = NSTextField(labelWithString: "source dir:")
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false

        let sourceField = NSTextField(string: "~/Documents/toptal-interview")
        sourceField.placeholderString = "to be entered"
        sourceField.font = .systemFont(ofSize: 13)
        sourceField.translatesAutoresizingMaskIntoConstraints = false
        opencodeSourceDirField = sourceField

        let workingLabel = NSTextField(labelWithString: "working dir:")
        workingLabel.font = .systemFont(ofSize: 12, weight: .medium)
        workingLabel.translatesAutoresizingMaskIntoConstraints = false

        let workingField = NSTextField(string: "~/Documents/stuff/interview-coding")
        workingField.placeholderString = "to be entered"
        workingField.font = .systemFont(ofSize: 13)
        workingField.translatesAutoresizingMaskIntoConstraints = false
        opencodeWorkingDirField = workingField

        let initialPromptLabel = NSTextField(labelWithString: "initial prompt:")
        initialPromptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        initialPromptLabel.translatesAutoresizingMaskIntoConstraints = false

        let initialPromptTextView = NSTextView()
        initialPromptTextView.isEditable = true
        initialPromptTextView.isSelectable = true
        initialPromptTextView.drawsBackground = true
        initialPromptTextView.backgroundColor = .textBackgroundColor
        initialPromptTextView.font = .systemFont(ofSize: 13)
        initialPromptTextView.textContainerInset = NSSize(width: 6, height: 6)
        initialPromptTextView.string = ""
        opencodeInitialPromptTextView = initialPromptTextView

        let initialPromptScroll = NSScrollView()
        initialPromptScroll.documentView = initialPromptTextView
        initialPromptScroll.hasVerticalScroller = true
        initialPromptScroll.autohidesScrollers = true
        initialPromptScroll.hasHorizontalScroller = false
        initialPromptScroll.borderType = .bezelBorder
        initialPromptScroll.translatesAutoresizingMaskIntoConstraints = false

        let startBtn = NSButton(title: "Start", target: self, action: #selector(startOpencodeTapped))
        startBtn.bezelStyle = .rounded
        startBtn.translatesAutoresizingMaskIntoConstraints = false
        opencodeStartButton = startBtn

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true
        opencodeStatusLabel = statusLabel

        let chatTextView = NSTextView()
        chatTextView.isEditable = false
        chatTextView.isSelectable = true
        chatTextView.drawsBackground = false
        chatTextView.font = .systemFont(ofSize: 12)
        chatTextView.textContainerInset = NSSize(width: 14, height: 14)
        chatTextView.textContainer?.widthTracksTextView = true
        opencodeChatTextView = chatTextView

        let chatScroll = NSScrollView()
        chatScroll.documentView = chatTextView
        chatScroll.hasVerticalScroller = true
        chatScroll.autohidesScrollers = true
        chatScroll.hasHorizontalScroller = false
        chatScroll.drawsBackground = false
        chatScroll.translatesAutoresizingMaskIntoConstraints = false

        let sendField = NSTextField(string: "")
        sendField.placeholderString = "Send follow-up message"
        sendField.font = .systemFont(ofSize: 13)
        sendField.translatesAutoresizingMaskIntoConstraints = false
        sendField.target = self
        sendField.action = #selector(opencodeSendTapped)
        opencodeSendField = sendField

        let sendBtn = NSButton(title: "Send", target: self, action: #selector(opencodeSendTapped))
        sendBtn.bezelStyle = .rounded
        sendBtn.translatesAutoresizingMaskIntoConstraints = false
        opencodeSendButton = sendBtn

        [sourceLabel, sourceField, workingLabel, workingField, initialPromptLabel, initialPromptScroll, startBtn, statusLabel,
         chatScroll, sendField, sendBtn]
            .forEach { opencodeView.addSubview($0) }

        // ── File Explore tab content ───────────────────────────────
        let fileExploreView = NSView()
        fileExploreView.translatesAutoresizingMaskIntoConstraints = false
        fileExploreView.isHidden = true
        fileExploreContainerView = fileExploreView

        let fileExploreRoot = NSTextField(labelWithString: "working dir: —")
        fileExploreRoot.font = .systemFont(ofSize: 12, weight: .medium)
        fileExploreRoot.textColor = .secondaryLabelColor
        fileExploreRoot.lineBreakMode = .byTruncatingMiddle
        fileExploreRoot.translatesAutoresizingMaskIntoConstraints = false
        fileExploreRootLabel = fileExploreRoot

        let fileExploreZoomOut = NSButton(title: "−", target: self, action: #selector(fileExploreZoomOut))
        fileExploreZoomOut.bezelStyle = .rounded
        fileExploreZoomOut.translatesAutoresizingMaskIntoConstraints = false
        fileExploreZoomOutButton = fileExploreZoomOut

        let fileExploreZoomIn = NSButton(title: "+", target: self, action: #selector(fileExploreZoomIn))
        fileExploreZoomIn.bezelStyle = .rounded
        fileExploreZoomIn.translatesAutoresizingMaskIntoConstraints = false
        fileExploreZoomInButton = fileExploreZoomIn

        let fileExploreSplitView = NSSplitView()
        fileExploreSplitView.isVertical = true
        fileExploreSplitView.dividerStyle = .thin
        fileExploreSplitView.translatesAutoresizingMaskIntoConstraints = false
        fileExploreSplitView.autosaveName = "CameraShot.FileExploreSplitView"

        let sidebarScroll = NSScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.hasHorizontalScroller = false
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.borderType = .bezelBorder
        fileExploreSidebarScrollView = sidebarScroll

        let outlineView = NSOutlineView()
        let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileExploreNameColumn"))
        outlineColumn.title = "Files"
        outlineView.addTableColumn(outlineColumn)
        outlineView.outlineTableColumn = outlineColumn
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.focusRingType = .none
        outlineView.delegate = self
        outlineView.dataSource = self
        sidebarScroll.documentView = outlineView
        fileExploreOutlineView = outlineView

        let previewCfg = WKWebViewConfiguration()
        let previewHandler = CopyCodeHandler(pageReady: { [weak self] in
            DispatchQueue.main.async {
                self?.fileExplorePreviewReady = true
                self?.flushFileExplorePendingRender()
            }
        })
        previewCfg.userContentController.add(previewHandler, name: "copyCode")
        previewCfg.userContentController.add(previewHandler, name: "pageReady")

        let filePreviewWebView = WKWebView(frame: .zero, configuration: previewCfg)
        filePreviewWebView.translatesAutoresizingMaskIntoConstraints = false
        filePreviewWebView.wantsLayer = true
        filePreviewWebView.layer?.backgroundColor = NSColor.clear.cgColor
        fileExplorePreviewWebView = filePreviewWebView

        fileExploreSplitView.addArrangedSubview(sidebarScroll)
        fileExploreSplitView.addArrangedSubview(filePreviewWebView)
        sidebarScroll.widthAnchor.constraint(equalToConstant: 280).isActive = true
        sidebarScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        fileExploreView.addSubview(fileExploreRoot)
        fileExploreView.addSubview(fileExploreZoomOut)
        fileExploreView.addSubview(fileExploreZoomIn)
        fileExploreView.addSubview(fileExploreSplitView)

        // ── Container ─────────────────────────────────────────────
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // ── Inner bar ─────────────────────────────────────────────
        let innerBar = NSView()
        innerBar.wantsLayer = true
        innerBar.layer?.backgroundColor = NSColor(named: "controlBackground")?.cgColor
        innerBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(innerBar)

        func barBtn(_ label: String, action: Selector) -> NSButton {
            let b = NSButton(title: label, target: self, action: action)
            b.bezelStyle = .inline
            b.font = .systemFont(ofSize: 13, weight: .medium)
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }

        // Content tab selector (left side of inner bar)
        let contentTabs = NSSegmentedControl(
            labels: ["Visual", "Transcript", "Audio AI", "Opencode"],
            trackingMode: .selectOne, target: self,
            action: #selector(contentTabChanged))
        contentTabs.selectedSegment = 0
        contentTabs.segmentStyle    = .automatic
        contentTabs.controlSize     = .small
        contentTabs.translatesAutoresizingMaskIntoConstraints = false
        innerBar.addSubview(contentTabs)
        contentTabControl = contentTabs

        // Visual-tab buttons (right side)
        let zo = barBtn("−", action: #selector(zoomOut)); zoomOutBtn    = zo
        let zi = barBtn("+", action: #selector(zoomIn));  zoomInBtn     = zi
        let vc = barBtn("Clear", action: #selector(clearAI))
        vc.font = .systemFont(ofSize: 11);                visualClearBtn = vc

        // Transcript-tab buttons (hidden initially)
        let ac = barBtn("Clear", action: #selector(clearAudioFeed))
        ac.font = .systemFont(ofSize: 11)
        ac.isHidden = true;                               audioClearBtn = ac

        // Audio AI-tab buttons (hidden initially)
        let azo = barBtn("−", action: #selector(audioAIZoomOut)); azo.isHidden = true; audioAIZoomOutBtn = azo
        let azi = barBtn("+", action: #selector(audioAIZoomIn));  azi.isHidden = true; audioAIZoomInBtn  = azi
        let aac = barBtn("Clear", action: #selector(clearAudioAI))
        aac.font = .systemFont(ofSize: 11); aac.isHidden = true; audioAIClearBtn = aac
        let askBtn = barBtn("Ask AI", action: #selector(askAITapped))
        askBtn.font = .systemFont(ofSize: 11); askBtn.isHidden = true; audioAIAskBtn = askBtn

        [zo, zi, vc, ac, azo, azi, aac, askBtn].forEach { innerBar.addSubview($0) }

        let divider = NSBox(); divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        container.addSubview(wv)
        container.addSubview(sv)
        container.addSubview(aiWV)
        container.addSubview(opencodeView)
        container.addSubview(fileExploreView)

        NSLayoutConstraint.activate([
            // Inner bar
            innerBar.topAnchor.constraint(equalTo: container.topAnchor),
            innerBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            innerBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            innerBar.heightAnchor.constraint(equalToConstant: 36),

            // Content tab selector (left)
            contentTabs.leadingAnchor.constraint(equalTo: innerBar.leadingAnchor, constant: 10),
            contentTabs.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),

            // Visual buttons (right)
            zo.trailingAnchor.constraint(equalTo: zi.leadingAnchor, constant: -2),
            zo.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),
            zi.trailingAnchor.constraint(equalTo: vc.leadingAnchor, constant: -10),
            zi.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),
            vc.trailingAnchor.constraint(equalTo: innerBar.trailingAnchor, constant: -14),
            vc.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),

            // Transcript buttons (same position – shown/hidden on tab switch)
            ac.trailingAnchor.constraint(equalTo: innerBar.trailingAnchor, constant: -14),
            ac.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),

            // Audio AI buttons (shown/hidden on tab switch)
            azo.trailingAnchor.constraint(equalTo: azi.leadingAnchor, constant: -2),
            azo.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),
            azi.trailingAnchor.constraint(equalTo: aac.leadingAnchor, constant: -10),
            azi.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),
            aac.trailingAnchor.constraint(equalTo: innerBar.trailingAnchor, constant: -14),
            aac.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),
            askBtn.trailingAnchor.constraint(equalTo: azo.leadingAnchor, constant: -12),
            askBtn.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),

            // Divider
            divider.topAnchor.constraint(equalTo: innerBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // Content views — all tabs share the same frame
            wv.topAnchor.constraint(equalTo: divider.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            sv.topAnchor.constraint(equalTo: divider.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            aiWV.topAnchor.constraint(equalTo: divider.bottomAnchor),
            aiWV.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            aiWV.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            aiWV.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            opencodeView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            opencodeView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            opencodeView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            opencodeView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            fileExploreView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            fileExploreView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fileExploreView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fileExploreView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            sourceLabel.topAnchor.constraint(equalTo: opencodeView.topAnchor, constant: 16),
            sourceLabel.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),

            sourceField.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 6),
            sourceField.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),
            sourceField.trailingAnchor.constraint(equalTo: opencodeView.trailingAnchor, constant: -16),

            workingLabel.topAnchor.constraint(equalTo: sourceField.bottomAnchor, constant: 12),
            workingLabel.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),

            workingField.topAnchor.constraint(equalTo: workingLabel.bottomAnchor, constant: 6),
            workingField.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),
            workingField.trailingAnchor.constraint(equalTo: opencodeView.trailingAnchor, constant: -16),

            initialPromptLabel.topAnchor.constraint(equalTo: workingField.bottomAnchor, constant: 12),
            initialPromptLabel.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),

            initialPromptScroll.topAnchor.constraint(equalTo: initialPromptLabel.bottomAnchor, constant: 6),
            initialPromptScroll.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),
            initialPromptScroll.trailingAnchor.constraint(equalTo: opencodeView.trailingAnchor, constant: -16),
            initialPromptScroll.heightAnchor.constraint(equalToConstant: 92),

            startBtn.topAnchor.constraint(equalTo: initialPromptScroll.bottomAnchor, constant: 14),
            startBtn.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),

            statusLabel.topAnchor.constraint(equalTo: startBtn.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: opencodeView.trailingAnchor, constant: -16),

            chatScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            chatScroll.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),
            chatScroll.trailingAnchor.constraint(equalTo: opencodeView.trailingAnchor, constant: -16),
            chatScroll.bottomAnchor.constraint(equalTo: sendField.topAnchor, constant: -10),
            chatScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

            sendField.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),
            sendField.bottomAnchor.constraint(equalTo: opencodeView.bottomAnchor, constant: -16),
            sendField.heightAnchor.constraint(equalToConstant: 28),

            sendBtn.leadingAnchor.constraint(equalTo: sendField.trailingAnchor, constant: 8),
            sendBtn.trailingAnchor.constraint(equalTo: opencodeView.trailingAnchor, constant: -16),
            sendBtn.centerYAnchor.constraint(equalTo: sendField.centerYAnchor),
            sendBtn.widthAnchor.constraint(equalToConstant: 74),

            fileExploreRoot.topAnchor.constraint(equalTo: fileExploreView.topAnchor, constant: 12),
            fileExploreRoot.leadingAnchor.constraint(equalTo: fileExploreView.leadingAnchor, constant: 16),
            fileExploreRoot.trailingAnchor.constraint(lessThanOrEqualTo: fileExploreZoomOut.leadingAnchor, constant: -12),

            fileExploreZoomIn.trailingAnchor.constraint(equalTo: fileExploreView.trailingAnchor, constant: -16),
            fileExploreZoomIn.centerYAnchor.constraint(equalTo: fileExploreRoot.centerYAnchor),
            fileExploreZoomIn.widthAnchor.constraint(equalToConstant: 28),

            fileExploreZoomOut.trailingAnchor.constraint(equalTo: fileExploreZoomIn.leadingAnchor, constant: -6),
            fileExploreZoomOut.centerYAnchor.constraint(equalTo: fileExploreRoot.centerYAnchor),
            fileExploreZoomOut.widthAnchor.constraint(equalToConstant: 28),

            fileExploreSplitView.topAnchor.constraint(equalTo: fileExploreRoot.bottomAnchor, constant: 8),
            fileExploreSplitView.leadingAnchor.constraint(equalTo: fileExploreView.leadingAnchor, constant: 12),
            fileExploreSplitView.trailingAnchor.constraint(equalTo: fileExploreView.trailingAnchor, constant: -12),
            fileExploreSplitView.bottomAnchor.constraint(equalTo: fileExploreView.bottomAnchor, constant: -12),
        ])

        setOpencodeStatus("Session not started.", isError: false)
        updateOpencodeControls()

        let baseURL: URL? = Self.resourcesBaseURL()
        wv.loadHTMLString(Self.htmlTemplate, baseURL: baseURL)
        aiWV.loadHTMLString(Self.htmlTemplate, baseURL: baseURL)
        fileExplorePreviewWebView.loadHTMLString(Self.fileExploreHTMLTemplate, baseURL: baseURL)
        renderFileExploreDocument(kind: "text", content: "Start Opencode to open File Explore.")
        return container
    }

    @objc private func contentTabChanged() {
        activeContentTab = contentTabControl.selectedSegment
        let isVisual = activeContentTab == ContentTab.visual.rawValue
        let isTranscript = activeContentTab == ContentTab.transcript.rawValue
        let isAudioAI = activeContentTab == ContentTab.audioAI.rawValue
        let isOpencode = activeContentTab == ContentTab.opencode.rawValue
        let isFileExplore = fileExploreTabIndex == activeContentTab

        webView.isHidden         = !isVisual
        audioScrollView.isHidden = !isTranscript
        audioAIWebView.isHidden  = !isAudioAI
        opencodeContainerView.isHidden = !isOpencode
        fileExploreContainerView?.isHidden = !isFileExplore

        zoomOutBtn.isHidden       = !isVisual
        zoomInBtn.isHidden        = !isVisual
        visualClearBtn.isHidden   = !isVisual
        audioClearBtn.isHidden    = !isTranscript
        audioAIZoomOutBtn.isHidden = !isAudioAI
        audioAIZoomInBtn.isHidden  = !isAudioAI
        audioAIClearBtn.isHidden   = !isAudioAI
        audioAIAskBtn.isHidden     = !isAudioAI

        if isFileExplore, let rootURL = fileExploreCurrentRootURL {
            rebuildFileExploreRoot(at: rootURL, preserveState: true)
        }
        updateFileExploreRealtimeRefreshState()
    }

    private func ensureFileExploreTabVisible() -> Int {
        if let existing = fileExploreTabIndex {
            return existing
        }
        let newIndex = contentTabControl.segmentCount
        contentTabControl.segmentCount = newIndex + 1
        contentTabControl.setLabel("file explore", forSegment: newIndex)
        fileExploreTabIndex = newIndex
        return newIndex
    }

    private func activateFileExploreTab(with workingURL: URL) {
        let rootURL = workingURL.standardizedFileURL
        fileExploreCurrentRootURL = rootURL
        fileExploreRootLabel?.stringValue = "working dir: \(rootURL.path)"
        rebuildFileExploreRoot(at: rootURL, preserveState: false)
        fileExploreTreeSnapshot = captureFileExploreTreeSnapshot(at: rootURL)
        stopFileExploreRealtimeRefresh()
        let segment = ensureFileExploreTabVisible()
        contentTabControl.selectedSegment = segment
        contentTabChanged()
    }

    private func rebuildFileExploreRoot(at rootURL: URL, preserveState: Bool) {
        fileExploreCurrentRootURL = rootURL.standardizedFileURL
        let expandedURLs = preserveState ? expandedFileExploreDirectoryURLs() : []
        let previouslySelected = preserveState ? fileExploreSelectedFileURL : nil

        let root = FileExploreNode(url: rootURL, isDirectory: true)
        fileExploreRootNode = root
        loadFileExploreChildrenIfNeeded(for: root)
        fileExploreOutlineView?.reloadData()

        if preserveState {
            restoreExpandedFileExploreDirectoryURLs(expandedURLs)
            if let selectedURL = previouslySelected,
               restoreFileExploreSelection(for: selectedURL) {
                previewFileExploreFile(at: selectedURL)
                return
            }
        }

        fileExploreSelectedFileURL = nil
        fileExploreSelectedFingerprint = nil
        renderFileExploreDocument(kind: "text", content: "Select a file from the sidebar.")
    }

    private func loadFileExploreChildrenIfNeeded(for node: FileExploreNode) {
        guard node.isDirectory, !node.isLoaded else { return }
        node.isLoaded = true

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .localizedNameKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: node.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            )
            let children = urls.compactMap { childURL -> FileExploreNode? in
                let values = try? childURL.resourceValues(forKeys: keys)
                let isDir = values?.isDirectory ?? false
                let child = FileExploreNode(url: childURL.standardizedFileURL, isDirectory: isDir)
                child.parent = node
                return child
            }
            node.children = children.sorted {
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory && !$1.isDirectory
                }
                return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
        } catch {
            node.children = []
        }
    }

    private func previewFileExploreFile(at fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL
        fileExploreSelectedFileURL = standardizedURL
        do {
            let data = try Data(contentsOf: standardizedURL)
            if isLikelyBinaryFileData(data) {
                fileExploreSelectedFingerprint = nil
                renderFileExploreDocument(kind: "text", content: "Cannot preview binary file: \(standardizedURL.lastPathComponent)")
                updateFileExploreRealtimeRefreshState()
                return
            }
            guard let text = parseFileExploreText(from: data) else {
                fileExploreSelectedFingerprint = nil
                renderFileExploreDocument(kind: "text", content: "Unable to decode file as UTF-8 text: \(standardizedURL.lastPathComponent)")
                updateFileExploreRealtimeRefreshState()
                return
            }
            let kind = fileExploreContentKind(for: standardizedURL)
            fileExploreSelectedFingerprint = fileExploreFingerprint(for: standardizedURL)
            renderFileExploreDocument(kind: kind, content: text)
            updateFileExploreRealtimeRefreshState()
        } catch {
            fileExploreSelectedFingerprint = nil
            renderFileExploreDocument(kind: "text", content: "Failed to read file: \(error.localizedDescription)")
            updateFileExploreRealtimeRefreshState()
        }
    }

    private func fileExploreContentKind(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" || ext == "mdown" {
            return "markdown"
        }
        if ext == "py" {
            return "python"
        }
        return "text"
    }

    private func parseFileExploreText(from data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let lossy = String(decoding: data, as: UTF8.self)
        return lossy.isEmpty ? nil : lossy
    }

    private func isLikelyBinaryFileData(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        let sample = data.prefix(4096)
        return sample.contains(0)
    }

    private func renderFileExploreDocument(kind: String, content: String) {
        guard fileExplorePreviewReady else {
            fileExplorePendingRender = (kind, content)
            return
        }
        guard let kindJS = jsLiteral(kind), let contentJS = jsLiteral(content) else { return }
        fileExplorePreviewWebView.evaluateJavaScript("renderDocument(\(kindJS), \(contentJS));", completionHandler: nil)
    }

    private func flushFileExplorePendingRender() {
        guard fileExplorePreviewReady, let pending = fileExplorePendingRender else { return }
        fileExplorePendingRender = nil
        guard let kindJS = jsLiteral(pending.kind), let contentJS = jsLiteral(pending.content) else { return }
        fileExplorePreviewWebView.evaluateJavaScript("renderDocument(\(kindJS), \(contentJS));", completionHandler: nil)
    }

    @objc private func fileExploreZoomIn() {
        fileExplorePreviewWebView?.evaluateJavaScript("adjustZoom(1);", completionHandler: nil)
    }

    @objc private func fileExploreZoomOut() {
        fileExplorePreviewWebView?.evaluateJavaScript("adjustZoom(-1);", completionHandler: nil)
    }

    private func startFileExploreRealtimeRefresh() {
        stopFileExploreRealtimeRefresh()
        fileExploreRealtimeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshFileExploreIfNeeded()
        }
        if let timer = fileExploreRealtimeRefreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopFileExploreRealtimeRefresh() {
        fileExploreRealtimeRefreshTimer?.invalidate()
        fileExploreRealtimeRefreshTimer = nil
    }

    private func updateFileExploreRealtimeRefreshState() {
        let isFileExploreActive = fileExploreTabIndex == activeContentTab
        let hasRoot = fileExploreCurrentRootURL != nil
        if isFileExploreActive && hasRoot {
            if fileExploreRealtimeRefreshTimer == nil {
                startFileExploreRealtimeRefresh()
            }
        } else {
            stopFileExploreRealtimeRefresh()
        }
    }

    private func refreshFileExploreIfNeeded() {
        guard let rootURL = fileExploreCurrentRootURL else {
            stopFileExploreRealtimeRefresh()
            return
        }

        let newSnapshot = captureFileExploreTreeSnapshot(at: rootURL)
        if newSnapshot != fileExploreTreeSnapshot {
            fileExploreTreeSnapshot = newSnapshot
            rebuildFileExploreRoot(at: rootURL, preserveState: true)
        }

        guard let selectedURL = fileExploreSelectedFileURL else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: selectedURL.path) else {
            fileExploreSelectedFileURL = nil
            fileExploreSelectedFingerprint = nil
            renderFileExploreDocument(kind: "text", content: "Selected file was removed.")
            return
        }

        let newFingerprint = fileExploreFingerprint(for: selectedURL)
        guard newFingerprint != fileExploreSelectedFingerprint else { return }
        previewFileExploreFile(at: selectedURL)
    }

    private func captureFileExploreTreeSnapshot(at rootURL: URL) -> [String: FileExploreTreeSnapshotEntry] {
        var snapshot: [String: FileExploreTreeSnapshotEntry] = [:]
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]

        let rootValues = try? rootURL.resourceValues(forKeys: keys)
        let rootEntry = FileExploreTreeSnapshotEntry(
            isDirectory: rootValues?.isDirectory ?? true,
            modifiedAt: rootValues?.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: Int64(rootValues?.fileSize ?? 0)
        )
        snapshot[rootURL.path] = rootEntry

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else {
            return snapshot
        }

        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: keys)
            let entry = FileExploreTreeSnapshotEntry(
                isDirectory: values?.isDirectory ?? false,
                modifiedAt: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                size: Int64(values?.fileSize ?? 0)
            )
            snapshot[url.path] = entry
        }
        return snapshot
    }

    private func fileExploreFingerprint(for fileURL: URL) -> String? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let values = try? fileURL.resourceValues(forKeys: keys) else { return nil }
        let modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        return "\(modifiedAt)-\(size)"
    }

    private func expandedFileExploreDirectoryURLs() -> Set<URL> {
        guard let outlineView = fileExploreOutlineView else { return [] }
        var urls = Set<URL>()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileExploreNode else { continue }
            if node.isDirectory, outlineView.isItemExpanded(node) {
                urls.insert(node.url.standardizedFileURL)
            }
        }
        return urls
    }

    private func restoreExpandedFileExploreDirectoryURLs(_ urls: Set<URL>) {
        guard let outlineView = fileExploreOutlineView else { return }
        let sorted = urls.sorted { $0.pathComponents.count < $1.pathComponents.count }
        for url in sorted {
            if let node = fileExploreNode(for: url) {
                expandFileExploreAncestors(of: node, in: outlineView)
                if node.isDirectory {
                    outlineView.expandItem(node)
                }
            }
        }
    }

    private func restoreFileExploreSelection(for fileURL: URL) -> Bool {
        guard let outlineView = fileExploreOutlineView,
              let node = fileExploreNode(for: fileURL),
              !node.isDirectory else { return false }

        expandFileExploreAncestors(of: node, in: outlineView)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fileExploreSelectedFileURL = node.url.standardizedFileURL
        return true
    }

    private func fileExploreNode(for url: URL) -> FileExploreNode? {
        guard let root = fileExploreRootNode else { return nil }
        let standardized = url.standardizedFileURL
        if root.url == standardized { return root }

        let rootPath = root.url.path
        let targetPath = standardized.path
        guard targetPath.hasPrefix(rootPath + "/") else { return nil }

        let relativePath = String(targetPath.dropFirst(rootPath.count + 1))
        if relativePath.isEmpty { return root }

        var current = root
        for component in relativePath.split(separator: "/") {
            loadFileExploreChildrenIfNeeded(for: current)
            guard let next = current.children.first(where: { $0.url.lastPathComponent == String(component) }) else {
                return nil
            }
            current = next
        }
        return current
    }

    private func expandFileExploreAncestors(of node: FileExploreNode, in outlineView: NSOutlineView) {
        var parents: [FileExploreNode] = []
        var current = node.parent
        while let dir = current {
            parents.append(dir)
            current = dir.parent
        }
        for parent in parents.reversed() {
            outlineView.expandItem(parent)
        }
    }

    @objc private func startOpencodeTapped() {
        let sourceDir = normalizedPathInput(opencodeSourceDirField.stringValue)
        let workingDir = normalizedPathInput(opencodeWorkingDirField.stringValue)
        let initialPrompt = opencodeInitialPromptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceDir.isEmpty, !workingDir.isEmpty else {
            setOpencodeStatus("Please enter both source dir and working dir.", isError: true)
            return
        }

        stopActiveOpencodeProcess(resetSession: true)
        setOpencodeStatus("Preparing input directory…", isError: false)

        runOpencodeStart(
            sourceDirInput: sourceDir,
            workingDirInput: workingDir,
            initialPrompt: initialPrompt,
            allowPermissionPrompt: true
        )
    }

    private func runOpencodeStart(
        sourceDirInput: String,
        workingDirInput: String,
        initialPrompt: String,
        allowPermissionPrompt: Bool
    ) {
        let sourceDir = sourceDirInput
        let workingDir = workingDirInput

        let fm = FileManager.default
        let workingURL = resolveUserPath(workingDir)
        let sourceURL = resolveUserPath(sourceDir, relativeTo: workingURL)
        let inputURL = workingURL.appendingPathComponent("input", isDirectory: true).standardizedFileURL

        do {
            var workingExistsIsDir: ObjCBool = false
            if fm.fileExists(atPath: workingURL.path, isDirectory: &workingExistsIsDir) {
                guard workingExistsIsDir.boolValue else {
                    setOpencodeStatus("Invalid working dir: path points to a file.", isError: true)
                    return
                }
            } else {
                try fm.createDirectory(at: workingURL, withIntermediateDirectories: true)
            }

            var sourceIsDir: ObjCBool = false
            guard fm.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDir) else {
                setOpencodeStatus("Source path does not exist: \(sourceURL.path)", isError: true)
                return
            }

            if sourceIsDir.boolValue && (sourceURL == inputURL || sourceURL.path.hasPrefix(inputURL.path + "/")) {
                setOpencodeStatus("Unsafe source dir: cannot be input/ itself or inside input/.", isError: true)
                return
            }

            let copiedCount = try prepareInputDirectory(from: sourceURL, isDirectory: sourceIsDir.boolValue, in: workingURL)
            NSLog("Opencode start complete. sourceDir=%@ workingDir=%@ initialPrompt=%@ inputDir=%@",
                  sourceDir, workingDir, initialPrompt, inputURL.path)
            setOpencodeStatus("Prepared \(inputURL.path) · Copied \(copiedCount) item(s). Starting session…", isError: false)
            activateFileExploreTab(with: workingURL)
            startNewOpencodeSession(workingURL: workingURL, initialPrompt: initialPrompt)
        } catch {
            if allowPermissionPrompt, isPermissionError(error),
               shouldPromptForExplicitFolderAccess(sourceURL: sourceURL, workingURL: workingURL) {
                let granted = requestOpencodeFolderAccess(sourceURL: sourceURL, workingURL: workingURL)
                if granted {
                    runOpencodeStart(
                        sourceDirInput: sourceDirInput,
                        workingDirInput: workingDirInput,
                        initialPrompt: initialPrompt,
                        allowPermissionPrompt: false
                    )
                    return
                }
                setOpencodeStatus("Folder permission was not granted.", isError: true)
                return
            }
            setOpencodeStatus("Start failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func prepareInputDirectory(from source: URL, isDirectory: Bool, in workingDir: URL) throws -> Int {
        let fm = FileManager.default
        let inputDir = workingDir.appendingPathComponent("input", isDirectory: true).standardizedFileURL

        if fm.fileExists(atPath: inputDir.path) {
            try fm.removeItem(at: inputDir)
        }
        try fm.createDirectory(at: inputDir, withIntermediateDirectories: true)

        var copiedCount = 0
        if isDirectory {
            let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for item in items {
                // Avoid recursively copying input/ into itself when source == workingDir.
                if item.standardizedFileURL == inputDir { continue }
                let destination = inputDir.appendingPathComponent(item.lastPathComponent, isDirectory: false)
                try fm.copyItem(at: item, to: destination)
                copiedCount += 1
            }
        } else {
            let destination = inputDir.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            try fm.copyItem(at: source, to: destination)
            copiedCount = 1
        }
        return copiedCount
    }

    private func resolveUserPath(_ rawPath: String, relativeTo baseDir: URL? = nil) -> URL {
        if rawPath.hasPrefix("file://"), let url = URL(string: rawPath), url.isFileURL {
            return url.standardizedFileURL
        }
        let expanded = expandTildeToRealHome(rawPath)
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        let base = baseDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return base.appendingPathComponent(expanded, isDirectory: false).standardizedFileURL
    }

    private func expandTildeToRealHome(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }

        let homePath: String
        if let pw = getpwuid(getuid()), let cHome = pw.pointee.pw_dir {
            homePath = String(cString: cHome)
        } else if let fallback = NSHomeDirectoryForUser(NSUserName()) {
            homePath = fallback
        } else {
            homePath = NSHomeDirectory()
        }

        if path == "~" { return homePath }
        if path.hasPrefix("~/") {
            return homePath + "/" + path.dropFirst(2)
        }
        return NSString(string: path).expandingTildeInPath
    }

    private func normalizedPathInput(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestOpencodeFolderAccess(sourceURL: URL, workingURL: URL) -> Bool {
        let sourceBase = sourceURL.hasDirectoryPath ? sourceURL : sourceURL.deletingLastPathComponent()
        let sourceGranted = requestSecurityScopedFolder(
            initialDirectory: sourceBase,
            prompt: "Grant Source Access",
            message: "CameraShot needs access to read the source path. Choose that folder (or a parent folder).",
            currentScope: &opencodeSourceScopeURL
        )
        guard sourceGranted else { return false }

        return requestSecurityScopedFolder(
            initialDirectory: workingURL,
            prompt: "Grant Working Access",
            message: "CameraShot needs access to create/remove input/ inside working dir. Choose that folder (or a parent folder).",
            currentScope: &opencodeWorkingScopeURL
        )
    }

    private func requestSecurityScopedFolder(
        initialDirectory: URL,
        prompt: String,
        message: String,
        currentScope: inout URL?
    ) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles       = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL         = initialDirectory
        panel.prompt               = prompt
        panel.message              = message

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard url.startAccessingSecurityScopedResource() else {
            setOpencodeStatus("Access denied for \(url.path)", isError: true)
            return false
        }
        currentScope?.stopAccessingSecurityScopedResource()
        currentScope = url
        return true
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError {
                return true
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            if ns.code == Int(EACCES) || ns.code == Int(EPERM) {
                return true
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    private func shouldPromptForExplicitFolderAccess(sourceURL: URL, workingURL: URL) -> Bool {
        let sourceBase = sourceURL.hasDirectoryPath ? sourceURL : sourceURL.deletingLastPathComponent()
        return !isUnderDocuments(sourceBase) || !isUnderDocuments(workingURL)
    }

    private func isUnderDocuments(_ url: URL) -> Bool {
        let docsURL = documentsRootURL()
        let path = url.standardizedFileURL.path
        let docsPath = docsURL.standardizedFileURL.path
        return path == docsPath || path.hasPrefix(docsPath + "/")
    }

    private func documentsRootURL() -> URL {
        let homePath: String
        if let pw = getpwuid(getuid()), let cHome = pw.pointee.pw_dir {
            homePath = String(cString: cHome)
        } else if let fallback = NSHomeDirectoryForUser(NSUserName()) {
            homePath = fallback
        } else {
            homePath = NSHomeDirectory()
        }
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .standardizedFileURL
    }

    @objc private func opencodeSendTapped() {
        let message = opencodeSendField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard let workingURL = opencodeActiveWorkingURL else {
            setOpencodeStatus("No active session. Press Start first.", isError: true)
            return
        }
        guard !opencodeIsBusy else {
            setOpencodeStatus("Opencode is currently processing. Please wait.", isError: true)
            return
        }
        guard let sessionID = opencodeActiveSessionID else {
            setOpencodeStatus("No active session ID. Press Start to create a new session.", isError: true)
            return
        }

        opencodeSendField.stringValue = ""
        appendOpencodeLine("You", message)
        runOpencodeMessage(message, in: workingURL, sessionID: sessionID, isInitialStart: false)
    }

    private func startNewOpencodeSession(workingURL: URL, initialPrompt: String) {
        opencodeActiveWorkingURL = workingURL
        opencodeActiveSessionID = nil
        updateOpencodeControls()

        let prompt = initialPrompt.isEmpty
            ? "Use the working directory and wait for follow-up instructions."
            : initialPrompt
        appendOpencodeLine("You", prompt)
        runOpencodeMessage(prompt, in: workingURL, sessionID: nil, isInitialStart: true)
    }

    private func runOpencodeMessage(_ message: String, in workingURL: URL, sessionID: String?, isInitialStart: Bool) {
        setOpencodeBusy(true)
        setOpencodeStatus(isInitialStart ? "Starting opencode session…" : "Sending message…", isError: false)

        opencodeCommandToken += 1
        let token = opencodeCommandToken

        if let sessionID {
            beginStreamingOpencodeMessage(
                message,
                sessionID: sessionID,
                workingURL: workingURL,
                isInitialStart: isInitialStart,
                token: token
            )
            return
        }

        guard isInitialStart else {
            setOpencodeBusy(false)
            setOpencodeStatus("No active session ID. Press Start to create a new session.", isError: true)
            return
        }

        createOpencodeSession(workingURL: workingURL) { [weak self] result in
            guard let self else { return }
            guard token == self.opencodeCommandToken else { return }
            switch result {
            case .failure(let error):
                self.setOpencodeBusy(false)
                self.setOpencodeStatus(error.localizedDescription, isError: true)
            case .success(let newSessionID):
                self.opencodeActiveSessionID = newSessionID
                self.updateOpencodeControls()
                self.beginStreamingOpencodeMessage(
                    message,
                    sessionID: newSessionID,
                    workingURL: workingURL,
                    isInitialStart: true,
                    token: token
                )
            }
        }
    }

    private func beginStreamingOpencodeMessage(
        _ message: String,
        sessionID: String,
        workingURL: URL,
        isInitialStart: Bool,
        token: Int
    ) {
        guard let eventURL = opencodeRequestURL(path: "event", workingURL: workingURL) else {
            setOpencodeBusy(false)
            setOpencodeStatus("Invalid opencode server URL.", isError: true)
            return
        }

        stopOpencodeEventStream()
        resetOpencodeStreamingState()

        let stream = OpencodeEventStreamClient(
            onEvent: { [weak self] event in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard token == self.opencodeCommandToken else { return }
                    self.handleOpencodeStreamEvent(event, sessionID: sessionID, isInitialStart: isInitialStart)
                }
            },
            onFailure: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard token == self.opencodeCommandToken else { return }
                    self.finishOpencodeStreaming(withError: message)
                }
            }
        )
        opencodeEventStreamClient = stream
        stream.start(url: eventURL)

        postOpencodePromptAsync(message, sessionID: sessionID, workingURL: workingURL) { [weak self] result in
            guard let self else { return }
            guard token == self.opencodeCommandToken else { return }
            if case .failure(let error) = result {
                self.finishOpencodeStreaming(withError: error.localizedDescription)
            }
        }
    }

    private func handleOpencodeStreamEvent(_ event: [String: Any], sessionID: String, isInitialStart: Bool) {
        guard let type = event["type"] as? String else { return }
        guard let properties = event["properties"] as? [String: Any] else { return }

        switch type {
        case "message.updated":
            guard
                let info = properties["info"] as? [String: Any],
                (info["sessionID"] as? String) == sessionID,
                (info["role"] as? String) == "assistant",
                let messageID = info["id"] as? String
            else { return }
            switchStreamingAssistantMessage(to: messageID)

        case "message.part.delta":
            guard
                (properties["sessionID"] as? String) == sessionID,
                let messageID = properties["messageID"] as? String,
                (properties["field"] as? String) == "text",
                let delta = properties["delta"] as? String
            else { return }
            switchStreamingAssistantMessage(to: messageID)
            appendStreamingAssistantDelta(delta)

        case "message.part.updated":
            guard
                let part = properties["part"] as? [String: Any],
                (part["sessionID"] as? String) == sessionID,
                let partType = part["type"] as? String
            else { return }
            if partType == "text",
               let messageID = part["messageID"] as? String,
               let text = part["text"] as? String {
                switchStreamingAssistantMessage(to: messageID)
                updateStreamingAssistantFullText(text)
            } else if partType == "tool" {
                handleStreamingToolPartUpdate(part)
            }

        case "session.error":
            guard (properties["sessionID"] as? String) == sessionID else { return }
            let message = parseOpencodeSessionError(properties)
            finishOpencodeStreaming(withError: message)

        case "session.idle":
            guard (properties["sessionID"] as? String) == sessionID else { return }
            finishOpencodeStreamingSuccessfully(isInitialStart: isInitialStart, sessionID: sessionID)

        default:
            break
        }
    }

    private func switchStreamingAssistantMessage(to messageID: String) {
        if opencodeStreamingAssistantMessageID == messageID {
            return
        }
        opencodeStreamingAssistantMessageID = messageID
        opencodeStreamingAssistantText = ""
        opencodeStreamingAssistantRange = nil
        opencodeToolStatusByPartID.removeAll(keepingCapacity: true)
    }

    private func appendStreamingAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        opencodeStreamingAssistantText += delta
        renderStreamingAssistantBubble()
    }

    private func updateStreamingAssistantFullText(_ text: String) {
        let normalized = stripANSI(text)
        if normalized.count < opencodeStreamingAssistantText.count, !opencodeStreamingAssistantText.isEmpty {
            return
        }
        opencodeStreamingAssistantText = normalized
        renderStreamingAssistantBubble()
    }

    private func renderStreamingAssistantBubble() {
        let display = cleanOpencodeAssistantText(opencodeStreamingAssistantText)
        guard !display.isEmpty else { return }
        guard let storage = opencodeChatTextView?.textStorage else { return }

        let headerStyle = NSMutableParagraphStyle()
        headerStyle.alignment = .left
        headerStyle.paragraphSpacing = 2

        let bubbleStyle = NSMutableParagraphStyle()
        bubbleStyle.alignment = .left
        bubbleStyle.lineSpacing = 1.5
        bubbleStyle.paragraphSpacing = 12

        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: headerStyle
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            .paragraphStyle: bubbleStyle
        ]
        let bodyText = "  \(display)  \n\n"

        if let range = opencodeStreamingAssistantRange {
            let replacement = NSAttributedString(string: bodyText, attributes: bodyAttributes)
            storage.replaceCharacters(in: range, with: replacement)
            opencodeStreamingAssistantRange = NSRange(location: range.location, length: replacement.length)
        } else {
            storage.append(NSAttributedString(string: "Opencode\n", attributes: headerAttributes))
            let start = storage.length
            let body = NSAttributedString(string: bodyText, attributes: bodyAttributes)
            storage.append(body)
            opencodeStreamingAssistantRange = NSRange(location: start, length: body.length)
        }
        scrollOpencodeChatToBottom()
    }

    private func finishOpencodeStreamingSuccessfully(isInitialStart: Bool, sessionID: String) {
        stopOpencodeEventStream()
        setOpencodeBusy(false)
        if isInitialStart {
            setOpencodeStatus("Session started: \(sessionID)", isError: false)
        } else {
            setOpencodeStatus("Message sent.", isError: false)
        }
        resetOpencodeStreamingState()
    }

    private func finishOpencodeStreaming(withError message: String) {
        stopOpencodeEventStream()
        setOpencodeBusy(false)
        setOpencodeStatus(message, isError: true)
        resetOpencodeStreamingState()
    }

    private func resetOpencodeStreamingState() {
        opencodeStreamingAssistantMessageID = nil
        opencodeStreamingAssistantText = ""
        opencodeStreamingAssistantRange = nil
        opencodeToolStatusByPartID.removeAll(keepingCapacity: false)
    }

    private func stopOpencodeEventStream() {
        opencodeEventStreamClient?.stop()
        opencodeEventStreamClient = nil
    }

    private func parseOpencodeSessionError(_ properties: [String: Any]) -> String {
        if
            let error = properties["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return "Opencode failed: \(message)"
        }
        return "Opencode failed."
    }

    private func handleStreamingToolPartUpdate(_ part: [String: Any]) {
        guard
            let partID = part["id"] as? String,
            let state = part["state"] as? [String: Any],
            let status = state["status"] as? String
        else { return }

        if opencodeToolStatusByPartID[partID] == status {
            return
        }
        opencodeToolStatusByPartID[partID] = status

        let rawToolName = (part["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = (rawToolName?.isEmpty == false) ? (rawToolName ?? "tool") : "tool"

        switch status {
        case "running":
            appendOpencodeLine("Opencode", "[processing] running \(toolName)…")
        case "completed":
            appendOpencodeLine("Opencode", "[processing] finished \(toolName).")
        case "failed":
            appendOpencodeLine("Opencode", "[processing] failed \(toolName).")
        default:
            break
        }
    }

    private func createOpencodeSession(workingURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let requestURL = opencodeRequestURL(path: "session", workingURL: workingURL) else {
            completion(.failure(makeOpencodeError("Invalid opencode server URL.")))
            return
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        performOpencodeRequest(request, completion: completion) { data in
            let decoder = JSONDecoder()
            let response = try decoder.decode(OpencodeSessionCreateResponse.self, from: data)
            return response.id
        }
    }

    private func postOpencodePromptAsync(
        _ message: String,
        sessionID: String,
        workingURL: URL,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        guard let requestURL = opencodeRequestURL(
            path: "session/\(sessionID)/prompt_async",
            workingURL: workingURL
        ) else {
            completion(.failure(makeOpencodeError("Invalid opencode server URL.")))
            return
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = OpencodePromptRequest(parts: [OpencodePromptTextPart(type: "text", text: message)])
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(makeOpencodeError("Failed to encode prompt payload: \(error.localizedDescription)")))
            return
        }

        performOpencodeRequest(request, completion: completion) { _ in
            true
        }
    }

    private func opencodeAttachURL() -> String? {
        if let configured = UserDefaults.standard.string(forKey: "opencode.attachURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }
        return opencodeDefaultAttachURL
    }

    private func opencodeRequestURL(path: String, workingURL: URL) -> URL? {
        guard
            let attachURL = opencodeAttachURL(),
            let baseURL = URL(string: attachURL),
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty {
            components.path = normalizedPath.isEmpty ? "/" : "/\(normalizedPath)"
        } else {
            components.path = normalizedPath.isEmpty ? "/\(basePath)" : "/\(basePath)/\(normalizedPath)"
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll(where: { $0.name == "directory" })
        queryItems.append(URLQueryItem(name: "directory", value: workingURL.path))
        components.queryItems = queryItems
        return components.url
    }

    private func performOpencodeRequest<T>(
        _ request: URLRequest,
        completion: @escaping (Result<T, Error>) -> Void,
        decode: @escaping (Data) throws -> T
    ) {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let urlError = error as? URLError {
                let message = self.opencodeConnectionErrorMessage(urlError)
                DispatchQueue.main.async { completion(.failure(self.makeOpencodeError(message))) }
                return
            }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.failure(self.makeOpencodeError("Opencode server returned an invalid response.")))
                }
                return
            }

            let payload = data ?? Data()
            guard (200..<300).contains(httpResponse.statusCode) else {
                let detail = self.parseOpencodeHTTPError(payload)
                let message = detail.isEmpty
                    ? "Opencode server error (HTTP \(httpResponse.statusCode))."
                    : "Opencode server error (HTTP \(httpResponse.statusCode)): \(detail)"
                DispatchQueue.main.async { completion(.failure(self.makeOpencodeError(message))) }
                return
            }

            do {
                let value = try decode(payload)
                DispatchQueue.main.async { completion(.success(value)) }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(self.makeOpencodeError("Failed to parse opencode response: \(error.localizedDescription)")))
                }
            }
        }
        task.resume()
    }

    private func makeOpencodeError(_ message: String) -> NSError {
        NSError(domain: "CameraShot.Opencode", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func opencodeConnectionErrorMessage(_ error: URLError) -> String {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut, .notConnectedToInternet, .networkConnectionLost:
            let attach = opencodeAttachURL() ?? opencodeDefaultAttachURL
            return "Cannot reach opencode server at \(attach). Start it with ./run.sh and try again."
        default:
            return "Opencode request failed: \(error.localizedDescription)"
        }
    }

    private func parseOpencodeHTTPError(_ payload: Data) -> String {
        guard !payload.isEmpty else { return "" }
        if
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let message = object["message"] as? String ?? object["error"] as? String
        {
            return message
        }
        return String(data: payload, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private struct FileExploreTreeSnapshotEntry: Equatable {
        let isDirectory: Bool
        let modifiedAt: TimeInterval
        let size: Int64
    }

    private struct OpencodeSessionCreateResponse: Decodable {
        let id: String
    }

    private struct OpencodePromptTextPart: Encodable {
        let type: String
        let text: String
    }

    private struct OpencodePromptRequest: Encodable {
        let parts: [OpencodePromptTextPart]
    }

    private final class FileExploreNode: NSObject {
        let url: URL
        let isDirectory: Bool
        weak var parent: FileExploreNode?
        var children: [FileExploreNode] = []
        var isLoaded = false

        init(url: URL, isDirectory: Bool) {
            self.url = url
            self.isDirectory = isDirectory
        }
    }

    private final class OpencodeEventStreamClient: NSObject, URLSessionDataDelegate {
        private let onEvent: ([String: Any]) -> Void
        private let onFailure: (String) -> Void
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var lineBuffer = Data()
        private var dataLines: [String] = []
        private var isStopped = false

        init(onEvent: @escaping ([String: Any]) -> Void, onFailure: @escaping (String) -> Void) {
            self.onEvent = onEvent
            self.onFailure = onFailure
            super.init()
        }

        func start(url: URL) {
            guard !isStopped else { return }
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 0
            configuration.timeoutIntervalForResource = 0
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 0
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            task?.cancel()
            task = nil
            session?.invalidateAndCancel()
            session = nil
            lineBuffer.removeAll(keepingCapacity: false)
            dataLines.removeAll(keepingCapacity: false)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                fail("Opencode stream returned an invalid response.")
                completionHandler(.cancel)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                fail("Opencode stream failed (HTTP \(http.statusCode)).")
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !isStopped else { return }
            lineBuffer.append(data)

            while let newlineRange = lineBuffer.range(of: Data([0x0A])) {
                let lineData = lineBuffer.subdata(in: 0..<newlineRange.lowerBound)
                lineBuffer.removeSubrange(0..<newlineRange.upperBound)
                guard var line = String(data: lineData, encoding: .utf8) else { continue }
                if line.hasSuffix("\r") { line.removeLast() }
                consumeLine(line)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !isStopped else { return }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            if let error {
                fail("Opencode stream disconnected: \(error.localizedDescription)")
            }
        }

        private func consumeLine(_ line: String) {
            if line.isEmpty {
                emitEventIfReady()
                return
            }
            guard line.hasPrefix("data:") else { return }
            var data = String(line.dropFirst(5))
            if data.hasPrefix(" ") { data.removeFirst() }
            dataLines.append(data)
        }

        private func emitEventIfReady() {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            guard let raw = payload.data(using: .utf8) else { return }
            guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
            onEvent(object)
        }

        private func fail(_ message: String) {
            guard !isStopped else { return }
            isStopped = true
            onFailure(message)
            task?.cancel()
            task = nil
            session?.invalidateAndCancel()
            session = nil
            lineBuffer.removeAll(keepingCapacity: false)
            dataLines.removeAll(keepingCapacity: false)
        }
    }

    private func stripANSI(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\u001B\[[0-?]*[ -/]*[@-~]"#) else { return input }
        let range = NSRange(location: 0, length: input.utf16.count)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
    }

    private func cleanOpencodeAssistantText(_ raw: String) -> String {
        let plain = stripANSI(raw)
        let filtered = plain
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return true }
                // Hide status/meta lines like: "> build · claude-sonnet-4-5"
                return !trimmed.hasPrefix("> ")
            }
        return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendOpencodeLine(_ role: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard role == "You" || role == "Opencode" else { return }
        guard let storage = opencodeChatTextView?.textStorage else { return }

        let isUser = role == "You"

        let headerStyle = NSMutableParagraphStyle()
        headerStyle.alignment = isUser ? .right : .left
        headerStyle.paragraphSpacing = 2

        let bubbleStyle = NSMutableParagraphStyle()
        bubbleStyle.alignment = isUser ? .right : .left
        bubbleStyle.lineSpacing = 1.5
        bubbleStyle.paragraphSpacing = 12

        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: headerStyle
        ]

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isUser ? NSColor.white : NSColor.labelColor,
            .backgroundColor: isUser ? NSColor.systemBlue : NSColor.controlBackgroundColor,
            .paragraphStyle: bubbleStyle
        ]

        storage.append(NSAttributedString(string: "\(role)\n", attributes: headerAttributes))
        storage.append(NSAttributedString(string: "  \(trimmed)  \n\n", attributes: bodyAttributes))
        scrollOpencodeChatToBottom()
    }

    private func scrollOpencodeChatToBottom() {
        guard let storage = opencodeChatTextView?.textStorage else { return }
        opencodeChatTextView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    private func setOpencodeBusy(_ busy: Bool) {
        opencodeIsBusy = busy
        updateOpencodeControls()
    }

    private func stopActiveOpencodeProcess(resetSession: Bool) {
        opencodeCommandToken += 1
        stopOpencodeEventStream()
        resetOpencodeStreamingState()
        opencodeIsBusy = false
        if resetSession {
            opencodeActiveSessionID = nil
            opencodeActiveWorkingURL = nil
        }
        updateOpencodeControls()
    }

    private func updateOpencodeControls() {
        let hasSession = opencodeActiveWorkingURL != nil
        opencodeSendField?.isEnabled = hasSession && !opencodeIsBusy
        opencodeSendButton?.isEnabled = hasSession && !opencodeIsBusy
        opencodeStartButton?.title = hasSession ? "Restart" : "Start"
    }

    private func setOpencodeStatus(_ message: String, isError: Bool) {
        opencodeStatusLabel.stringValue = message
        opencodeStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        opencodeStatusLabel.isHidden = message.isEmpty
    }

    @objc private func clearAudioFeed() {
        audioTextView.textStorage?.setAttributedString(NSAttributedString())
        transcriptBuffer = ""
        lastSentTranscript = ""
    }

    @objc private func clearAudioAI() {
        audioAIWebView.evaluateJavaScript("clearFeed()", completionHandler: nil)
        audioAICurrentEntry = nil
        audioAIStreamingText = ""
    }

    // MARK: – AI helpers

    private func startStreamingEntry(imageURL: URL, entryId: Int) {
        let header = "[\(Self.timeString())]  \(imageURL.lastPathComponent)"
        guard let hJS = jsLiteral(header) else { return }
        webView.evaluateJavaScript("startStreamingEntry(\(hJS), null, \(entryId))", completionHandler: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dataURL = Self.thumbnailDataURL(for: imageURL, maxWidth: 280)
            DispatchQueue.main.async {
                guard let self else { return }
                if let url = dataURL, let urlJS = self.jsLiteral(url) {
                    self.webView.evaluateJavaScript("setStreamingEntryThumbnail(\(entryId), \(urlJS))", completionHandler: nil)
                }
            }
        }
    }

    private static func thumbnailDataURL(for url: URL, maxWidth: CGFloat) -> String? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let size = img.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxWidth / size.width)
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        guard w > 0, h > 0 else { return nil }
        let small = NSImage(size: NSSize(width: w, height: h))
        small.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                 from: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                 operation: .copy, fraction: 1)
        small.unlockFocus()
        guard let tiff = small.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    private func appendEntry(header: String, body: String, isError: Bool) {
        pendingEntries.append((header, body, isError))
        flushPendingEntries()
    }

    private func flushPendingEntries() {
        guard aiPageReady, !pendingEntries.isEmpty else { return }
        for item in pendingEntries {
            guard let hJS = jsLiteral(item.header), let bJS = jsLiteral(item.body) else { continue }
            let js = "appendEntry(\(hJS), \(bJS), \(item.isError ? "true" : "false"))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        pendingEntries.removeAll()
    }

    @objc private func zoomIn()  { webView.evaluateJavaScript("adjustZoom(1)",  completionHandler: nil) }
    @objc private func zoomOut() { webView.evaluateJavaScript("adjustZoom(-1)", completionHandler: nil) }
    @objc private func clearAI() { webView.evaluateJavaScript("clearFeed()",    completionHandler: nil) }

    private func jsLiteral(_ s: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let str  = String(data: data, encoding: .utf8) else { return nil }
        return String(str.dropFirst().dropLast())
    }

    private func updateAIStatus() {
        if pendingCount > 0 {
            spinner.startAnimation(nil)
            aiStatus.stringValue = pendingCount == 1 ? "Processing…" : "Processing \(pendingCount)…"
        } else {
            spinner.stopAnimation(nil)
            aiStatus.stringValue = ""
        }
    }

    private static func resourcesBaseURL() -> URL? {
        func hasMarked(at base: URL) -> Bool {
            FileManager.default.fileExists(atPath: base.appendingPathComponent("marked.min.js").path)
        }
        let appResources = Bundle.main.resourceURL?.appendingPathComponent("Resources")
        if let url = appResources, hasMarked(at: url) { return url }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.resourceURL, hasMarked(at: url) { return url }
        #endif
        return appResources
    }

    private static func timeString() -> String {
        DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    }

    private static let fileExploreHTMLTemplate = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <link rel="stylesheet" href="github-dark-dimmed.min.css">
    <script src="marked.min.js"></script>
    <script src="highlight.min.js"></script>
    <style>
      *, *::before, *::after { box-sizing: border-box; }
      :root {
        --bg: #ffffff;
        --fg: #1c1c1e;
        --border: #d1d1d6;
        --muted: #6b7280;
        --code-bg: rgba(0,0,0,0.05);
        --font-size: 14px;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #1c1c1e;
          --fg: #e5e5ea;
          --border: #3a3a3c;
          --muted: #9ca3af;
          --code-bg: rgba(255,255,255,0.08);
        }
      }
      html, body {
        margin: 0;
        padding: 0;
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        font-size: var(--font-size);
        line-height: 1.65;
        word-break: break-word;
      }
      #root {
        padding: 14px 16px;
      }
      .placeholder {
        color: var(--muted);
      }
      h1 { font-size: 1.45em; margin: 20px 0 8px; }
      h2 { font-size: 1.25em; margin: 18px 0 8px; }
      h3 { font-size: 1.1em; margin: 14px 0 6px; }
      h4, h5, h6 { font-size: 1em; margin: 12px 0 4px; }
      p { margin: 8px 0; }
      ul, ol { padding-left: 24px; margin: 8px 0; }
      li { margin: 3px 0; }
      blockquote {
        border-left: 3px solid var(--border);
        margin: 10px 0;
        padding: 4px 14px;
        color: var(--muted);
      }
      table {
        border-collapse: collapse;
        width: 100%;
        margin: 12px 0;
      }
      th, td {
        border: 1px solid var(--border);
        padding: 6px 10px;
        text-align: left;
        vertical-align: top;
      }
      th {
        background: var(--code-bg);
        font-weight: 600;
      }
      .table-wrap {
        overflow-x: auto;
      }
      pre {
        overflow-x: auto;
        border: 1px solid var(--border);
        border-radius: 8px;
        padding: 10px;
        margin: 12px 0;
        background: var(--code-bg);
      }
      code, pre {
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, "Courier New", monospace;
      }
      code:not(pre > code) {
        background: var(--code-bg);
        border-radius: 4px;
        padding: 2px 5px;
        font-size: 0.9em;
      }
      pre > code {
        background: transparent !important;
        padding: 0 !important;
      }
    </style>
    </head>
    <body>
      <div id="root"><div class="placeholder">Select a file from the sidebar.</div></div>
      <script>
        var currentFontSize = 14;

        function escapeHtml(input) {
          return input
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
        }

        function highlightBlocks(root) {
          if (typeof hljs === 'undefined') return;
          root.querySelectorAll('pre code').forEach(function(block) {
            try { hljs.highlightElement(block); } catch (_) {}
          });
        }

        function normalizeMarkdownHtml(root) {
          root.querySelectorAll('table').forEach(function(table) {
            if (table.parentElement && table.parentElement.classList && table.parentElement.classList.contains('table-wrap')) {
              return;
            }
            var wrap = document.createElement('div');
            wrap.className = 'table-wrap';
            table.parentNode.insertBefore(wrap, table);
            wrap.appendChild(table);
          });
        }

        function renderDocument(kind, content) {
          var root = document.getElementById('root');
          if (!root) return;

          if (!content || content.length === 0) {
            root.innerHTML = '<div class="placeholder">Empty file.</div>';
            return;
          }

          if (kind === 'markdown' && typeof marked !== 'undefined' && marked.parse) {
            root.innerHTML = marked.parse(content);
            normalizeMarkdownHtml(root);
            highlightBlocks(root);
            return;
          }

          if (kind === 'python' && typeof marked !== 'undefined' && marked.parse) {
            var wrapped = '```python\\n' + content + '\\n```';
            root.innerHTML = marked.parse(wrapped);
            normalizeMarkdownHtml(root);
            highlightBlocks(root);
            return;
          }

          root.innerHTML = '<pre><code>' + escapeHtml(content) + '</code></pre>';
          highlightBlocks(root);
        }

        function adjustZoom(delta) {
          currentFontSize = Math.min(Math.max(currentFontSize + delta, 9), 30);
          document.documentElement.style.setProperty('--font-size', currentFontSize + 'px');
        }

        if (typeof marked !== 'undefined' && marked.use) {
          marked.use({
            gfm: true,
            breaks: true,
            highlight: function(code, lang) {
              if (typeof hljs === 'undefined') return code;
              if (lang && hljs.getLanguage(lang)) return hljs.highlight(code, { language: lang }).value;
              return hljs.highlightAuto(code).value;
            }
          });
        }

        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pageReady) {
          window.webkit.messageHandlers.pageReady.postMessage('ready');
        }
      </script>
    </body>
    </html>
    """

    // MARK: – HTML template

    private static let htmlTemplate = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="UTF-8">
    <link rel="stylesheet" href="github-dark-dimmed.min.css">
    <script src="marked.min.js"></script>
    <script src="highlight.min.js"></script>
    <script src="mermaid.min.js"></script>
    <style>
      *, *::before, *::after { box-sizing: border-box; }

      :root {
        --bg:         #ffffff;
        --fg:         #1c1c1e;
        --fg2:        #636366;
        --border:     #d1d1d6;
        --code-bg:    rgba(0,0,0,0.05);
        --block-bg:   #1e1e2e;
        --font-size:  14px;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg:      #1c1c1e;
          --fg:      #e5e5ea;
          --fg2:     #8e8e93;
          --border:  #3a3a3c;
          --code-bg: rgba(255,255,255,0.08);
        }
      }

      html, body {
        margin: 0; padding: 0;
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
        font-size: var(--font-size);
        line-height: 1.7;
        word-break: break-word;
      }

      #feed { padding: 24px; }

      h1 { font-size: 1.45em; margin: 20px 0 8px; }
      h2 { font-size: 1.25em; margin: 18px 0 8px; }
      h3 { font-size: 1.1em;  margin: 14px 0 6px; }
      h4, h5, h6 { font-size: 1em; margin: 12px 0 4px; }
      p  { margin: 8px 0; }
      ul, ol { padding-left: 26px; margin: 8px 0; }
      li { margin: 3px 0; }
      strong { font-weight: 600; }

      blockquote {
        border-left: 3px solid var(--border);
        margin: 10px 0;
        padding: 4px 14px;
        color: var(--fg2);
      }

      code:not(pre > code) {
        background: var(--code-bg);
        border-radius: 4px;
        padding: 2px 5px;
        font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 0.87em;
      }

      .code-wrapper {
        position: relative;
        margin: 14px 0;
        border-radius: 10px;
        overflow: hidden;
      }
      pre {
        margin: 0;
        padding: 16px 18px;
        overflow-x: auto;
        background: var(--block-bg) !important;
        border-radius: 0;
      }
      pre > code {
        font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 0.87em;
        line-height: 1.55;
        background: transparent !important;
        padding: 0 !important;
      }

      .lang-label {
        position: absolute;
        top: 8px;
        left: 12px;
        font-family: 'SF Mono', monospace;
        font-size: 10px;
        color: rgba(255,255,255,0.35);
        text-transform: lowercase;
        pointer-events: none;
        user-select: none;
      }

      .copy-btn {
        position: absolute;
        top: 7px;
        right: 10px;
        background: rgba(255,255,255,0.10);
        border: 1px solid rgba(255,255,255,0.18);
        border-radius: 5px;
        color: rgba(255,255,255,0.65);
        font-size: 11px;
        padding: 3px 9px;
        cursor: pointer;
        font-family: -apple-system, sans-serif;
        transition: background 0.12s, color 0.12s;
        user-select: none;
        -webkit-user-select: none;
      }
      .copy-btn:hover  { background: rgba(255,255,255,0.20); color: #fff; }
      .copy-btn.copied { color: #32d74b; border-color: #32d74b; }

      .entry-header {
        font-family: 'SF Mono', monospace;
        font-size: 11px;
        color: var(--fg2);
        margin-bottom: 10px;
        white-space: pre-line;
      }

      .entry-thumbnail {
        max-width: 280px;
        max-height: 160px;
        width: auto;
        height: auto;
        border-radius: 8px;
        margin-bottom: 10px;
        display: block;
        border: 1px solid var(--border);
      }

      .streaming-body {
        white-space: pre-wrap;
        word-break: break-word;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
        min-height: 1em;
      }

      .entry-divider {
        border: none;
        border-top: 1px solid var(--border);
        margin: 28px 0;
      }

      .entry-error-body {
        color: #ff3b30;
      }

      table { border-collapse: collapse; width: 100%; margin: 12px 0; }
      th, td { border: 1px solid var(--border); padding: 6px 10px; text-align: left; }
      th { background: var(--code-bg); font-weight: 600; }

      .mermaid-wrapper {
        background: #1e1e2e;
        border-radius: 10px;
        padding: 20px;
        margin: 14px 0;
        display: flex;
        justify-content: center;
        overflow-x: auto;
      }
      .mermaid-wrapper svg { max-width: 100%; height: auto; }
      .mermaid-error {
        color: #ff3b30;
        font-family: 'SF Mono', monospace;
        font-size: 12px;
        padding: 8px;
      }
    </style>
    </head>
    <body>
    <div id="feed"></div>
    <script>
      var currentFontSize = 14;
      var userScrolledUp = false;
      var streamingBodiesById = Object.create(null);
      window.addEventListener('scroll', function() {
        var sv = document.scrollingElement || document.documentElement;
        userScrolledUp = sv.scrollTop + sv.clientHeight < sv.scrollHeight - 60;
      }, { passive: true });

      function escapeHtml(s) {
        var div = document.createElement('div');
        div.textContent = s;
        return div.innerHTML;
      }
      function startStreamingEntry(header, imageDataURL, entryId) {
        try {
          var feed = document.getElementById('feed');
          if (!feed) return;
          if (feed.children.length > 0) {
            var hr = document.createElement('hr');
            hr.className = 'entry-divider';
            feed.appendChild(hr);
          }
          var entry = document.createElement('div');
          entry.dataset.entryId = String(entryId);
          var hdr = document.createElement('div');
          hdr.className = 'entry-header';
          hdr.textContent = header;
          entry.appendChild(hdr);
          if (imageDataURL) {
            var img = document.createElement('img');
            img.className = 'entry-thumbnail';
            img.src = imageDataURL;
            img.alt = 'Screenshot';
            entry.appendChild(img);
          }
          var body = document.createElement('div');
          body.className = 'streaming-body';
          body.textContent = '';
          entry.appendChild(body);
          feed.appendChild(entry);
          streamingBodiesById[String(entryId)] = body;
          var sv = document.scrollingElement || document.documentElement;
          if (!userScrolledUp) sv.scrollTop = sv.scrollHeight;
        } catch (e) { console.error('startStreamingEntry', e); }
      }
      function setStreamingEntryThumbnail(entryId, dataURL) {
        var entry = document.querySelector('[data-entry-id="' + entryId + '"]');
        if (!entry || !dataURL) return;
        var img = entry.querySelector('img.entry-thumbnail');
        if (!img) {
          img = document.createElement('img');
          img.className = 'entry-thumbnail';
          img.alt = 'Screenshot';
          var hdr = entry.querySelector('.entry-header');
          if (hdr && hdr.nextSibling) entry.insertBefore(img, hdr.nextSibling);
          else if (hdr) entry.appendChild(img);
          else entry.insertBefore(img, entry.firstChild);
        }
        img.src = dataURL;
      }
      function appendStreamingChunk(entryId, text) {
        var body = streamingBodiesById[String(entryId)];
        if (body) {
          body.textContent += text;
          var sv = document.scrollingElement || document.documentElement;
          if (!userScrolledUp) sv.scrollTop = sv.scrollHeight;
        }
      }
      function endStreamingEntry(entryId, markdown) {
        var key = String(entryId);
        var body = streamingBodiesById[key];
        if (!body) return;
        delete streamingBodiesById[key];
        body.classList.remove('streaming-body');
        var html = (typeof marked !== 'undefined' && marked.parse) ? marked.parse(markdown) : markdown.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\\n/g, '<br>');
        body.innerHTML = html;
        var mermaidNodes = [];
        Array.from(body.querySelectorAll('pre')).forEach(function(pre) {
          var codeEl = pre.querySelector('code');
          var lang = '';
          if (codeEl) { var m = (codeEl.className || '').match(/language-(\\S+)/); if (m) lang = m[1]; }
          if (lang === 'mermaid' && typeof mermaid !== 'undefined' && mermaid.run) {
            var diagram = codeEl ? codeEl.textContent : pre.textContent;
            var wrapper = document.createElement('div');
            wrapper.className = 'mermaid-wrapper';
            var inner = document.createElement('div');
            inner.className = 'mermaid';
            inner.textContent = diagram;
            wrapper.appendChild(inner);
            pre.parentNode.insertBefore(wrapper, pre);
            pre.parentNode.removeChild(pre);
            mermaidNodes.push(inner);
            return;
          }
          if (codeEl && typeof hljs !== 'undefined') {
            if (lang && hljs.getLanguage(lang)) codeEl.innerHTML = hljs.highlight(codeEl.textContent, { language: lang }).value;
            else hljs.highlightElement(codeEl);
          }
          var wrapper = document.createElement('div');
          wrapper.className = 'code-wrapper';
          pre.parentNode.insertBefore(wrapper, pre);
          wrapper.appendChild(pre);
          if (lang) { var badge = document.createElement('span'); badge.className = 'lang-label'; badge.textContent = lang; wrapper.appendChild(badge); }
          var btn = document.createElement('button');
          btn.className = 'copy-btn';
          btn.textContent = 'Copy';
          btn.addEventListener('click', function() {
            var text = codeEl ? codeEl.innerText : pre.innerText;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyCode) window.webkit.messageHandlers.copyCode.postMessage(text);
            btn.textContent = 'Copied!'; btn.classList.add('copied');
            setTimeout(function() { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 1600);
          });
          wrapper.appendChild(btn);
        });
        if (mermaidNodes.length > 0 && typeof mermaid !== 'undefined' && mermaid.run) {
          mermaid.run({ nodes: mermaidNodes }).catch(function(err) {
            mermaidNodes.forEach(function(n) { n.innerHTML = '<span class="mermaid-error">Mermaid error: ' + err.message + '</span>'; });
          });
        }
        var sv = document.scrollingElement || document.documentElement;
        if (!userScrolledUp) sv.scrollTop = sv.scrollHeight;
      }
      function endStreamingEntryAsError(entryId, message) {
        var key = String(entryId);
        var body = streamingBodiesById[key];
        if (!body) return;
        delete streamingBodiesById[key];
        body.classList.remove('streaming-body');
        body.classList.add('entry-error-body');
        body.textContent = message;
      }

      function appendEntry(header, markdown, isError) {
        try {
          var sv = document.scrollingElement || document.documentElement;
          var feed = document.getElementById('feed');
          if (!feed) return;
          if (feed.children.length > 0) {
            var hr = document.createElement('hr');
            hr.className = 'entry-divider';
            feed.appendChild(hr);
          }
          var entry = document.createElement('div');
          var hdr = document.createElement('div');
          hdr.className = 'entry-header';
          hdr.textContent = header;
          entry.appendChild(hdr);
          var body = document.createElement('div');
          if (isError) {
            body.className = 'entry-error-body';
            body.textContent = markdown;
          } else {
            var html = (typeof marked !== 'undefined' && marked.parse)
              ? marked.parse(markdown)
              : markdown.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\\n/g, '<br>');
            body.innerHTML = html;
            var mermaidNodes = [];
            body.querySelectorAll('pre').forEach(function(pre) {
              var codeEl = pre.querySelector('code');
              var lang = '';
              if (codeEl) { var m = (codeEl.className || '').match(/language-(\\S+)/); if (m) lang = m[1]; }
              if (lang === 'mermaid' && typeof mermaid !== 'undefined' && mermaid.run) {
                var diagram = codeEl ? codeEl.textContent : pre.textContent;
                var wrapper = document.createElement('div');
                wrapper.className = 'mermaid-wrapper';
                var inner = document.createElement('div');
                inner.className = 'mermaid';
                inner.textContent = diagram;
                wrapper.appendChild(inner);
                pre.parentNode.insertBefore(wrapper, pre);
                pre.parentNode.removeChild(pre);
                mermaidNodes.push(inner);
                return;
              }
              if (codeEl && typeof hljs !== 'undefined') {
                if (lang && hljs.getLanguage(lang)) codeEl.innerHTML = hljs.highlight(codeEl.textContent, { language: lang }).value;
                else hljs.highlightElement(codeEl);
              }
              var wrapper = document.createElement('div');
              wrapper.className = 'code-wrapper';
              pre.parentNode.insertBefore(wrapper, pre);
              wrapper.appendChild(pre);
              if (lang) { var badge = document.createElement('span'); badge.className = 'lang-label'; badge.textContent = lang; wrapper.appendChild(badge); }
              var btn = document.createElement('button');
              btn.className = 'copy-btn';
              btn.textContent = 'Copy';
              btn.addEventListener('click', function() {
                var text = codeEl ? codeEl.innerText : pre.innerText;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyCode) window.webkit.messageHandlers.copyCode.postMessage(text);
                btn.textContent = 'Copied!'; btn.classList.add('copied');
                setTimeout(function() { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 1600);
              });
              wrapper.appendChild(btn);
            });
            if (mermaidNodes.length > 0 && typeof mermaid !== 'undefined' && mermaid.run) {
              mermaid.run({ nodes: mermaidNodes }).catch(function(err) {
                mermaidNodes.forEach(function(n) { n.innerHTML = '<span class="mermaid-error">Mermaid error: ' + err.message + '</span>'; });
              });
            }
          }
          entry.appendChild(body);
          feed.appendChild(entry);
          if (!userScrolledUp) sv.scrollTop = sv.scrollHeight;
        } catch (e) {
          var feed = document.getElementById('feed');
          if (feed) {
            var errDiv = document.createElement('div');
            errDiv.className = 'entry-error-body';
            errDiv.textContent = 'Display error: ' + e.message + ' | Raw: ' + (markdown ? markdown.substring(0, 200) : '');
            feed.appendChild(errDiv);
          }
        }
      }

      function clearFeed() { document.getElementById('feed').innerHTML = ''; }

      function adjustZoom(delta) {
        currentFontSize = Math.min(Math.max(currentFontSize + delta, 9), 30);
        document.documentElement.style.setProperty('--font-size', currentFontSize + 'px');
      }

      if (typeof mermaid !== 'undefined') {
        mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'loose', fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif' });
      }
      if (typeof marked !== 'undefined' && marked.use) {
        marked.use({
          gfm: true,
          breaks: true,
          highlight: function(code, lang) {
            if (typeof hljs === 'undefined') return code;
            if (lang && lang !== 'mermaid' && hljs.getLanguage(lang)) return hljs.highlight(code, { language: lang }).value;
            return lang === 'mermaid' ? code : hljs.highlightAuto(code).value;
          }
        });
      }
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pageReady) {
        window.webkit.messageHandlers.pageReady.postMessage('ready');
      }
    </script>
    </body>
    </html>
    """
}

// MARK: - File Explore Outline

extension CaptureWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard outlineView === fileExploreOutlineView else { return 0 }
        if let node = item as? FileExploreNode {
            loadFileExploreChildrenIfNeeded(for: node)
            return node.children.count
        }
        guard let root = fileExploreRootNode else { return 0 }
        loadFileExploreChildrenIfNeeded(for: root)
        return root.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileExploreNode {
            return node.children[index]
        }
        guard let root = fileExploreRootNode else { return NSObject() }
        return root.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard outlineView === fileExploreOutlineView, let node = item as? FileExploreNode else { return false }
        return node.isDirectory
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard outlineView === fileExploreOutlineView, let node = item as? FileExploreNode else { return true }
        // Refresh this directory when the user opens it.
        node.isLoaded = false
        loadFileExploreChildrenIfNeeded(for: node)
        outlineView.reloadItem(node, reloadChildren: true)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard outlineView === fileExploreOutlineView, let node = item as? FileExploreNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileExploreCell")

        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyDown
            cell.imageView = iconView
            cell.addSubview(iconView)

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.textField = textField
            cell.addSubview(textField)

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = node.url.lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView, outlineView === fileExploreOutlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileExploreNode else {
            fileExploreSelectedFileURL = nil
            fileExploreSelectedFingerprint = nil
            updateFileExploreRealtimeRefreshState()
            return
        }
        guard !node.isDirectory else {
            fileExploreSelectedFileURL = nil
            fileExploreSelectedFingerprint = nil
            renderFileExploreDocument(kind: "text", content: "Select a file from the sidebar.")
            updateFileExploreRealtimeRefreshState()
            return
        }
        previewFileExploreFile(at: node.url)
    }
}

// MARK: - WKNavigationDelegate

extension CaptureWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        aiPageReady = true
        flushPendingEntries()
    }
}

// MARK: - CopyCodeHandler

private final class CopyCodeHandler: NSObject, WKScriptMessageHandler {
    var onPageReady: (() -> Void)?

    init(pageReady: (() -> Void)? = nil) {
        self.onPageReady = pageReady
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "pageReady" {
            onPageReady?()
            return
        }
        if message.name == "copyCode", let text = message.body as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

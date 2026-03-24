import AppKit
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

    // MARK: – Content tab (Visual / Transcript / Audio AI)

    private weak var contentTabControl: NSSegmentedControl!
    private var activeContentTab = 0   // 0 = Visual, 1 = Transcript, 2 = Audio AI

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

    // Transcript feed
    private weak var audioScrollView: NSScrollView!
    private var audioTextView:        NSTextView!   // strong (inside scrollview)
    private var transcriptBuffer:     String = ""   // last N chars for Audio AI
    private var partialRange:         NSRange?      // range of current partial line (nil = none)

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
        win.title           = "CameraShot  ·  \(name)"
        win.minSize         = NSSize(width: 700, height: 440)
        win.isMovableByWindowBackground = true
        super.init(window: win)
        buildUI(name: name, interval: interval)
    }

    deinit { audioAITimer?.invalidate() }

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

    /// Shows `text` as a replaceable live-preview line (dim, italic). Replaces any previous partial.
    func appendPartialTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let ts = audioTextView.textStorage else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let replacement = NSAttributedString(string: text + "\n", attributes: attrs)
            if let range = partialRange {
                ts.replaceCharacters(in: range, with: replacement)
                partialRange = NSRange(location: range.location, length: replacement.length)
            } else {
                let insertLoc = ts.length
                ts.append(replacement)
                partialRange = NSRange(location: insertLoc, length: replacement.length)
            }
            scrollAudioToBottom()
        }
    }

    /// Commits `text` as a permanent line and adds it to the AI transcript buffer.
    func appendFinalTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let ts = audioTextView.textStorage else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
            let committed = NSAttributedString(string: text + "\n", attributes: attrs)
            if let range = partialRange {
                ts.replaceCharacters(in: range, with: committed)
                partialRange = nil
            } else {
                ts.append(committed)
            }
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
            labels: ["Visual", "Transcript", "Audio AI"],
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

            // WebView (Visual) — all three content views share the same frame
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
        ])

        let baseURL: URL? = Self.resourcesBaseURL()
        wv.loadHTMLString(Self.htmlTemplate, baseURL: baseURL)
        aiWV.loadHTMLString(Self.htmlTemplate, baseURL: baseURL)
        return container
    }

    @objc private func contentTabChanged() {
        activeContentTab = contentTabControl.selectedSegment
        let isVisual     = activeContentTab == 0
        let isTranscript = activeContentTab == 1
        let isAudioAI    = activeContentTab == 2

        webView.isHidden         = !isVisual
        audioScrollView.isHidden = !isTranscript
        audioAIWebView.isHidden  = !isAudioAI

        zoomOutBtn.isHidden       = !isVisual
        zoomInBtn.isHidden        = !isVisual
        visualClearBtn.isHidden   = !isVisual
        audioClearBtn.isHidden    = !isTranscript
        audioAIZoomOutBtn.isHidden = !isAudioAI
        audioAIZoomInBtn.isHidden  = !isAudioAI
        audioAIClearBtn.isHidden   = !isAudioAI
        audioAIAskBtn.isHidden     = !isAudioAI
    }

    @objc private func clearAudioFeed() {
        audioTextView.textStorage?.setAttributedString(NSAttributedString())
        transcriptBuffer = ""
        lastSentTranscript = ""
        partialRange = nil
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

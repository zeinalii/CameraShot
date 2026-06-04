import AppKit
import Darwin
import ImageIO
import WebKit

// MARK: - CaptureWindowController

final class CaptureWindowController: NSWindowController {

    // MARK: – AI

    private var webView: WKWebView!
    private let visualBridge = WebViewBatchBridge(label: "visual")
    private var aiPageReady = false
    private var pendingEntries: [(header: String, body: String, isError: Bool)] = []
    private var pendingVisualScripts: [String] = []
    private var visualPendingChunksByEntryID: [Int: String] = [:]
    private var visualChunkFlushWorkItem: DispatchWorkItem?
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
    /// Called when the user wants to cancel the current visual AI call and retry the latest screenshot.
    var onRetryAI: (() -> Void)?
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
    private weak var visualRetryBtn: NSButton!
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
    private var opencodeChatWebView: WKWebView!
    private let opencodeBridge = WebViewBatchBridge(label: "opencode")
    private var opencodeChatPageReady = false
    private var opencodePendingChatEntries: [(header: String, body: String, isError: Bool)] = []
    private var opencodePendingChatScripts: [String] = []
    private var opencodeActiveSessionID: String?
    private var opencodeActiveWorkingURL: URL?
    private var opencodeCommandToken: Int = 0
    private var opencodeIsBusy = false
    private let opencodeDefaultAttachURL = "http://127.0.0.1:4096"
    private var opencodeEventStreamClient: OpencodeEventStreamClient?
    private var opencodeStreamingAssistantMessageID: String?
    private var opencodeStreamingAssistantText: String = ""
    private var opencodeStreamingEntryIDByMessageID: [String: Int] = [:]
    private var opencodeCurrentStreamingEntryID: Int?
    private var opencodeNextStreamingEntryID = 0
    private var opencodeToolStatusByPartID: [String: String] = [:]
    private var opencodePendingStreamingChunksByEntryID: [Int: String] = [:]
    private var opencodeChunkFlushWorkItem: DispatchWorkItem?
    private var opencodeStreamTimeoutWorkItem: DispatchWorkItem?
    private var opencodePerfEventCount = 0
    private var opencodePerfLastLogAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var opencodeSourceScopeURL: URL?
    private var opencodeWorkingScopeURL: URL?
    private let opencodeInitialPromptDefaultsKey = "opencode.initialPrompt"

    // File Explore tab controls
    private weak var fileExploreContainerView: NSView!
    private weak var fileExploreRootLabel: NSTextField!
    private weak var fileExploreOutlineView: NSOutlineView!
    private weak var fileExploreSidebarScrollView: NSScrollView!
    private var fileExplorePreviewWebView: WKWebView!
    private let fileExploreBridge = WebViewBatchBridge(label: "fileExplore")
    private weak var fileExploreZoomOutButton: NSButton!
    private weak var fileExploreZoomInButton: NSButton!
    private var fileExplorePreviewReady = false
    private var fileExploreRootNode: FileExploreNode?
    private var fileExploreNodeByPath: [String: FileExploreNode] = [:]
    private var fileExploreCurrentRootURL: URL?
    private var fileExplorePendingRender: (kind: String, content: String)?
    private var fileExploreWatcher = FileExploreWatcher()
    private var fileExploreChangeDebounceWorkItem: DispatchWorkItem?
    private var fileExploreRealtimeRefreshTimer: Timer?
    private var fileExploreWatcherActive = false
    private var fileExploreIconCache: [String: NSImage] = [:]
    private let fileExplorePreviewQueue = DispatchQueue(label: "camerashot.file-explore-preview", qos: .userInitiated)
    private var fileExplorePreviewToken = 0
    private var fileExploreSelectedFileURL: URL?
    private var fileExploreSelectedFingerprint: String?
    private let fileExplorePreviewMaxBytes = 1_500_000

    // Transcript feed
    private weak var audioScrollView: NSScrollView!
    private var audioTextView:        NSTextView!   // strong (inside scrollview)
    private var transcriptBuffer:     String = ""   // last N chars for Audio AI
    private let transcriptDisplayCharLimit = 200_000

    // Audio AI feed
    private var audioAIWebView:      WKWebView!     // strong
    private let audioAIBridge = WebViewBatchBridge(label: "audioAI")
    private var audioAIPageReady     = false
    private var audioAINextEntryId   = 0
    private var audioAICurrentEntry: Int?           // nil = no active streaming entry
    private var audioAIStreamingText = ""
    private var audioAIPendingChunksByEntryID: [Int: String] = [:]
    private var audioAIChunkFlushWorkItem: DispatchWorkItem?

    // Audio AI callbacks / timer
    var onAudioAIRequest: ((String) -> Bool)?
    var audioAITokenLimit: Int = 500          // ~4 chars per token
    private var audioAITimer: Timer?
    private var memoryMaintenanceTimer: Timer?
    private let captureInterval: TimeInterval
    private var lastSentTranscript: String = ""
    private var pendingTranscriptCharsSinceLastSend: Int = 0

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
        win.tabbingMode = .disallowed
        win.title           = "CameraShot  ·  \(name)"
        win.minSize         = NSSize(width: 700, height: 440)
        win.isMovableByWindowBackground = true
        super.init(window: win)
        buildUI(name: name, interval: interval)
        startMemoryMaintenanceTimer()
    }

    deinit {
        audioAITimer?.invalidate()
        memoryMaintenanceTimer?.invalidate()
        visualChunkFlushWorkItem?.cancel()
        audioAIChunkFlushWorkItem?.cancel()
        opencodeChunkFlushWorkItem?.cancel()
        fileExploreChangeDebounceWorkItem?.cancel()
        pendingVisualScripts.removeAll(keepingCapacity: false)
        visualBridge.clear()
        audioAIBridge.clear()
        opencodeBridge.clear()
        fileExploreBridge.clear()
        stopOpencodeEventStream()
        stopFileExploreRealtimeRefresh()
        opencodeSourceScopeURL?.stopAccessingSecurityScopedResource()
        opencodeWorkingScopeURL?.stopAccessingSecurityScopedResource()
    }

    /// Call this once voice input is confirmed enabled to start the auto-trigger timer.
    func startAudioAITimer() {
        audioAITimer?.invalidate()
        let interval = max(0.5, captureInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.triggerAudioAI()
        }
        timer.tolerance = min(0.4, interval * 0.25)
        RunLoop.main.add(timer, forMode: .common)
        audioAITimer = timer
    }

    func closeCurrentSession() {
        audioAITimer?.invalidate()
        audioAITimer = nil
        stopMemoryMaintenanceTimer()
        stopActiveOpencodeProcess(resetSession: true, closeRemoteSession: true)
        stopFileExploreRealtimeRefresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Self Maintenance

    private func startMemoryMaintenanceTimer() {
        memoryMaintenanceTimer?.invalidate()
        let interval = RetentionPolicy.memoryMaintenanceInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.runMemoryMaintenance(reason: "timer")
        }
        timer.tolerance = min(10, interval * 0.25)
        RunLoop.main.add(timer, forMode: .common)
        memoryMaintenanceTimer = timer
        runMemoryMaintenance(reason: "startup")
    }

    private func stopMemoryMaintenanceTimer() {
        memoryMaintenanceTimer?.invalidate()
        memoryMaintenanceTimer = nil
    }

    private func runMemoryMaintenance(reason: String) {
        trimVisualNativeState(reason: reason)
        trimAudioAINativeState(reason: reason)
        trimOpencodeNativeState(reason: reason)
        trimFileExploreNativeState(reason: reason)

        if aiPageReady {
            visualBridge.enqueue("performMemoryMaintenance()", immediate: true)
        }
        if audioAIPageReady {
            audioAIBridge.enqueue("performMemoryMaintenance()", immediate: true)
        }
        if opencodeChatPageReady {
            opencodeBridge.enqueue("performMemoryMaintenance()", immediate: true)
        }
    }

    private func trimVisualNativeState(reason: String) {
        let activeEntryIDs = Set(entryIdByImageURL.values)
        let chunkCountBefore = visualPendingChunksByEntryID.count
        visualPendingChunksByEntryID = visualPendingChunksByEntryID.filter { activeEntryIDs.contains($0.key) }

        if pendingEntries.count > RetentionPolicy.pendingVisualEntryLimit {
            pendingEntries.removeFirst(pendingEntries.count - RetentionPolicy.pendingVisualEntryLimit)
        }
        if pendingVisualScripts.count > RetentionPolicy.pendingVisualScriptLimit {
            pendingVisualScripts.removeFirst(pendingVisualScripts.count - RetentionPolicy.pendingVisualScriptLimit)
        }
        if pendingCount != entryIdByImageURL.count {
            pendingCount = entryIdByImageURL.count
        }

        if chunkCountBefore != visualPendingChunksByEntryID.count {
            DevLog.log(
                "VisualUI",
                "memory maintenance reason=\(reason) trimmedVisualChunks \(chunkCountBefore)->\(visualPendingChunksByEntryID.count)"
            )
        }
    }

    private func trimAudioAINativeState(reason: String) {
        guard let activeEntry = audioAICurrentEntry else {
            if !audioAIPendingChunksByEntryID.isEmpty {
                DevLog.log("AudioAI", "memory maintenance reason=\(reason) clearing stale audio chunks count=\(audioAIPendingChunksByEntryID.count)")
                audioAIPendingChunksByEntryID.removeAll(keepingCapacity: false)
            }
            return
        }
        audioAIPendingChunksByEntryID = audioAIPendingChunksByEntryID.filter { $0.key == activeEntry }
    }

    private func trimOpencodeNativeState(reason: String) {
        guard let activeEntry = opencodeCurrentStreamingEntryID else {
            if !opencodePendingStreamingChunksByEntryID.isEmpty {
                DevLog.log("Opencode", "memory maintenance reason=\(reason) clearing stale opencode chunks count=\(opencodePendingStreamingChunksByEntryID.count)")
                opencodePendingStreamingChunksByEntryID.removeAll(keepingCapacity: false)
            }
            return
        }
        opencodePendingStreamingChunksByEntryID = opencodePendingStreamingChunksByEntryID.filter { $0.key == activeEntry }
    }

    private func trimFileExploreNativeState(reason: String) {
        guard fileExploreIconCache.count > RetentionPolicy.fileExploreIconCacheLimit else { return }
        DevLog.log("FileExplore", "memory maintenance reason=\(reason) clearing icon cache count=\(fileExploreIconCache.count)")
        fileExploreIconCache.removeAll(keepingCapacity: true)
    }

    // MARK: – Public

    func updateStatus(filename: String, count: Int) {
        DispatchQueue.main.async { [weak self] in
            DevLog.log("VisualUI", "saved status count=\(count) file=\(filename)")
            self?.countLabel.stringValue = "saved \(count)"
        }
    }

    // MARK: – Public — AI results

    func markProcessingStarted(imageURL: URL, retryIndex: Int = 0, maxRetries: Int = 3) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if entryIdByImageURL[imageURL] != nil {
                DevLog.log("VisualUI", "markProcessingStarted duplicate file=\(imageURL.lastPathComponent) retry=\(retryIndex)/\(maxRetries)")
                updateVisualStatus("Retry \(retryIndex) of \(maxRetries)", imageURL: imageURL)
                return
            }
            pendingCount += 1
            let entryId = nextStreamingEntryId
            nextStreamingEntryId += 1
            entryIdByImageURL[imageURL] = entryId
            DevLog.log(
                "VisualUI",
                "markProcessingStarted entry=\(entryId) file=\(imageURL.lastPathComponent) retry=\(retryIndex)/\(maxRetries) aiPageReady=\(aiPageReady ? 1 : 0) pendingCount=\(pendingCount)"
            )
            startStreamingEntry(imageURL: imageURL, entryId: entryId, retryIndex: retryIndex, maxRetries: maxRetries)
        }
    }

    func updateVisualStatus(_ status: String, imageURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let entryId = entryIdByImageURL[imageURL] else {
                DevLog.log("VisualUI", "status dropped missing entry file=\(imageURL.lastPathComponent) status=\(status)")
                return
            }
            guard let js = jsLiteral(status) else {
                DevLog.log("VisualUI", "status dropped jsLiteral failed entry=\(entryId) statusLength=\(status.count)")
                return
            }
            DevLog.log("VisualUI", "status entry=\(entryId) file=\(imageURL.lastPathComponent) status=\(status)")
            enqueueVisualJavaScript("setStreamingEntryStatus(\(entryId), \(js))", immediate: true)
        }
    }

    func replaceStreamingContent(_ markdown: String, imageURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let entryId = entryIdByImageURL[imageURL] else {
                DevLog.log("VisualUI", "replace dropped missing entry file=\(imageURL.lastPathComponent) chars=\(markdown.count)")
                return
            }
            guard let js = jsLiteral(markdown) else {
                DevLog.log("VisualUI", "replace dropped jsLiteral failed entry=\(entryId) chars=\(markdown.count)")
                return
            }
            DevLog.log("VisualUI", "replace entry=\(entryId) file=\(imageURL.lastPathComponent) chars=\(markdown.count)")
            visualPendingChunksByEntryID.removeValue(forKey: entryId)
            enqueueVisualJavaScript("replaceStreamingEntryContent(\(entryId), \(js))", immediate: true)
        }
    }

    func appendStreamingChunk(_ chunk: String, imageURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let entryId = entryIdByImageURL[imageURL] else {
                DevLog.log("VisualUI", "chunk dropped missing entry file=\(imageURL.lastPathComponent) chars=\(chunk.count)")
                return
            }
            DevLog.log("VisualUI", "chunk queued entry=\(entryId) file=\(imageURL.lastPathComponent) chars=\(chunk.count)")
            visualPendingChunksByEntryID[entryId, default: ""] += chunk
            scheduleVisualChunkFlush()
        }
    }

    func endStreamingWithResult(fullMarkdown: String, imageURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingCount = max(0, pendingCount - 1)
            guard let entryId = entryIdByImageURL.removeValue(forKey: imageURL) else {
                DevLog.log("VisualUI", "result dropped missing entry file=\(imageURL.lastPathComponent) chars=\(fullMarkdown.count) pendingCount=\(pendingCount)")
                return
            }
            DevLog.log("VisualUI", "result entry=\(entryId) file=\(imageURL.lastPathComponent) chars=\(fullMarkdown.count) pendingCount=\(pendingCount)")
            flushVisualStreamingChunks(for: entryId)
            guard let js = jsLiteral(fullMarkdown) else {
                DevLog.log("VisualUI", "result dropped jsLiteral failed entry=\(entryId) chars=\(fullMarkdown.count)")
                return
            }
            enqueueVisualJavaScript("endStreamingEntry(\(entryId), \(js))", immediate: true)
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
                DevLog.log("VisualUI", "error entry=\(entryId) file=\(imageURL.lastPathComponent) message=\(message)")
                flushVisualStreamingChunks(for: entryId)
                enqueueVisualJavaScript("endStreamingEntryAsError(\(entryId), \(js))", immediate: true)
                return
            }
            DevLog.log("VisualUI", "error standalone image=\(imageURL?.lastPathComponent ?? "nil") message=\(message)")
            let header = "[\(Self.timeString())]  Error"
            appendEntry(header: header, body: message, isError: true)
        }
    }

    func discardStreamingEntry(imageURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let entryId = entryIdByImageURL.removeValue(forKey: imageURL) else {
                DevLog.log("VisualUI", "discard dropped missing entry file=\(imageURL.lastPathComponent)")
                return
            }
            pendingCount = max(0, pendingCount - 1)
            DevLog.log("VisualUI", "discard entry=\(entryId) file=\(imageURL.lastPathComponent) pendingCount=\(pendingCount)")
            visualPendingChunksByEntryID.removeValue(forKey: entryId)
            enqueueVisualJavaScript("removeStreamingEntry(\(entryId))", immediate: true)
        }
    }

    // MARK: – Public — Transcript feed

    /// Appends each server message permanently (no partial vs final distinction).
    func appendTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let ts = audioTextView.textStorage else { return }
            let started = CapturePerf.begin()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
            ts.append(NSAttributedString(string: text + "\n", attributes: attrs))
            if ts.length > transcriptDisplayCharLimit * 2 {
                let target = transcriptDisplayCharLimit
                let removeCount = max(0, ts.length - target)
                if removeCount > 0 {
                    ts.deleteCharacters(in: NSRange(location: 0, length: removeCount))
                }
            }
            transcriptBuffer += text + "\n"
            pendingTranscriptCharsSinceLastSend += text.count + 1
            let cap = audioAITokenLimit * 4
            if transcriptBuffer.count > cap * 2 {
                transcriptBuffer = String(transcriptBuffer.suffix(cap))
            }
            if activeContentTab == ContentTab.transcript.rawValue {
                scrollAudioToBottom()
            }
            CapturePerf.end(started, "transcript.append", details: "chars=\(text.count)")
        }
    }

    // MARK: – Public — Audio AI feed

    /// Streams a chunk of Gemini's response into the Audio AI WebView.
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
                    audioAIBridge.enqueue("startStreamingEntry(\(hJS), null, \(entryId))")
                }
            }
            guard let entryId = audioAICurrentEntry else { return }
            audioAIStreamingText += text
            audioAIPendingChunksByEntryID[entryId, default: ""] += text
            scheduleAudioAIChunkFlush()
        }
    }

    /// Finalizes the current Audio AI streaming entry, rendering full markdown.
    func finalizeAudioAI() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let entryId = audioAICurrentEntry,
                  let mdJS = jsLiteral(audioAIStreamingText) else { return }
            flushAudioAIStreamingChunks(for: entryId)
            audioAIBridge.enqueue("endStreamingEntry(\(entryId), \(mdJS))", immediate: true)
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
                flushAudioAIStreamingChunks(for: entryId)
                audioAIBridge.enqueue("endStreamingEntry(\(entryId), \(mdJS))")
                audioAICurrentEntry = nil; audioAIStreamingText = ""
            }
            let entryId = audioAINextEntryId; audioAINextEntryId += 1
            let header = "[\(Self.timeString())]"
            if let hJS = jsLiteral(header) {
                audioAIBridge.enqueue("startStreamingEntry(\(hJS), null, \(entryId))")
            }
            if let errJS = jsLiteral("⚠ \(message)") {
                audioAIBridge.enqueue("endStreamingEntry(\(entryId), \(errJS))", immediate: true)
            }
        }
    }

    @objc private func audioAIZoomIn()  { audioAIBridge.enqueue("adjustZoom(1)", immediate: true) }
    @objc private func audioAIZoomOut() { audioAIBridge.enqueue("adjustZoom(-1)", immediate: true) }

    @objc private func askAITapped() { triggerAudioAI(force: true) }

    private func triggerAudioAI(force: Bool = false) {
        let full    = transcriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return }
        // Trim to the configured token limit before sending
        let current = String(full.suffix(audioAITokenLimit * 4))
        guard force || current != lastSentTranscript else { return }

        // Skip auto-send if fewer than 3% of transcript chars were appended since the last request.
        let base = max(lastSentTranscript.count, 1)
        let growthRatio = Double(pendingTranscriptCharsSinceLastSend) / Double(base)
        guard force || lastSentTranscript.isEmpty || growthRatio >= 0.03 else { return }

        guard onAudioAIRequest?(current) == true else { return }
        CapturePerf.log("audioAI.request sent chars=\(current.count) growthRatio=\(String(format: "%.3f", growthRatio)) force=\(force ? 1 : 0)")
        lastSentTranscript = current
        pendingTranscriptCharsSinceLastSend = 0
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
            if activeContentTab == ContentTab.transcript.rawValue {
                scrollAudioToBottom()
            }
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
        closeCurrentSession()
        onStop?()
    }

    private func buildAIPane() -> NSView {
        // ── WebView (Visual tab) ─────────────────────────────────
        let config = WKWebViewConfiguration()
        let handler = CopyCodeHandler(pageReady: { [weak self] in
            DispatchQueue.main.async {
                DevLog.log("VisualUI", "pageReady message received")
                self?.markVisualPageReady(reason: "pageReady")
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
        visualBridge.attach(webView: wv)

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
                self?.audioAIBridge.enqueue("setMaxRenderedEntries(\(RetentionPolicy.audioAIRenderedEntryLimit))", immediate: true)
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
        audioAIBridge.attach(webView: aiWV)

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
        initialPromptTextView.string = UserDefaults.standard.string(forKey: opencodeInitialPromptDefaultsKey) ?? ""
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

        let opencodeChatCfg = WKWebViewConfiguration()
        let opencodeChatHandler = CopyCodeHandler(pageReady: { [weak self] in
            DispatchQueue.main.async {
                self?.opencodeChatPageReady = true
                self?.opencodeBridge.enqueue("setMaxRenderedEntries(\(RetentionPolicy.opencodeRenderedEntryLimit))", immediate: true)
                self?.flushOpencodePendingChatEntries()
                self?.flushOpencodePendingChatScripts()
            }
        })
        opencodeChatCfg.userContentController.add(opencodeChatHandler, name: "copyCode")
        opencodeChatCfg.userContentController.add(opencodeChatHandler, name: "pageReady")

        let opencodeChatView = WKWebView(frame: .zero, configuration: opencodeChatCfg)
        opencodeChatView.translatesAutoresizingMaskIntoConstraints = false
        opencodeChatView.wantsLayer = true
        opencodeChatView.layer?.backgroundColor = NSColor.clear.cgColor
        opencodeChatWebView = opencodeChatView
        opencodeBridge.attach(webView: opencodeChatView)

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
         opencodeChatView, sendField, sendBtn]
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
        fileExploreBridge.attach(webView: filePreviewWebView)

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
        let vr = barBtn("Retry", action: #selector(retryAI))
        vr.font = .systemFont(ofSize: 11);                visualRetryBtn = vr
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

        [zo, zi, vr, vc, ac, azo, azi, aac, askBtn].forEach { innerBar.addSubview($0) }

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
            zi.trailingAnchor.constraint(equalTo: vr.leadingAnchor, constant: -10),
            zi.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),
            vr.trailingAnchor.constraint(equalTo: vc.leadingAnchor, constant: -6),
            vr.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),
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

            opencodeChatView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            opencodeChatView.leadingAnchor.constraint(equalTo: opencodeView.leadingAnchor, constant: 16),
            opencodeChatView.trailingAnchor.constraint(equalTo: opencodeView.trailingAnchor, constant: -16),
            opencodeChatView.bottomAnchor.constraint(equalTo: sendField.topAnchor, constant: -10),
            opencodeChatView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

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
        opencodeChatWebView.loadHTMLString(Self.htmlTemplate, baseURL: baseURL)
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
        visualRetryBtn.isHidden   = !isVisual
        visualClearBtn.isHidden   = !isVisual
        audioClearBtn.isHidden    = !isTranscript
        audioAIZoomOutBtn.isHidden = !isAudioAI
        audioAIZoomInBtn.isHidden  = !isAudioAI
        audioAIClearBtn.isHidden   = !isAudioAI
        audioAIAskBtn.isHidden     = !isAudioAI

        if isFileExplore, let rootURL = fileExploreCurrentRootURL {
            if fileExploreRootNode?.url != rootURL {
                rebuildFileExploreRoot(at: rootURL, preserveState: true)
            } else {
                scheduleFileExploreDebouncedRefresh(reason: "tab-switch")
            }
        }
        if isTranscript {
            scrollAudioToBottom()
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
        let segment = ensureFileExploreTabVisible()
        contentTabControl.selectedSegment = segment
        contentTabChanged()
    }

    private func rebuildFileExploreRoot(at rootURL: URL, preserveState: Bool) {
        let started = CapturePerf.begin()
        fileExploreCurrentRootURL = rootURL.standardizedFileURL
        let expandedURLs = preserveState ? expandedFileExploreDirectoryURLs() : []
        let previouslySelected = preserveState ? fileExploreSelectedFileURL : nil

        let root = FileExploreNode(url: rootURL, isDirectory: true)
        fileExploreRootNode = root
        fileExploreNodeByPath.removeAll(keepingCapacity: false)
        fileExploreNodeByPath[rootURL.path] = root
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
        CapturePerf.end(started, "fileExplore.rebuildRoot", details: "preserve=\(preserveState ? 1 : 0)")
    }

    private func loadFileExploreChildrenIfNeeded(for node: FileExploreNode) {
        guard node.isDirectory, !node.isLoaded else { return }
        refreshFileExploreDirectory(node, reloadIfNeeded: true)
    }

    private func previewFileExploreFile(at fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL
        fileExploreSelectedFileURL = standardizedURL
        fileExplorePreviewToken += 1
        let token = fileExplorePreviewToken
        let kind = fileExploreContentKind(for: standardizedURL)
        let started = CapturePerf.begin()

        fileExplorePreviewQueue.async { [weak self] in
            guard let self else { return }
            let result = self.buildFileExplorePreview(for: standardizedURL, kind: kind)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard token == fileExplorePreviewToken else { return }
                guard fileExploreSelectedFileURL == standardizedURL else { return }

                switch result {
                case .success(let payload):
                    fileExploreSelectedFingerprint = payload.fingerprint
                    renderFileExploreDocument(kind: payload.kind, content: payload.content)
                case .failure(let error):
                    fileExploreSelectedFingerprint = nil
                    renderFileExploreDocument(kind: "text", content: error.localizedDescription)
                }
                updateFileExploreRealtimeRefreshState()
                CapturePerf.end(started, "fileExplore.preview", details: "kind=\(kind)")
            }
        }
    }

    private func fileExploreContentKind(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "ipynb" {
            return "jupyter"
        }
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

    private func parseJupyterNotebookForPreview(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cells = root["cells"] as? [[String: Any]]
        else {
            return nil
        }

        let metadata = root["metadata"] as? [String: Any]
        let defaultLanguage = detectNotebookLanguage(from: metadata) ?? "python"
        var sections: [String] = []

        for (index, cell) in cells.enumerated() {
            let cellType = ((cell["cell_type"] as? String) ?? "raw").lowercased()
            sections.append("### Cell \(index + 1) - \(cellType)")
            sections.append("")

            switch cellType {
            case "markdown":
                let markdown = notebookJoinedText(from: cell["source"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(markdown.isEmpty ? "_(empty markdown cell)_" : markdown)
            case "code":
                let code = notebookJoinedText(from: cell["source"])
                let language = detectNotebookCodeLanguage(for: cell, fallback: defaultLanguage)
                sections.append("```\(language)")
                sections.append(code)
                sections.append("```")

                let outputMarkdown = notebookOutputMarkdown(from: cell["outputs"])
                if !outputMarkdown.isEmpty {
                    sections.append("")
                    sections.append("**Output**")
                    sections.append("")
                    sections.append(outputMarkdown)
                }
            default:
                let raw = notebookJoinedText(from: cell["source"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(raw.isEmpty ? "_(empty raw cell)_" : "```text\n\(raw)\n```")
            }

            if index < cells.count - 1 {
                sections.append("")
                sections.append("---")
                sections.append("")
            }
        }

        if sections.isEmpty {
            return "Notebook has no cells."
        }

        var header: [String] = ["# Jupyter Notebook"]
        if let language = detectNotebookLanguage(from: metadata), !language.isEmpty {
            header.append("_Default language: `\(language)`_")
        }
        header.append("")
        return header.joined(separator: "\n") + sections.joined(separator: "\n")
    }

    private func detectNotebookLanguage(from metadata: [String: Any]?) -> String? {
        guard let metadata else { return nil }
        if
            let kernelspec = metadata["kernelspec"] as? [String: Any],
            let language = kernelspec["language"] as? String,
            !language.isEmpty
        {
            return language
        }
        if
            let languageInfo = metadata["language_info"] as? [String: Any],
            let language = languageInfo["name"] as? String,
            !language.isEmpty
        {
            return language
        }
        return nil
    }

    private func detectNotebookCodeLanguage(for cell: [String: Any], fallback: String) -> String {
        guard let metadata = cell["metadata"] as? [String: Any] else { return fallback }
        if
            let vscode = metadata["vscode"] as? [String: Any],
            let languageID = vscode["languageId"] as? String,
            !languageID.isEmpty
        {
            return languageID
        }
        if let language = metadata["language"] as? String, !language.isEmpty {
            return language
        }
        return fallback
    }

    private func notebookJoinedText(from value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        if let lines = value as? [String] {
            return lines.joined()
        }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }.joined()
        }
        return ""
    }

    private func notebookOutputMarkdown(from value: Any?) -> String {
        guard let outputs = value as? [[String: Any]], !outputs.isEmpty else { return "" }
        var rendered: [String] = []

        for output in outputs {
            if let data = output["data"] as? [String: Any] {
                let markdown = truncatedNotebookText(notebookJoinedText(from: data["text/markdown"]))
                if !markdown.isEmpty {
                    rendered.append(markdown)
                    continue
                }
            }

            var plain = ""
            if let traceback = output["traceback"] as? [String], !traceback.isEmpty {
                plain = traceback.joined(separator: "\n")
            } else if let errorName = output["ename"] as? String, let errorValue = output["evalue"] as? String {
                plain = "\(errorName): \(errorValue)"
            } else if let text = output["text"] {
                plain = notebookJoinedText(from: text)
            } else if let data = output["data"] as? [String: Any] {
                plain = notebookJoinedText(from: data["text/plain"])
                if plain.isEmpty {
                    plain = notebookJoinedText(from: data["application/json"])
                }
            }

            plain = truncatedNotebookText(plain)
            if !plain.isEmpty {
                rendered.append("```text\n\(plain)\n```")
            }
        }

        return rendered.joined(separator: "\n\n")
    }

    private func truncatedNotebookText(_ text: String, limit: Int = 6000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<end]) + "\n...(truncated)..."
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
        fileExploreBridge.enqueue("renderDocument(\(kindJS), \(contentJS))", immediate: true)
    }

    private func flushFileExplorePendingRender() {
        guard fileExplorePreviewReady, let pending = fileExplorePendingRender else { return }
        fileExplorePendingRender = nil
        guard let kindJS = jsLiteral(pending.kind), let contentJS = jsLiteral(pending.content) else { return }
        fileExploreBridge.enqueue("renderDocument(\(kindJS), \(contentJS))", immediate: true)
    }

    @objc private func fileExploreZoomIn() {
        fileExploreBridge.enqueue("adjustZoom(1)", immediate: true)
    }

    @objc private func fileExploreZoomOut() {
        fileExploreBridge.enqueue("adjustZoom(-1)", immediate: true)
    }

    private func startFileExploreRealtimeRefresh() {
        stopFileExploreRealtimeRefresh()
        guard let rootURL = fileExploreCurrentRootURL else { return }

        fileExploreWatcherActive = fileExploreWatcher.start(url: rootURL) { [weak self] in
            self?.scheduleFileExploreDebouncedRefresh(reason: "watcher")
        }

        // Fallback refresh timer remains enabled as a safety net.
        let interval = fileExploreWatcherActive ? 4.0 : 1.2
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshFileExploreIfNeeded(reason: "timer")
        }
        timer.tolerance = min(0.8, interval * 0.25)
        RunLoop.main.add(timer, forMode: .common)
        fileExploreRealtimeRefreshTimer = timer
        scheduleFileExploreDebouncedRefresh(reason: "start")
    }

    private func stopFileExploreRealtimeRefresh() {
        fileExploreRealtimeRefreshTimer?.invalidate()
        fileExploreRealtimeRefreshTimer = nil
        fileExploreWatcher.stop()
        fileExploreWatcherActive = false
        fileExploreChangeDebounceWorkItem?.cancel()
        fileExploreChangeDebounceWorkItem = nil
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

    private func refreshFileExploreIfNeeded(reason: String = "manual") {
        guard let rootURL = fileExploreCurrentRootURL else {
            stopFileExploreRealtimeRefresh()
            return
        }
        let started = CapturePerf.begin()
        refreshVisibleFileExploreDirectories(rootURL: rootURL)

        guard let selectedURL = fileExploreSelectedFileURL else {
            CapturePerf.end(started, "fileExplore.refresh", details: "reason=\(reason),selected=0")
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: selectedURL.path) else {
            fileExploreSelectedFileURL = nil
            fileExploreSelectedFingerprint = nil
            renderFileExploreDocument(kind: "text", content: "Selected file was removed.")
            CapturePerf.end(started, "fileExplore.refresh", details: "reason=\(reason),removed=1")
            return
        }

        let newFingerprint = fileExploreFingerprint(for: selectedURL)
        guard newFingerprint != fileExploreSelectedFingerprint else {
            CapturePerf.end(started, "fileExplore.refresh", details: "reason=\(reason),changed=0")
            return
        }
        previewFileExploreFile(at: selectedURL)
        CapturePerf.end(started, "fileExplore.refresh", details: "reason=\(reason)")
    }

    private func scheduleFileExploreDebouncedRefresh(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            fileExploreChangeDebounceWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.refreshFileExploreIfNeeded(reason: reason)
            }
            fileExploreChangeDebounceWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
        }
    }

    private func refreshVisibleFileExploreDirectories(rootURL: URL) {
        guard let root = fileExploreRootNode else { return }
        refreshFileExploreDirectory(root, reloadIfNeeded: true)

        let expanded = expandedFileExploreDirectoryURLs()
        let sorted = expanded.sorted { $0.pathComponents.count < $1.pathComponents.count }
        for url in sorted where url != rootURL {
            guard let node = fileExploreNodeByPath[url.path] else { continue }
            refreshFileExploreDirectory(node, reloadIfNeeded: true)
        }
    }

    private func fileExploreFingerprint(for fileURL: URL) -> String? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let values = try? fileURL.resourceValues(forKeys: keys) else { return nil }
        let modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        return "\(modifiedAt)-\(size)"
    }

    private func refreshFileExploreDirectory(_ node: FileExploreNode, reloadIfNeeded: Bool) {
        guard node.isDirectory else { return }
        let started = CapturePerf.begin()
        let keys: Set<URLResourceKey> = [.isDirectoryKey]

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: node.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            )
        } catch {
            for child in node.children {
                removeFileExploreNodeSubtreeFromIndex(child)
            }
            node.children = []
            node.isLoaded = true
            CapturePerf.end(started, "fileExplore.refreshDirectory", details: "error=\(error.localizedDescription)")
            return
        }

        var existingByPath: [String: FileExploreNode] = [:]
        for child in node.children {
            existingByPath[child.url.path] = child
        }

        var nextChildren: [FileExploreNode] = []
        nextChildren.reserveCapacity(urls.count)
        var changed = false

        for childURL in urls {
            let stdURL = childURL.standardizedFileURL
            let isDir = (try? stdURL.resourceValues(forKeys: keys).isDirectory) ?? false
            if let existing = existingByPath.removeValue(forKey: stdURL.path), existing.isDirectory == isDir {
                nextChildren.append(existing)
                continue
            }

            let child = FileExploreNode(url: stdURL, isDirectory: isDir)
            child.parent = node
            nextChildren.append(child)
            fileExploreNodeByPath[stdURL.path] = child
            changed = true
        }

        if !existingByPath.isEmpty {
            changed = true
            for removed in existingByPath.values {
                removeFileExploreNodeSubtreeFromIndex(removed)
            }
        }

        nextChildren.sort {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
        }

        if !changed {
            let oldPaths = node.children.map { $0.url.path }
            let newPaths = nextChildren.map { $0.url.path }
            changed = oldPaths != newPaths
        }

        node.children = nextChildren
        node.isLoaded = true

        guard changed, reloadIfNeeded, let outlineView = fileExploreOutlineView else {
            CapturePerf.end(started, "fileExplore.refreshDirectory", details: "changed=\(changed ? 1 : 0)")
            return
        }
        if node.parent == nil {
            outlineView.reloadData()
        } else {
            outlineView.reloadItem(node, reloadChildren: true)
        }
        CapturePerf.end(started, "fileExplore.refreshDirectory", details: "changed=1")
    }

    private func removeFileExploreNodeSubtreeFromIndex(_ node: FileExploreNode) {
        fileExploreNodeByPath.removeValue(forKey: node.url.path)
        for child in node.children {
            removeFileExploreNodeSubtreeFromIndex(child)
        }
    }

    private struct FileExplorePreviewPayload {
        let kind: String
        let content: String
        let fingerprint: String?
    }

    private struct FileExplorePreviewFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func buildFileExplorePreview(for fileURL: URL, kind: String) -> Result<FileExplorePreviewPayload, Error> {
        do {
            let (data, truncated) = try readFileExplorePreviewData(at: fileURL, limit: fileExplorePreviewMaxBytes)
            if isLikelyBinaryFileData(data) {
                return .failure(FileExplorePreviewFailure(message: "Cannot preview binary file: \(fileURL.lastPathComponent)"))
            }

            if kind == "jupyter" {
                if truncated {
                    return .failure(FileExplorePreviewFailure(
                        message: "Notebook is too large for live preview. Open a smaller notebook or reduce file size."))
                }
                guard let notebookMarkdown = parseJupyterNotebookForPreview(from: data) else {
                    return .failure(FileExplorePreviewFailure(
                        message: "Unable to parse notebook JSON: \(fileURL.lastPathComponent)"))
                }
                return .success(FileExplorePreviewPayload(
                    kind: "jupyter",
                    content: notebookMarkdown,
                    fingerprint: fileExploreFingerprint(for: fileURL)
                ))
            }

            guard var text = parseFileExploreText(from: data) else {
                return .failure(FileExplorePreviewFailure(
                    message: "Unable to decode file as UTF-8 text: \(fileURL.lastPathComponent)"))
            }
            if truncated {
                text += "\n\n...(preview truncated at \(fileExplorePreviewMaxBytes) bytes)..."
            }

            return .success(FileExplorePreviewPayload(
                kind: kind,
                content: text,
                fingerprint: fileExploreFingerprint(for: fileURL)
            ))
        } catch {
            return .failure(FileExplorePreviewFailure(message: "Failed to read file: \(error.localizedDescription)"))
        }
    }

    private func readFileExplorePreviewData(at fileURL: URL, limit: Int) throws -> (Data, Bool) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let maxRead = max(1, limit + 1)
        let data = try handle.read(upToCount: maxRead) ?? Data()
        if data.count > limit {
            return (data.prefix(limit), true)
        }
        return (data, false)
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
        let standardized = url.standardizedFileURL
        if let node = fileExploreNodeByPath[standardized.path] {
            return node
        }
        guard let root = fileExploreRootNode else { return nil }
        if standardized == root.url {
            return root
        }
        let rootPath = root.url.path
        let targetPath = standardized.path
        guard targetPath.hasPrefix(rootPath + "/") else { return nil }

        var current = root
        let relativePath = String(targetPath.dropFirst(rootPath.count + 1))
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
        let initialPromptRaw = opencodeInitialPromptTextView.string
        let initialPrompt = initialPromptRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(initialPromptRaw, forKey: opencodeInitialPromptDefaultsKey)
        guard !sourceDir.isEmpty, !workingDir.isEmpty else {
            setOpencodeStatus("Please enter both source dir and working dir.", isError: true)
            return
        }

        stopActiveOpencodeProcess(resetSession: true, closeRemoteSession: true)
        let startToken = opencodeCommandToken
        setOpencodeStatus("Preparing input directory…", isError: false)

        runOpencodeStart(
            sourceDirInput: sourceDir,
            workingDirInput: workingDir,
            initialPrompt: initialPrompt,
            allowPermissionPrompt: true,
            token: startToken
        )
    }

    private func runOpencodeStart(
        sourceDirInput: String,
        workingDirInput: String,
        initialPrompt: String,
        allowPermissionPrompt: Bool,
        token: Int
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

            // Show File Explore immediately so startup feels responsive even while input sync runs.
            activateFileExploreTab(with: workingURL)

            let isDir = sourceIsDir.boolValue
            let prepStart = CapturePerf.begin()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let copiedCount = try self.prepareInputDirectory(from: sourceURL, isDirectory: isDir, in: workingURL)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard token == opencodeCommandToken else { return }
                        NSLog("Opencode start complete. sourceDir=%@ workingDir=%@ initialPrompt=%@ inputDir=%@",
                              sourceDir, workingDir, initialPrompt, inputURL.path)
                        CapturePerf.end(prepStart, "opencode.prepareInputDirectory", details: "items=\(copiedCount)")
                        setOpencodeStatus("Prepared \(inputURL.path) · Copied \(copiedCount) item(s). Starting session…", isError: false)
                        startNewOpencodeSession(workingURL: workingURL, initialPrompt: initialPrompt)
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard token == opencodeCommandToken else { return }
                        if allowPermissionPrompt, isPermissionError(error),
                           shouldPromptForExplicitFolderAccess(sourceURL: sourceURL, workingURL: workingURL) {
                            let granted = requestOpencodeFolderAccess(sourceURL: sourceURL, workingURL: workingURL)
                            if granted {
                                runOpencodeStart(
                                    sourceDirInput: sourceDirInput,
                                    workingDirInput: workingDirInput,
                                    initialPrompt: initialPrompt,
                                    allowPermissionPrompt: false,
                                    token: token
                                )
                                return
                            }
                            setOpencodeStatus("Folder permission was not granted.", isError: true)
                            return
                        }
                        setOpencodeStatus("Start failed: \(error.localizedDescription)", isError: true)
                    }
                }
            }
        } catch {
            guard token == opencodeCommandToken else { return }
            if allowPermissionPrompt, isPermissionError(error),
               shouldPromptForExplicitFolderAccess(sourceURL: sourceURL, workingURL: workingURL) {
                let granted = requestOpencodeFolderAccess(sourceURL: sourceURL, workingURL: workingURL)
                if granted {
                    runOpencodeStart(
                        sourceDirInput: sourceDirInput,
                        workingDirInput: workingDirInput,
                        initialPrompt: initialPrompt,
                        allowPermissionPrompt: false,
                        token: token
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

        if isDirectory {
            if !fm.fileExists(atPath: inputDir.path) {
                try fm.createDirectory(at: inputDir, withIntermediateDirectories: true)
            }

            if let changed = try syncInputDirectoryIncremental(source: source, inputDir: inputDir, workingDir: workingDir) {
                return changed
            }

            // Fallback path when rsync is unavailable/fails.
            if fm.fileExists(atPath: inputDir.path) {
                try fm.removeItem(at: inputDir)
            }
            try fm.createDirectory(at: inputDir, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            var copiedCount = 0
            for item in items {
                // Avoid recursively copying input/ into itself when source == workingDir.
                if item.standardizedFileURL == inputDir { continue }
                let destination = inputDir.appendingPathComponent(item.lastPathComponent, isDirectory: false)
                try fm.copyItem(at: item, to: destination)
                copiedCount += 1
            }
            return copiedCount
        } else {
            if fm.fileExists(atPath: inputDir.path) {
                try fm.removeItem(at: inputDir)
            }
            try fm.createDirectory(at: inputDir, withIntermediateDirectories: true)
            let destination = inputDir.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            try fm.copyItem(at: source, to: destination)
            return 1
        }
    }

    private func syncInputDirectoryIncremental(source: URL, inputDir: URL, workingDir: URL) throws -> Int? {
        let rsyncPath = "/usr/bin/rsync"
        guard FileManager.default.isReadableFile(atPath: rsyncPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsyncPath)

        var args = ["-a", "--delete", "--itemize-changes"]
        if source.standardizedFileURL == workingDir.standardizedFileURL {
            args.append(contentsOf: ["--exclude", "input/"])
        }
        args.append(source.path.hasSuffix("/") ? source.path : source.path + "/")
        args.append(inputDir.path.hasSuffix("/") ? inputDir.path : inputDir.path + "/")
        process.arguments = args

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            CapturePerf.log("opencode.rsync unavailable, falling back to full copy: \(error.localizedDescription)")
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let snippet = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = snippet.isEmpty ? "Unknown rsync error." : String(snippet.prefix(300))
            throw makeOpencodeError("Failed to sync input directory: \(msg)")
        }

        let changedCount = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        return changedCount
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
            guard token == self.opencodeCommandToken else {
                if case .success(let newSessionID) = result {
                    self.closeOpencodeSession(sessionID: newSessionID, workingURL: workingURL)
                }
                return
            }
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
        scheduleOpencodeStreamTimeout(token: token)

        postOpencodePromptAsync(message, sessionID: sessionID, workingURL: workingURL) { [weak self] result in
            guard let self else { return }
            guard token == self.opencodeCommandToken else { return }
            if case .failure(let error) = result {
                self.finishOpencodeStreaming(withError: error.localizedDescription)
            }
        }
    }

    private func handleOpencodeStreamEvent(_ event: [String: Any], sessionID: String, isInitialStart: Bool) {
        opencodePerfEventCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - opencodePerfLastLogAt >= 5 {
            CapturePerf.log("opencode.events per 5s = \(opencodePerfEventCount)")
            opencodePerfEventCount = 0
            opencodePerfLastLogAt = now
        }
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
        if opencodeStreamingAssistantMessageID != messageID {
            opencodeStreamingAssistantMessageID = messageID
            opencodeStreamingAssistantText = ""
            opencodeToolStatusByPartID.removeAll(keepingCapacity: true)
        }
        if let existingEntryID = opencodeStreamingEntryIDByMessageID[messageID] {
            opencodeCurrentStreamingEntryID = existingEntryID
            return
        }
        let entryID = opencodeNextStreamingEntryID
        opencodeNextStreamingEntryID += 1
        opencodeStreamingEntryIDByMessageID[messageID] = entryID
        opencodeCurrentStreamingEntryID = entryID
        startOpencodeStreamingEntry(entryID: entryID, header: "Opencode")
    }

    private func appendStreamingAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        opencodeStreamingAssistantText += delta
        guard let entryID = opencodeCurrentStreamingEntryID else { return }
        appendOpencodeStreamingChunk(entryID: entryID, text: delta)
    }

    private func updateStreamingAssistantFullText(_ text: String) {
        guard let entryID = opencodeCurrentStreamingEntryID else { return }
        let normalized = stripANSI(text)
        if normalized.count < opencodeStreamingAssistantText.count, !opencodeStreamingAssistantText.isEmpty {
            return
        }
        if normalized.hasPrefix(opencodeStreamingAssistantText) {
            let delta = String(normalized.dropFirst(opencodeStreamingAssistantText.count))
            if !delta.isEmpty {
                appendOpencodeStreamingChunk(entryID: entryID, text: delta)
            }
            opencodeStreamingAssistantText = normalized
            return
        }
        if opencodeStreamingAssistantText.isEmpty {
            opencodeStreamingAssistantText = normalized
            if !normalized.isEmpty {
                appendOpencodeStreamingChunk(entryID: entryID, text: normalized)
            }
            return
        }
        opencodeStreamingAssistantText = normalized
        finalizeOpencodeStreamingEntry(entryID: entryID, markdown: cleanOpencodeAssistantText(normalized))
    }

    private func finishOpencodeStreamingSuccessfully(isInitialStart: Bool, sessionID: String) {
        cancelOpencodeStreamTimeout()
        stopOpencodeEventStream()
        setOpencodeBusy(false)
        if let entryID = opencodeCurrentStreamingEntryID {
            let finalMarkdown = cleanOpencodeAssistantText(opencodeStreamingAssistantText)
            if !finalMarkdown.isEmpty {
                finalizeOpencodeStreamingEntry(entryID: entryID, markdown: finalMarkdown)
            }
        }
        if isInitialStart {
            setOpencodeStatus("Session started: \(sessionID)", isError: false)
        } else {
            setOpencodeStatus("Message sent.", isError: false)
        }
        resetOpencodeStreamingState()
    }

    private func finishOpencodeStreaming(withError message: String) {
        cancelOpencodeStreamTimeout()
        stopOpencodeEventStream()
        setOpencodeBusy(false)
        setOpencodeStatus(message, isError: true)
        resetOpencodeStreamingState()
    }

    private func resetOpencodeStreamingState() {
        opencodeStreamingAssistantMessageID = nil
        opencodeStreamingAssistantText = ""
        opencodeStreamingEntryIDByMessageID.removeAll(keepingCapacity: false)
        opencodeCurrentStreamingEntryID = nil
        opencodeToolStatusByPartID.removeAll(keepingCapacity: false)
        opencodePendingStreamingChunksByEntryID.removeAll(keepingCapacity: false)
        opencodeChunkFlushWorkItem?.cancel()
        opencodeChunkFlushWorkItem = nil
    }

    private func stopOpencodeEventStream() {
        cancelOpencodeStreamTimeout()
        opencodeEventStreamClient?.stop()
        opencodeEventStreamClient = nil
    }

    private func scheduleOpencodeStreamTimeout(token: Int) {
        cancelOpencodeStreamTimeout()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard token == opencodeCommandToken else { return }
            finishOpencodeStreaming(withError: "Opencode response timed out. You can send a follow-up message to retry.")
        }
        opencodeStreamTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: item)
    }

    private func cancelOpencodeStreamTimeout() {
        opencodeStreamTimeoutWorkItem?.cancel()
        opencodeStreamTimeoutWorkItem = nil
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

    private func closeOpencodeSession(sessionID: String, workingURL: URL) {
        abortOpencodeSession(sessionID: sessionID, workingURL: workingURL) { [weak self] in
            self?.deleteOpencodeSession(sessionID: sessionID, workingURL: workingURL)
        }
    }

    private func abortOpencodeSession(
        sessionID: String,
        workingURL: URL,
        completion: @escaping () -> Void
    ) {
        guard let requestURL = opencodeRequestURL(
            path: "session/\(sessionID)/abort",
            workingURL: workingURL
        ) else {
            completion()
            return
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        performOpencodeRequest(request, completion: { (result: Result<Bool, Error>) in
            if case .failure(let error) = result {
                NSLog("Failed to abort opencode session %@: %@", sessionID, error.localizedDescription)
            }
            completion()
        }) { _ in
            true
        }
    }

    private func deleteOpencodeSession(sessionID: String, workingURL: URL) {
        guard let requestURL = opencodeRequestURL(
            path: "session/\(sessionID)",
            workingURL: workingURL
        ) else { return }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"

        performOpencodeRequest(request, completion: { (result: Result<Bool, Error>) in
            if case .failure(let error) = result {
                NSLog("Failed to delete opencode session %@: %@", sessionID, error.localizedDescription)
            }
        }) { _ in
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
                return
            }
            fail("Opencode stream ended unexpectedly before completion.")
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
        guard let regex = Self.ansiRegex else { return input }
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
                // Hide status/meta lines like: "> build · gemini-3.5-flash"
                return !trimmed.hasPrefix("> ")
            }
        return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendOpencodeLine(_ role: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard role == "You" || role == "Opencode" else { return }
        appendOpencodeChatEntry(header: role, markdown: trimmed, isError: false)
    }

    private func appendOpencodeChatEntry(header: String, markdown: String, isError: Bool) {
        opencodePendingChatEntries.append((header, markdown, isError))
        flushOpencodePendingChatEntries()
    }

    private func flushOpencodePendingChatEntries() {
        guard opencodeChatPageReady, !opencodePendingChatEntries.isEmpty else { return }
        for item in opencodePendingChatEntries {
            guard let hJS = jsLiteral(item.header), let bJS = jsLiteral(item.body) else { continue }
            let js = "appendEntry(\(hJS), \(bJS), \(item.isError ? "true" : "false"))"
            runOpencodeChatJavaScript(js)
        }
        opencodePendingChatEntries.removeAll()
        flushOpencodePendingChatScripts()
    }

    private func startOpencodeStreamingEntry(entryID: Int, header: String) {
        guard let hJS = jsLiteral(header) else { return }
        let js = "startStreamingEntry(\(hJS), null, \(entryID))"
        runOpencodeChatJavaScript(js)
    }

    private func appendOpencodeStreamingChunk(entryID: Int, text: String) {
        guard !text.isEmpty else { return }
        opencodePendingStreamingChunksByEntryID[entryID, default: ""] += text
        scheduleOpencodeChunkFlush()
    }

    private func finalizeOpencodeStreamingEntry(entryID: Int, markdown: String) {
        flushOpencodeStreamingChunks(for: entryID)
        guard let mdJS = jsLiteral(markdown) else { return }
        let js = "endStreamingEntry(\(entryID), \(mdJS))"
        runOpencodeChatJavaScript(js)
    }

    private func runOpencodeChatJavaScript(_ js: String) {
        guard opencodeChatPageReady else {
            opencodePendingChatScripts.append(js)
            return
        }
        opencodeBridge.enqueue(js)
    }

    private func flushOpencodePendingChatScripts() {
        guard opencodeChatPageReady, !opencodePendingChatScripts.isEmpty else { return }
        let scripts = opencodePendingChatScripts
        opencodePendingChatScripts.removeAll()
        for js in scripts { opencodeBridge.enqueue(js) }
        opencodeBridge.flushNow()
    }

    private func setOpencodeBusy(_ busy: Bool) {
        opencodeIsBusy = busy
        updateOpencodeControls()
    }

    private func stopActiveOpencodeProcess(resetSession: Bool, closeRemoteSession: Bool = false) {
        let sessionToClose = closeRemoteSession ? opencodeActiveSessionID : nil
        let workingURLToClose = closeRemoteSession ? opencodeActiveWorkingURL : nil
        opencodeCommandToken += 1
        stopOpencodeEventStream()
        resetOpencodeStreamingState()
        opencodeIsBusy = false
        if resetSession {
            opencodeActiveSessionID = nil
            opencodeActiveWorkingURL = nil
        }
        updateOpencodeControls()

        if let sessionID = sessionToClose, let workingURL = workingURLToClose {
            closeOpencodeSession(sessionID: sessionID, workingURL: workingURL)
        }
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
        pendingTranscriptCharsSinceLastSend = 0
    }

    @objc private func clearAudioAI() {
        audioAIBridge.enqueue("clearFeed()", immediate: true)
        audioAIPendingChunksByEntryID.removeAll(keepingCapacity: false)
        audioAIChunkFlushWorkItem?.cancel()
        audioAIChunkFlushWorkItem = nil
        audioAICurrentEntry = nil
        audioAIStreamingText = ""
    }

    // MARK: – AI helpers

    private func startStreamingEntry(imageURL: URL, entryId: Int, retryIndex: Int, maxRetries: Int) {
        let retryText = retryIndex == 0 ? "Attempt 1" : "Retry \(retryIndex) of \(maxRetries)"
        let header = "[\(Self.timeString())]  \(imageURL.lastPathComponent)\n\(retryText)"
        guard let hJS = jsLiteral(header) else { return }
        DevLog.log("VisualUI", "startStreamingEntry entry=\(entryId) file=\(imageURL.lastPathComponent) aiPageReady=\(aiPageReady ? 1 : 0)")
        enqueueVisualJavaScript("startStreamingEntry(\(hJS), null, \(entryId))")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dataURL = Self.thumbnailDataURL(for: imageURL, maxWidth: 280)
            DispatchQueue.main.async {
                guard let self else { return }
                if let url = dataURL, let urlJS = self.jsLiteral(url) {
                    DevLog.log("VisualUI", "thumbnail ready entry=\(entryId) file=\(imageURL.lastPathComponent) chars=\(url.count)")
                    self.enqueueVisualJavaScript("setStreamingEntryThumbnail(\(entryId), \(urlJS))")
                } else {
                    DevLog.log("VisualUI", "thumbnail failed entry=\(entryId) file=\(imageURL.lastPathComponent)")
                }
            }
        }
    }

    private static func thumbnailDataURL(for url: URL, maxWidth: CGFloat) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxWidth),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: thumb)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    private func scheduleVisualChunkFlush() {
        guard visualChunkFlushWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.visualChunkFlushWorkItem = nil
            self?.flushVisualStreamingChunks()
        }
        visualChunkFlushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
    }

    private func flushVisualStreamingChunks(for entryID: Int? = nil) {
        guard !visualPendingChunksByEntryID.isEmpty else { return }
        let targets: [(Int, String)]
        if let entryID {
            guard let text = visualPendingChunksByEntryID.removeValue(forKey: entryID), !text.isEmpty else { return }
            targets = [(entryID, text)]
        } else {
            targets = visualPendingChunksByEntryID.map { ($0.key, $0.value) }
            visualPendingChunksByEntryID.removeAll(keepingCapacity: true)
        }
        for (id, text) in targets.sorted(by: { $0.0 < $1.0 }) {
            guard let js = jsLiteral(text) else { continue }
            DevLog.log("VisualUI", "flush chunk entry=\(id) chars=\(text.count) aiPageReady=\(aiPageReady ? 1 : 0)")
            enqueueVisualJavaScript("appendStreamingChunk(\(id), \(js))")
        }
        visualBridge.flushNow()
    }

    private func scheduleAudioAIChunkFlush() {
        guard audioAIChunkFlushWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.audioAIChunkFlushWorkItem = nil
            self?.flushAudioAIStreamingChunks()
        }
        audioAIChunkFlushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
    }

    private func flushAudioAIStreamingChunks(for entryID: Int? = nil) {
        guard !audioAIPendingChunksByEntryID.isEmpty else { return }
        let targets: [(Int, String)]
        if let entryID {
            guard let text = audioAIPendingChunksByEntryID.removeValue(forKey: entryID), !text.isEmpty else { return }
            targets = [(entryID, text)]
        } else {
            targets = audioAIPendingChunksByEntryID.map { ($0.key, $0.value) }
            audioAIPendingChunksByEntryID.removeAll(keepingCapacity: true)
        }
        for (id, text) in targets.sorted(by: { $0.0 < $1.0 }) {
            guard let js = jsLiteral(text) else { continue }
            audioAIBridge.enqueue("appendStreamingChunk(\(id), \(js))")
        }
        audioAIBridge.flushNow()
    }

    private func scheduleOpencodeChunkFlush() {
        guard opencodeChunkFlushWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.opencodeChunkFlushWorkItem = nil
            self?.flushOpencodeStreamingChunks()
        }
        opencodeChunkFlushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
    }

    private func flushOpencodeStreamingChunks(for entryID: Int? = nil) {
        guard !opencodePendingStreamingChunksByEntryID.isEmpty else { return }
        let targets: [(Int, String)]
        if let entryID {
            guard let text = opencodePendingStreamingChunksByEntryID.removeValue(forKey: entryID), !text.isEmpty else { return }
            targets = [(entryID, text)]
        } else {
            targets = opencodePendingStreamingChunksByEntryID.map { ($0.key, $0.value) }
            opencodePendingStreamingChunksByEntryID.removeAll(keepingCapacity: true)
        }
        for (id, text) in targets.sorted(by: { $0.0 < $1.0 }) {
            guard let js = jsLiteral(text) else { continue }
            runOpencodeChatJavaScript("appendStreamingChunk(\(id), \(js))")
        }
        opencodeBridge.flushNow()
    }

    private func appendEntry(header: String, body: String, isError: Bool) {
        DevLog.log("VisualUI", "appendEntry queued isError=\(isError ? 1 : 0) aiPageReady=\(aiPageReady ? 1 : 0) header=\(header)")
        pendingEntries.append((header, body, isError))
        if pendingEntries.count > RetentionPolicy.pendingVisualEntryLimit {
            let overflow = pendingEntries.count - RetentionPolicy.pendingVisualEntryLimit
            pendingEntries.removeFirst(overflow)
            DevLog.log("VisualUI", "trimmed pending visual entries overflow=\(overflow) remaining=\(pendingEntries.count)")
        }
        flushPendingEntries()
    }

    private func flushPendingEntries() {
        DevLog.log("VisualUI", "flushPendingEntries ready=\(aiPageReady ? 1 : 0) count=\(pendingEntries.count)")
        guard aiPageReady, !pendingEntries.isEmpty else { return }
        for item in pendingEntries {
            guard let hJS = jsLiteral(item.header), let bJS = jsLiteral(item.body) else { continue }
            let js = "appendEntry(\(hJS), \(bJS), \(item.isError ? "true" : "false"))"
            enqueueVisualJavaScript(js)
        }
        pendingEntries.removeAll()
        flushPendingVisualScripts()
        visualBridge.flushNow()
    }

    private func markVisualPageReady(reason: String) {
        if aiPageReady {
            DevLog.log("VisualUI", "markVisualPageReady ignored alreadyReady reason=\(reason)")
            return
        }
        DevLog.log("VisualUI", "markVisualPageReady reason=\(reason)")
        aiPageReady = true
        enqueueVisualJavaScript("setMaxRenderedEntries(\(RetentionPolicy.visualRenderedEntryLimit))", immediate: true)
        flushPendingEntries()
        flushPendingVisualScripts()
    }

    private func probeVisualPageReadiness(reason: String) {
        guard let webView else {
            DevLog.log("VisualUI", "probeVisualPageReadiness skipped no webView reason=\(reason)")
            return
        }
        let js = """
        (function() {
          return [
            typeof startStreamingEntry,
            typeof setStreamingEntryStatus,
            typeof appendStreamingChunk,
            typeof endStreamingEntry
          ].join(",");
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error {
                    DevLog.log("VisualUI", "probeVisualPageReadiness error reason=\(reason) error=\(error.localizedDescription)")
                    return
                }
                let value = result as? String ?? "nil"
                DevLog.log("VisualUI", "probeVisualPageReadiness reason=\(reason) result=\(value)")
                if value == "function,function,function,function" {
                    self?.markVisualPageReady(reason: "probe:\(reason)")
                }
            }
        }
    }

    private func enqueueVisualJavaScript(_ script: String, immediate: Bool = false) {
        guard aiPageReady else {
            pendingVisualScripts.append(script)
            if pendingVisualScripts.count > RetentionPolicy.pendingVisualScriptLimit {
                let overflow = pendingVisualScripts.count - RetentionPolicy.pendingVisualScriptLimit
                pendingVisualScripts.removeFirst(overflow)
                DevLog.log("VisualUI", "trimmed pending visual scripts overflow=\(overflow) remaining=\(pendingVisualScripts.count)")
            }
            DevLog.log("VisualUI", "queue visual script count=\(pendingVisualScripts.count) script=\(visualScriptName(script))")
            return
        }
        DevLog.log("VisualUI", "enqueue visual script immediate=\(immediate ? 1 : 0) script=\(visualScriptName(script))")
        visualBridge.enqueue(script, immediate: immediate)
    }

    private func flushPendingVisualScripts() {
        DevLog.log("VisualUI", "flushPendingVisualScripts ready=\(aiPageReady ? 1 : 0) count=\(pendingVisualScripts.count)")
        guard aiPageReady, !pendingVisualScripts.isEmpty else { return }
        let scripts = pendingVisualScripts
        pendingVisualScripts.removeAll(keepingCapacity: true)
        for script in scripts {
            visualBridge.enqueue(script)
        }
        visualBridge.flushNow()
    }

    @objc private func zoomIn()  { enqueueVisualJavaScript("adjustZoom(1)", immediate: true) }
    @objc private func zoomOut() { enqueueVisualJavaScript("adjustZoom(-1)", immediate: true) }
    @objc private func retryAI() {
        DevLog.log("VisualUI", "retryAI tapped activeEntries=\(entryIdByImageURL.count) pendingCount=\(pendingCount)")
        removeActiveVisualStreamingEntriesForRetry()
        onRetryAI?()
    }

    @objc private func clearAI() {
        DevLog.log("VisualUI", "clearAI pendingEntries=\(pendingEntries.count) pendingScripts=\(pendingVisualScripts.count) activeEntries=\(entryIdByImageURL.count)")
        visualPendingChunksByEntryID.removeAll(keepingCapacity: false)
        pendingVisualScripts.removeAll(keepingCapacity: false)
        visualChunkFlushWorkItem?.cancel()
        visualChunkFlushWorkItem = nil
        enqueueVisualJavaScript("clearFeed()", immediate: true)
    }

    private func removeActiveVisualStreamingEntriesForRetry() {
        let activeEntries = entryIdByImageURL
        guard !activeEntries.isEmpty else { return }
        entryIdByImageURL.removeAll(keepingCapacity: true)
        pendingCount = max(0, pendingCount - activeEntries.count)
        for (imageURL, entryId) in activeEntries {
            DevLog.log("VisualUI", "retry removing active entry=\(entryId) file=\(imageURL.lastPathComponent)")
            visualPendingChunksByEntryID.removeValue(forKey: entryId)
            enqueueVisualJavaScript("removeStreamingEntry(\(entryId))", immediate: true)
        }
    }

    private func visualScriptName(_ script: String) -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = trimmed.firstIndex(of: "(") {
            return String(trimmed[..<paren])
        }
        return String(trimmed.prefix(80))
    }

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

    private static let ansiRegex = try? NSRegularExpression(pattern: #"\u001B\[[0-?]*[ -/]*[@-~]"#)

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

        function highlightBlocks(root, allowAutoDetect) {
          if (typeof hljs === 'undefined') return;
          root.querySelectorAll('pre code').forEach(function(block) {
            if (block.dataset.hlDone === '1') return;
            try {
              var classes = (block.className || '').split(/\\s+/);
              var hasLanguage = classes.some(function(c) { return c.indexOf('language-') === 0; });
              if (hasLanguage) {
                hljs.highlightElement(block);
                block.dataset.hlDone = '1';
                return;
              }
              if (allowAutoDetect && block.textContent && block.textContent.length <= 6000) {
                block.innerHTML = hljs.highlightAuto(block.textContent).value;
                block.dataset.hlDone = '1';
              }
            } catch (_) {}
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

          if ((kind === 'markdown' || kind === 'jupyter') && typeof marked !== 'undefined' && marked.parse) {
            root.innerHTML = marked.parse(content);
            normalizeMarkdownHtml(root);
            highlightBlocks(root, false);
            return;
          }

          if (kind === 'python' && typeof marked !== 'undefined' && marked.parse) {
            var wrapped = '```python\\n' + content + '\\n```';
            root.innerHTML = marked.parse(wrapped);
            normalizeMarkdownHtml(root);
            highlightBlocks(root, false);
            return;
          }

          root.innerHTML = '<pre><code>' + escapeHtml(content) + '</code></pre>';
        }

        function adjustZoom(delta) {
          currentFontSize = Math.min(Math.max(currentFontSize + delta, 9), 60);
          document.documentElement.style.setProperty('--font-size', currentFontSize + 'px');
        }

        if (typeof marked !== 'undefined' && marked.use) {
          marked.use({
            gfm: true,
            breaks: true
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

      .entry-card {
        border: 1px solid var(--border);
        border-radius: 10px;
        padding: 12px 14px;
        margin: 10px 0;
      }
      .entry-user {
        background: rgba(10,132,255,0.10);
      }
      .entry-opencode {
        background: rgba(142,142,147,0.10);
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
      var pendingAutoScroll = false;
      var maxRenderedEntries = 80;
      window.addEventListener('scroll', function() {
        var sv = document.scrollingElement || document.documentElement;
        userScrolledUp = sv.scrollTop + sv.clientHeight < sv.scrollHeight - 60;
      }, { passive: true });

      function scheduleAutoScroll() {
        if (userScrolledUp || pendingAutoScroll) return;
        pendingAutoScroll = true;
        requestAnimationFrame(function() {
          pendingAutoScroll = false;
          var sv = document.scrollingElement || document.documentElement;
          if (!userScrolledUp) sv.scrollTop = sv.scrollHeight;
        });
      }

      function destroyEntryNode(entryNode) {
        if (!entryNode) return;
        var entryId = entryNode.dataset ? entryNode.dataset.entryId : null;
        if (entryId) delete streamingBodiesById[String(entryId)];
        entryNode.querySelectorAll('img').forEach(function(img) { img.src = ''; });
      }

      function pruneFeedIfNeeded() {
        var feed = document.getElementById('feed');
        if (!feed) return;
        var entries = Array.from(feed.children).filter(function(node) {
          return node && node.dataset && node.dataset.entryKind === 'entry';
        });
        while (entries.length > maxRenderedEntries) {
          var oldest = entries.shift();
          destroyEntryNode(oldest);
          var prev = oldest.previousElementSibling;
          var next = oldest.nextElementSibling;
          feed.removeChild(oldest);
          if (next && next.classList && next.classList.contains('entry-divider')) {
            feed.removeChild(next);
          } else if (prev && prev.classList && prev.classList.contains('entry-divider')) {
            feed.removeChild(prev);
          }
        }
      }

      function setMaxRenderedEntries(limit) {
        var parsed = Number(limit);
        if (!Number.isFinite(parsed)) return;
        maxRenderedEntries = Math.max(1, Math.floor(parsed));
        pruneFeedIfNeeded();
      }

      function performMemoryMaintenance() {
        pruneFeedIfNeeded();
        var feed = document.getElementById('feed');
        var liveStreamingIds = Object.create(null);
        if (feed) {
          Array.from(feed.children).forEach(function(node) {
            if (!node || !node.dataset || node.dataset.entryKind !== 'entry') return;
            if (node.dataset.entryId) liveStreamingIds[String(node.dataset.entryId)] = true;
          });
        }
        Object.keys(streamingBodiesById).forEach(function(entryId) {
          var body = streamingBodiesById[entryId];
          if (!body || !body.isConnected || !liveStreamingIds[entryId]) {
            delete streamingBodiesById[entryId];
          }
        });
      }

      function escapeHtml(s) {
        var div = document.createElement('div');
        div.textContent = s;
        return div.innerHTML;
      }

      function applyRoleStyle(entry, header) {
        var normalized = (header || '').trim().toLowerCase();
        if (normalized === 'you') {
          entry.classList.add('entry-card', 'entry-user');
        } else if (normalized === 'opencode') {
          entry.classList.add('entry-card', 'entry-opencode');
        }
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
          applyRoleStyle(entry, header);
          entry.dataset.entryId = String(entryId);
          entry.dataset.entryKind = 'entry';
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
          pruneFeedIfNeeded();
          streamingBodiesById[String(entryId)] = body;
          scheduleAutoScroll();
        } catch (e) { console.error('startStreamingEntry', e); }
      }
      function setStreamingEntryStatus(entryId, status) {
        var entry = document.querySelector('[data-entry-id="' + entryId + '"]');
        if (!entry) return;
        var hdr = entry.querySelector('.entry-header');
        if (!hdr) return;
        var lines = (hdr.textContent || '').split('\\n');
        if (lines.length <= 1) hdr.textContent = lines[0] + '\\n' + status;
        else { lines[lines.length - 1] = status; hdr.textContent = lines.join('\\n'); }
      }
      function replaceStreamingEntryContent(entryId, markdown) {
        var key = String(entryId);
        var body = streamingBodiesById[key];
        if (!body) {
          var entry = document.querySelector('[data-entry-id="' + entryId + '"]');
          body = entry ? entry.querySelector('.streaming-body, .entry-body, .entry-error-body') : null;
        }
        if (!body) return;
        body.classList.remove('entry-error-body');
        body.classList.add('streaming-body');
        streamingBodiesById[key] = body;
        body.textContent = markdown || '';
        scheduleAutoScroll();
      }
      function removeStreamingEntry(entryId) {
        var entry = document.querySelector('[data-entry-id="' + entryId + '"]');
        if (!entry || !entry.parentNode) return;
        delete streamingBodiesById[String(entryId)];
        destroyEntryNode(entry);
        var prev = entry.previousElementSibling;
        var next = entry.nextElementSibling;
        var parent = entry.parentNode;
        parent.removeChild(entry);
        if (next && next.classList && next.classList.contains('entry-divider')) parent.removeChild(next);
        else if (prev && prev.classList && prev.classList.contains('entry-divider')) parent.removeChild(prev);
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
          scheduleAutoScroll();
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
          if (codeEl && typeof hljs !== 'undefined' && lang && lang !== 'mermaid') {
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
        scheduleAutoScroll();
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
          var feed = document.getElementById('feed');
          if (!feed) return;
          if (feed.children.length > 0) {
            var hr = document.createElement('hr');
            hr.className = 'entry-divider';
            feed.appendChild(hr);
          }
          var entry = document.createElement('div');
          applyRoleStyle(entry, header);
          entry.dataset.entryKind = 'entry';
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
              if (codeEl && typeof hljs !== 'undefined' && lang && lang !== 'mermaid') {
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
          pruneFeedIfNeeded();
          scheduleAutoScroll();
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

      function clearFeed() {
        var feed = document.getElementById('feed');
        if (feed) {
          Array.from(feed.children).forEach(function(node) {
            if (node && node.dataset && node.dataset.entryKind === 'entry') destroyEntryNode(node);
          });
          feed.innerHTML = '';
        }
        streamingBodiesById = Object.create(null);
      }

      function adjustZoom(delta) {
        currentFontSize = Math.min(Math.max(currentFontSize + delta, 9), 60);
        document.documentElement.style.setProperty('--font-size', currentFontSize + 'px');
      }

      if (typeof mermaid !== 'undefined') {
        mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'loose', fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif' });
      }
      if (typeof marked !== 'undefined' && marked.use) {
        marked.use({
          gfm: true,
          breaks: true
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
        refreshFileExploreDirectory(node, reloadIfNeeded: true)
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
        let iconKey: String = {
            if node.isDirectory { return "dir" }
            let ext = node.url.pathExtension.lowercased()
            return ext.isEmpty ? "file" : "ext:\(ext)"
        }()
        if let cached = fileExploreIconCache[iconKey] {
            cell.imageView?.image = cached
        } else {
            let icon = NSWorkspace.shared.icon(forFile: node.url.path)
            icon.size = NSSize(width: 16, height: 16)
            fileExploreIconCache[iconKey] = icon
            cell.imageView?.image = icon
        }
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
        DevLog.log("VisualUI", "WKNavigation didFinish visual webView")
        probeVisualPageReadiness(reason: "didFinish")
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

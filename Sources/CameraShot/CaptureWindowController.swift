import AppKit
import AVFoundation
import QuartzCore
import WebKit

// MARK: - PreviewContent

enum PreviewContent {
    case camera(AVCaptureSession)
    case screen
}

// MARK: - CaptureWindowController

/// Single window shown after capture starts.
/// Tab 0 — Preview: live camera or screen feed with status overlay.
/// Tab 1 — AI Responses: WKWebView with full markdown + syntax highlighting.
final class CaptureWindowController: NSWindowController {

    // MARK: – Preview

    private weak var previewPane: NSView!
    private weak var screenLayer: CALayer?
    private weak var statusField: NSTextField!

    // MARK: – AI

    private var webView: WKWebView!
    private weak var aiPane:   NSView!
    private weak var spinner:  NSProgressIndicator!
    private weak var aiStatus: NSTextField!
    private var pendingCount = 0 { didSet { updateAIStatus() } }

    // MARK: – Toolbar

    private weak var tabCtrl:    NSSegmentedControl!
    private weak var pauseButton: NSButton!
    private weak var stopButton:  NSButton!
    private var aiPaused = false

    /// Called when AI is paused (`true`) or resumed (`false`).
    var onPauseAI: ((Bool) -> Void)?
    /// Called when the user clicks Stop — stops capture entirely.
    var onStop: (() -> Void)?

    // MARK: – Init

    init(source: PreviewContent, name: String, interval: TimeInterval) {
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
        win.backgroundColor = .black
        win.isMovableByWindowBackground = true
        super.init(window: win)
        buildUI(source: source, name: name, interval: interval)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: – Public — preview

    func updateStatus(filename: String, count: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.statusField.stringValue = "Last: \(filename)  ·  saved \(count)"
        }
    }

    func updatePreviewImage(_ image: CGImage) {
        guard let layer = screenLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }

    // MARK: – Public — AI results

    func markProcessingStarted() {
        DispatchQueue.main.async { [weak self] in self?.pendingCount += 1 }
    }

    func appendResult(response: String, imageURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingCount = max(0, self.pendingCount - 1)
            let ts = Self.timeString()
            self.appendEntry(header: "[\(ts)]  \(imageURL.lastPathComponent)",
                             body: response, isError: false)
        }
    }

    func appendError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingCount = max(0, self.pendingCount - 1)
            let ts = Self.timeString()
            self.appendEntry(header: "[\(ts)]  Error", body: message, isError: true)
        }
    }

    // MARK: – UI construction

    private func buildUI(source: PreviewContent, name: String, interval: TimeInterval) {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true

        let toolbar = makeToolbar(name: name)
        root.addSubview(toolbar)

        // ── Preview pane ─────────────────────────────────────────────────────
        let pvPane = NSView()
        pvPane.wantsLayer = true
        pvPane.layer?.backgroundColor = NSColor.black.cgColor
        pvPane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pvPane)
        previewPane = pvPane

        switch source {
        case .camera(let session):
            let cv = CameraPreviewView(frame: .zero, session: session)
            cv.translatesAutoresizingMaskIntoConstraints = false
            pvPane.addSubview(cv)
            NSLayoutConstraint.activate([
                cv.topAnchor.constraint(equalTo: pvPane.topAnchor),
                cv.leadingAnchor.constraint(equalTo: pvPane.leadingAnchor),
                cv.trailingAnchor.constraint(equalTo: pvPane.trailingAnchor),
                cv.bottomAnchor.constraint(equalTo: pvPane.bottomAnchor),
            ])
        case .screen:
            let sl = CALayer()
            sl.contentsGravity  = .resizeAspect
            sl.backgroundColor  = NSColor.black.cgColor
            sl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            pvPane.layer?.addSublayer(sl)
            screenLayer = sl
        }

        let statusOverlay = NSView()
        statusOverlay.wantsLayer = true
        statusOverlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        pvPane.addSubview(statusOverlay)

        let sf = NSTextField(labelWithString: "\(name)  ·  every \(Int(interval))s  ·  saved 0")
        sf.font          = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        sf.textColor     = .white
        sf.lineBreakMode = .byTruncatingTail
        sf.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(sf)
        statusField = sf

        NSLayoutConstraint.activate([
            statusOverlay.leadingAnchor.constraint(equalTo: pvPane.leadingAnchor),
            statusOverlay.trailingAnchor.constraint(equalTo: pvPane.trailingAnchor),
            statusOverlay.bottomAnchor.constraint(equalTo: pvPane.bottomAnchor),
            statusOverlay.heightAnchor.constraint(equalToConstant: 28),
            sf.leadingAnchor.constraint(equalTo: statusOverlay.leadingAnchor, constant: 12),
            sf.trailingAnchor.constraint(equalTo: statusOverlay.trailingAnchor, constant: -12),
            sf.centerYAnchor.constraint(equalTo: statusOverlay.centerYAnchor),
        ])

        // ── AI pane ──────────────────────────────────────────────────────────
        let ap = buildAIPane()
        ap.isHidden = true
        root.addSubview(ap)
        aiPane = ap

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            pvPane.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            pvPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pvPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pvPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            ap.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            ap.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ap.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ap.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func makeToolbar(name: String) -> NSView {
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

        let tabs = NSSegmentedControl(
            labels: ["Preview", "AI Responses"],
            trackingMode: .selectOne, target: self, action: #selector(tabChanged)
        )
        tabs.selectedSegment = 0
        tabs.controlSize     = .small
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabCtrl = tabs
        bar.addSubview(tabs)

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

        // Pause AI button (yellow)
        let pauseBtn = NSButton(title: "⏸  Pause AI", target: self, action: #selector(pauseAITapped))
        pauseBtn.bezelStyle = .rounded
        pauseBtn.controlSize = .small
        pauseBtn.contentTintColor = .systemYellow
        pauseBtn.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(pauseBtn)
        pauseButton = pauseBtn

        // Stop button (red)
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
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 180),

            tabs.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            tabs.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

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
        // WKWebView config — register copy-code message handler
        let config = WKWebViewConfiguration()
        let handler = CopyCodeHandler()
        config.userContentController.add(handler, name: "copyCode")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        // Transparent background so the system appearance shows through
        wv.setValue(false, forKey: "drawsBackground")
        webView = wv

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Inner top bar with zoom + clear
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

        let zoomOut = barBtn("−", action: #selector(zoomOut))
        let zoomIn  = barBtn("+", action: #selector(zoomIn))
        let clear   = barBtn("Clear", action: #selector(clearAI))
        clear.font  = .systemFont(ofSize: 11)

        [zoomOut, zoomIn, clear].forEach { innerBar.addSubview($0) }

        let divider = NSBox(); divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        container.addSubview(wv)

        NSLayoutConstraint.activate([
            innerBar.topAnchor.constraint(equalTo: container.topAnchor),
            innerBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            innerBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            innerBar.heightAnchor.constraint(equalToConstant: 36),

            zoomOut.trailingAnchor.constraint(equalTo: zoomIn.leadingAnchor, constant: -2),
            zoomOut.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),
            zoomIn.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -10),
            zoomIn.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: innerBar.trailingAnchor, constant: -14),
            clear.centerYAnchor.constraint(equalTo: innerBar.centerYAnchor),

            divider.topAnchor.constraint(equalTo: innerBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            wv.topAnchor.constraint(equalTo: divider.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        wv.loadHTMLString(Self.htmlTemplate, baseURL: nil)
        return container
    }

    // MARK: – Tab switching

    @objc private func tabChanged() {
        let isAI = tabCtrl.selectedSegment == 1
        previewPane.isHidden = isAI
        aiPane.isHidden      = !isAI
        window?.backgroundColor = isAI ? .windowBackgroundColor : .black
    }

    // MARK: – AI helpers

    private func appendEntry(header: String, body: String, isError: Bool) {
        guard let hJS = jsLiteral(header), let bJS = jsLiteral(body) else { return }
        let js = "appendEntry(\(hJS), \(bJS), \(isError ? "true" : "false"))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc private func zoomIn()  { webView.evaluateJavaScript("adjustZoom(1)",  completionHandler: nil) }
    @objc private func zoomOut() { webView.evaluateJavaScript("adjustZoom(-1)", completionHandler: nil) }
    @objc private func clearAI() { webView.evaluateJavaScript("clearFeed()",    completionHandler: nil) }

    /// Encodes a Swift string as a JSON string literal safe to embed in JS.
    /// Wraps in an array so JSONSerialization accepts it, then strips the [ ].
    private func jsLiteral(_ s: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let str  = String(data: data, encoding: .utf8) else { return nil }
        // str is e.g. ["hello \"world\""] — strip the outer brackets
        return String(str.dropFirst().dropLast())
    }

    private func updateAIStatus() {
        if pendingCount > 0 {
            spinner.startAnimation(nil)
            aiStatus.stringValue = pendingCount == 1 ? "Processing…" : "Processing \(pendingCount)…"
            tabCtrl.setLabel("AI Responses ●", forSegment: 1)
        } else {
            spinner.stopAnimation(nil)
            aiStatus.stringValue = ""
            tabCtrl.setLabel("AI Responses", forSegment: 1)
        }
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
    <link rel="stylesheet"
          href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark-dimmed.min.css">
    <script src="https://cdn.jsdelivr.net/npm/marked@9/marked.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
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

      /* Typography */
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

      /* Inline code */
      code:not(pre > code) {
        background: var(--code-bg);
        border-radius: 4px;
        padding: 2px 5px;
        font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 0.87em;
      }

      /* Code block wrapper */
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

      /* Language badge */
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

      /* Copy button */
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

      /* Entry header */
      .entry-header {
        font-family: 'SF Mono', monospace;
        font-size: 11px;
        color: var(--fg2);
        margin-bottom: 10px;
      }

      /* Divider between entries */
      .entry-divider {
        border: none;
        border-top: 1px solid var(--border);
        margin: 28px 0;
      }

      /* Error body */
      .entry-error-body {
        color: #ff3b30;
      }

      /* Tables */
      table { border-collapse: collapse; width: 100%; margin: 12px 0; }
      th, td { border: 1px solid var(--border); padding: 6px 10px; text-align: left; }
      th { background: var(--code-bg); font-weight: 600; }

      /* Mermaid diagrams */
      .mermaid-wrapper {
        background: #1e1e2e;
        border-radius: 10px;
        padding: 20px;
        margin: 14px 0;
        display: flex;
        justify-content: center;
        overflow-x: auto;
      }
      .mermaid-wrapper svg {
        max-width: 100%;
        height: auto;
      }
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
      mermaid.initialize({
        startOnLoad: false,
        theme: 'dark',
        securityLevel: 'loose',
        fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif'
      });

      marked.use({
        gfm: true,
        breaks: true,
        highlight: function(code, lang) {
          if (lang && lang !== 'mermaid' && hljs.getLanguage(lang)) {
            return hljs.highlight(code, { language: lang }).value;
          }
          return lang === 'mermaid' ? code : hljs.highlightAuto(code).value;
        }
      });

      var currentFontSize = 14;

      // Track whether the user has scrolled up away from the bottom.
      // Only auto-scroll when they are already pinned to the bottom.
      var userScrolledUp = false;
      window.addEventListener('scroll', function() {
        var sv = document.scrollingElement || document.documentElement;
        userScrolledUp = sv.scrollTop + sv.clientHeight < sv.scrollHeight - 60;
      }, { passive: true });

      function appendEntry(header, markdown, isError) {
        var sv = document.scrollingElement || document.documentElement;

        var feed = document.getElementById('feed');

        // Divider between entries (not before the first one)
        if (feed.children.length > 0) {
          var hr = document.createElement('hr');
          hr.className = 'entry-divider';
          feed.appendChild(hr);
        }

        var entry = document.createElement('div');

        // Header row
        var hdr = document.createElement('div');
        hdr.className = 'entry-header';
        hdr.textContent = header;
        entry.appendChild(hdr);

        // Body
        var body = document.createElement('div');
        if (isError) {
          body.className = 'entry-error-body';
          body.textContent = markdown;
        } else {
          body.innerHTML = marked.parse(markdown);

          // Process each code block
          var mermaidNodes = [];
          body.querySelectorAll('pre').forEach(function(pre) {
            var codeEl = pre.querySelector('code');
            var lang = '';
            if (codeEl) {
              var cls = codeEl.className || '';
              var m = cls.match(/language-(\\S+)/);
              if (m) lang = m[1];
            }

            // ── Mermaid: render as diagram ────────────────────────────────
            if (lang === 'mermaid') {
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

            // ── Regular code block ────────────────────────────────────────
            if (codeEl) {
              if (lang && hljs.getLanguage(lang)) {
                codeEl.innerHTML = hljs.highlight(codeEl.textContent, { language: lang }).value;
              } else {
                hljs.highlightElement(codeEl);
              }
            }

            var wrapper = document.createElement('div');
            wrapper.className = 'code-wrapper';
            pre.parentNode.insertBefore(wrapper, pre);
            wrapper.appendChild(pre);

            if (lang) {
              var badge = document.createElement('span');
              badge.className = 'lang-label';
              badge.textContent = lang;
              wrapper.appendChild(badge);
            }

            var btn = document.createElement('button');
            btn.className = 'copy-btn';
            btn.textContent = 'Copy';
            btn.addEventListener('click', function() {
              var text = codeEl ? codeEl.innerText : pre.innerText;
              window.webkit.messageHandlers.copyCode.postMessage(text);
              btn.textContent = 'Copied!';
              btn.classList.add('copied');
              setTimeout(function() {
                btn.textContent = 'Copy';
                btn.classList.remove('copied');
              }, 1600);
            });
            wrapper.appendChild(btn);
          });

          // Run mermaid on collected diagram nodes
          if (mermaidNodes.length > 0) {
            mermaid.run({ nodes: mermaidNodes }).catch(function(err) {
              mermaidNodes.forEach(function(n) {
                n.innerHTML = '<span class="mermaid-error">Mermaid error: ' + err.message + '</span>';
              });
            });
          }
        }

        entry.appendChild(body);
        feed.appendChild(entry);

        if (!userScrolledUp) {
          sv.scrollTop = sv.scrollHeight;
        }
      }

      function clearFeed() {
        document.getElementById('feed').innerHTML = '';
      }

      function adjustZoom(delta) {
        currentFontSize = Math.min(Math.max(currentFontSize + delta, 9), 30);
        document.documentElement.style.setProperty('--font-size', currentFontSize + 'px');
      }
    </script>
    </body>
    </html>
    """
}

// MARK: - CopyCodeHandler

/// Receives copy requests from the web page and writes to NSPasteboard.
private final class CopyCodeHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "copyCode", let text = message.body as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - CameraPreviewView

private final class CameraPreviewView: NSView {
    private let captureSession: AVCaptureSession
    init(frame: NSRect, session: AVCaptureSession) {
        captureSession = session; super.init(frame: frame); wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    override func makeBackingLayer() -> CALayer {
        let l = AVCaptureVideoPreviewLayer(session: captureSession)
        l.videoGravity = .resizeAspect; l.backgroundColor = NSColor.black.cgColor; return l
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.frame = bounds; CATransaction.commit()
    }
}

import Foundation
import WebKit

final class WebViewBatchBridge {
    private weak var webView: WKWebView?
    private let label: String
    private let flushInterval: TimeInterval
    private var pendingScripts: [String] = []
    private var flushWorkItem: DispatchWorkItem?

    init(label: String, flushInterval: TimeInterval = 0.04) {
        self.label = label
        self.flushInterval = flushInterval
    }

    func attach(webView: WKWebView) {
        runOnMain {
            self.webView = webView
        }
    }

    func enqueue(_ script: String, immediate: Bool = false) {
        runOnMain {
            self.pendingScripts.append(script)
            if immediate {
                self.flushNow()
                return
            }
            self.scheduleFlush()
        }
    }

    func flushNow() {
        runOnMain {
            guard !self.pendingScripts.isEmpty else { return }
            let scripts = self.pendingScripts
            self.pendingScripts.removeAll(keepingCapacity: true)
            self.flushWorkItem?.cancel()
            self.flushWorkItem = nil

            guard let webView = self.webView else { return }
            let joined = scripts.joined(separator: ";\n")
            let started = CapturePerf.begin()
            webView.evaluateJavaScript(joined, completionHandler: nil)
            CapturePerf.end(started, "webview.flush.\(self.label)", details: "scripts=\(scripts.count),chars=\(joined.count)")
        }
    }

    func clear() {
        runOnMain {
            self.pendingScripts.removeAll(keepingCapacity: false)
            self.flushWorkItem?.cancel()
            self.flushWorkItem = nil
        }
    }

    private func scheduleFlush() {
        guard flushWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.flushWorkItem = nil
            self?.flushNow()
        }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval, execute: item)
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

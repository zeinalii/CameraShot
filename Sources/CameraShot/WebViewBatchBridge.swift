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
            self.log("attached webView")
        }
    }

    func enqueue(_ script: String, immediate: Bool = false) {
        runOnMain {
            self.pendingScripts.append(script)
            self.log("enqueue immediate=\(immediate ? 1 : 0) pending=\(self.pendingScripts.count) script=\(self.scriptSummary(script))")
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

            guard let webView = self.webView else {
                self.log("flush dropped because webView is nil scripts=\(scripts.count)")
                return
            }
            let joined = scripts.joined(separator: ";\n")
            let executable = self.wrappedExecutable(for: scripts)
            let started = CapturePerf.begin()
            self.log("flush scripts=\(scripts.count) chars=\(joined.count) first=\(self.scriptSummary(scripts.first ?? ""))")
            webView.evaluateJavaScript(executable) { result, error in
                if let error {
                    self.log("evaluateJavaScript failed scripts=\(scripts.count) error=\(error.localizedDescription) first=\(self.scriptSummary(scripts.first ?? ""))")
                } else if let result = result as? String, result != "ok" {
                    self.log("evaluateJavaScript js-errors scripts=\(scripts.count) result=\(result)")
                } else {
                    self.log("evaluateJavaScript ok scripts=\(scripts.count)")
                }
            }
            CapturePerf.end(started, "webview.flush.\(self.label)", details: "scripts=\(scripts.count),chars=\(joined.count)")
        }
    }

    func clear() {
        runOnMain {
            self.log("clear pending=\(self.pendingScripts.count)")
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

    private func log(_ message: String) {
        guard ["visual", "audioAI", "instantVoice", "chat"].contains(label) else { return }
        DevLog.log("WebViewBridge", "\(label): \(message)")
    }

    private func scriptSummary(_ script: String) -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = trimmed.firstIndex(of: "(") {
            return String(trimmed[..<paren])
        }
        return String(trimmed.prefix(80))
    }

    private func wrappedExecutable(for scripts: [String]) -> String {
        let body = scripts.enumerated().map { index, script in
            """
            try {
            \(script)
            } catch (e) {
              __cameraShotErrors.push("\(index):" + ((e && e.name) ? e.name : "Error") + ": " + ((e && e.message) ? e.message : String(e)));
            }
            """
        }.joined(separator: "\n")

        return """
        (function() {
          var __cameraShotErrors = [];
        \(body)
          return __cameraShotErrors.length ? __cameraShotErrors.join("\\n") : "ok";
        })()
        """
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

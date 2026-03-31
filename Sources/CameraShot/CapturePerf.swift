import Foundation

enum CapturePerf {
    #if DEBUG
    private static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CAMERASHOT_PERF"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "capture.perf.enabled")
    }()
    #else
    private static let isEnabled = false
    #endif

    static func begin() -> CFAbsoluteTime {
        guard isEnabled else { return 0 }
        return CFAbsoluteTimeGetCurrent()
    }

    static func end(_ start: CFAbsoluteTime, _ label: String, details: String = "") {
        guard isEnabled, start > 0 else { return }
        let elapsedMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log("\(label) took \(String(format: "%.2f", elapsedMS))ms\(details.isEmpty ? "" : " | \(details)")")
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        NSLog("[CapturePerf] %@", message)
    }
}

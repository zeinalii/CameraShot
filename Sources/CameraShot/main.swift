import AppKit

let app      = NSApplication.shared
let delegate = AppDelegate()
NSWindow.allowsAutomaticWindowTabbing = false

let hideDockIcon = ProcessInfo.processInfo.environment["CAMERASHOT_HIDE_DOCK"] == "1"
    || CommandLine.arguments.contains("--hide-dock")
app.setActivationPolicy(hideDockIcon ? .accessory : .regular)
app.delegate = delegate
app.run()

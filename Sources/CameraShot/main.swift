import AppKit

let app      = NSApplication.shared
let delegate = AppDelegate()
NSWindow.allowsAutomaticWindowTabbing = false
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()

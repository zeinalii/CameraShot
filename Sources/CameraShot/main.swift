import AppKit

let app      = NSApplication.shared
let delegate = AppDelegate()
NSWindow.allowsAutomaticWindowTabbing = false

// CameraShot is a windowed utility, but it should not occupy space in the Dock.
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()

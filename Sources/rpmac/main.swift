import Foundation
import AppKit

// Initialize NSApplication so we can create overlay windows.
// We don't activate it — rpmac stays in the background.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

print("rpmac — ratpoison-style window manager for macOS")
print("")

// Check accessibility permissions first
guard AccessibilityHelper.checkPermissions() else {
    print("Please grant accessibility permissions and restart rpmac.")
    exit(1)
}

print("Accessibility permissions OK.")
print("")

let wm = WindowManager()

// Auto-capture all existing windows
wm.captureAllWindows()
wm.printStatus()
print("")

// Start keybindings (Ctrl-t prefix)
let keyBinder = KeyBinder(wm: wm)
if !keyBinder.start() {
    print("Failed to start keybindings. Falling back to socket-only mode.")
    print("")
}

// Also start socket server for scripting
let server = CommandServer(wm: wm)

// Handle clean shutdown
signal(SIGINT) { _ in
    print("\nShutting down...")
    unlink("/tmp/rpmac.sock")
    exit(0)
}

signal(SIGTERM) { _ in
    unlink("/tmp/rpmac.sock")
    exit(0)
}

server.start()

print("Socket commands also available at /tmp/rpmac.sock")
print("")

// Run the app event loop (needed for NSWindow overlay + run loop)
app.run()

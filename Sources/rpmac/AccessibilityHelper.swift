import Foundation
import ApplicationServices
import AppKit

enum AccessibilityHelper {
    /// Check if we have accessibility permissions
    static func checkPermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("⚠ Accessibility permissions required.")
            print("  Go to: System Settings → Privacy & Security → Accessibility")
            print("  Add and enable rpmac.")
            print("")
            print("  Requesting permission prompt...")
            // This triggers the system prompt
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        return trusted
    }

    /// List all normal windows across all applications
    static func allWindows() -> [WindowRef] {
        var windows: [WindowRef] = []
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in apps {
            let pid = app.processIdentifier
            let appRef = AXUIElementCreateApplication(pid)

            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
            guard result == .success, let axWindows = value as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                let wref = WindowRef(pid: pid, element: axWindow)
                if wref.isNormalWindow {
                    windows.append(wref)
                }
            }
        }
        return windows
    }

    /// Get the currently focused window
    static func focusedWindow() -> WindowRef? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success else { return nil }

        return WindowRef(pid: pid, element: value as! AXUIElement)
    }

    /// Get the usable screen rect (minus menu bar and dock) in Accessibility API coordinates (top-left origin)
    static func screenRect() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        // NSScreen uses bottom-left origin (Cocoa), Accessibility API uses top-left origin.
        // screen.frame.maxY is the total screen height (including menu bar).
        // visibleFrame excludes menu bar at top and dock.
        let visible = screen.visibleFrame
        let fullHeight = screen.frame.height
        let yFlipped = fullHeight - visible.origin.y - visible.height
        return CGRect(x: visible.origin.x, y: yFlipped, width: visible.width, height: visible.height)
    }
}

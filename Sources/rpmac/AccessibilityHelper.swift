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
        return screenRect(for: NSScreen.main)
    }

    /// Get usable rect for a specific NSScreen, in Accessibility API coordinates (top-left origin)
    static func screenRect(for screen: NSScreen?) -> CGRect {
        guard let screen = screen else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        // NSScreen uses bottom-left origin (Cocoa), Accessibility API uses top-left origin.
        // For multi-monitor, the primary screen's origin is (0,0) at bottom-left.
        // In AX coordinates, primary screen origin is (0,0) at top-left.
        // We need to convert using the primary screen's height as the reference.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let visible = screen.visibleFrame
        let yFlipped = primaryHeight - visible.origin.y - visible.height
        return CGRect(x: visible.origin.x, y: yFlipped, width: visible.width, height: visible.height)
    }

    /// All screens as AX-coordinate rects, ordered by position (left to right)
    static func allScreenRects() -> [(screen: NSScreen, rect: CGRect)] {
        return NSScreen.screens
            .map { ($0, screenRect(for: $0)) }
            .sorted { $0.rect.origin.x < $1.rect.origin.x }
    }
}

import Foundation
import ApplicationServices
import AppKit

/// Reference to a macOS window via the Accessibility API
struct WindowRef: Equatable {
    let pid: pid_t
    let element: AXUIElement

    static func == (lhs: WindowRef, rhs: WindowRef) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element)
    }

    /// Move and resize the window to fill the given rect
    func moveResize(to rect: CGRect) {
        var pos = CGPoint(x: rect.origin.x, y: rect.origin.y)
        var size = CGSize(width: rect.width, height: rect.height)

        if let posValue = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    /// Get the window title
    var title: String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    /// Whether the window is a normal, resizable window (not a menu, dialog, etc.)
    var isNormalWindow: Bool {
        var value: AnyObject?

        // Check subrole
        let roleResult = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        guard roleResult == .success, let subrole = value as? String else { return false }
        return subrole == kAXStandardWindowSubrole as String
    }

    /// Get current position and size
    var frame: CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: pos, size: size)
    }

    /// Raise this window to front and give it keyboard focus
    func raise(warp: Bool = false) {
        if warp, let f = frame {
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        // Activate the owning application
        let app = NSRunningApplication(processIdentifier: pid)
        app?.activate(options: [.activateIgnoringOtherApps])

        // Raise the window visually
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        // Set this as the focused window of the application
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}

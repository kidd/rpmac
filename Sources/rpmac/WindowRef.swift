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

    /// Apps that don't respond to AX focus changes and need a synthetic click
    static var clickToFocusApps: Set<String> = ["alacritty"]

    /// Whether this window's app needs a synthetic click to receive focus
    private var needsClickToFocus: Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let name = app.localizedName?.lowercased() else { return false }
        return Self.clickToFocusApps.contains(name)
    }

    /// Raise this window to front and give it keyboard focus
    func raise(warp: Bool = false) {
        // Activate the owning application
        let app = NSRunningApplication(processIdentifier: pid)
        app?.activate(options: [.activateIgnoringOtherApps])

        // Raise the window visually
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        // Set this as the focused window of the application
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)

        if warp, let f = frame {
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
            CGAssociateMouseAndMouseCursorPosition(1)
        } else if needsClickToFocus, let f = frame {
            // Synthetic click for apps that don't respond to AX focus.
            // Save cursor, warp, click, then warp back.
            let clickPoint = CGPoint(x: f.midX, y: f.midY)
            let savedPos = CGEvent(source: nil)?.location ?? clickPoint

            CGWarpMouseCursorPosition(clickPoint)

            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left),
               let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left) {
                mouseDown.post(tap: .cgSessionEventTap)
                mouseUp.post(tap: .cgSessionEventTap)
            }

            // Small delay so the click registers before we move the cursor back
            usleep(50_000)
            CGWarpMouseCursorPosition(savedPos)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}

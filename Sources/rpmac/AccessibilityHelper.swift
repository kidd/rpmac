import Foundation
import ApplicationServices
import AppKit

/// Observes AX window-created and window-destroyed notifications for a single app.
class AppWindowObserver {
    let pid: pid_t
    let observer: AXObserver
    let createCallback: (AXUIElement) -> Void
    let destroyCallback: (AXUIElement) -> Void

    init?(pid: pid_t, onCreate: @escaping (AXUIElement) -> Void, onDestroy: @escaping (AXUIElement) -> Void) {
        self.pid = pid
        self.createCallback = onCreate
        self.destroyCallback = onDestroy

        var obs: AXObserver?
        let err = AXObserverCreate(pid, { (_: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) in
            guard let refcon = refcon else { return }
            let observer = Unmanaged<AppWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            if notification as String == kAXUIElementDestroyedNotification as String {
                observer.destroyCallback(element)
            } else {
                observer.createCallback(element)
            }
        }, &obs)
        guard err == .success, let observer = obs else { return nil }
        self.observer = observer

        let appRef = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appRef, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appRef, kAXUIElementDestroyedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}

/// Watches for new app launches and installs per-app AX observers.
class WindowCreationWatcher {
    private var observers: [pid_t: AppWindowObserver] = [:]
    private var createCallback: (AXUIElement, pid_t) -> Void
    private var destroyCallback: (AXUIElement, pid_t) -> Void
    private var workspaceObserver: NSObjectProtocol?

    init(onCreate: @escaping (AXUIElement, pid_t) -> Void, onDestroy: @escaping (AXUIElement, pid_t) -> Void) {
        self.createCallback = onCreate
        self.destroyCallback = onDestroy
    }

    func start() {
        // Observe all currently running apps
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            watchApp(pid: app.processIdentifier)
        }

        // Observe newly launched apps
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            self?.watchApp(pid: app.processIdentifier)
        }

        // Clean up terminated apps
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observers.removeValue(forKey: app.processIdentifier)
        }
    }

    private func watchApp(pid: pid_t) {
        guard observers[pid] == nil else { return }
        let createCb = self.createCallback
        let destroyCb = self.destroyCallback
        if let obs = AppWindowObserver(pid: pid,
                                       onCreate: { element in createCb(element, pid) },
                                       onDestroy: { element in destroyCb(element, pid) }) {
            observers[pid] = obs
        }
    }
}

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

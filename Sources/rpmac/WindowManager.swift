import Foundation
import CoreGraphics

/// The core window manager state — manages frames and window assignments
class WindowManager {
    var root: Frame
    var focused: Frame
    private var lastWindow: WindowRef?
    let overlay = Overlay()

    /// Windows not currently assigned to any frame
    var unmanaged: [WindowRef] = []

    init() {
        let screen = AccessibilityHelper.screenRect()
        let rect = CGRect(
            x: screen.origin.x,
            y: screen.origin.y,
            width: screen.width,
            height: screen.height
        )
        root = Frame(rect: rect)
        focused = root
    }

    /// Change focus, tracking the previous window for `focusLast`
    private func setFocus(_ frame: Frame) {
        // Track the window we're leaving, not the frame
        if let currentWin = focused.window, focused !== frame || frame.window != currentWin {
            lastWindow = currentWin
        }
        focused = frame
        showFocusOverlay()
    }

    /// Flash an overlay showing what's in the focused frame, and update the border
    private func showFocusOverlay() {
        let leaves = root.leaves
        guard let idx = leaves.firstIndex(where: { $0 === focused }) else { return }
        let winTitle = focused.window?.title ?? "(empty)"
        let msg = "[\(idx)] \(winTitle)"
        overlay.show(message: msg, in: focused.rect)
        overlay.showBorder(around: focused.rect)
    }

    /// Switch to the last window (ratpoison's "last").
    /// If the window is in another frame, focus that frame.
    /// If the window is in the unmanaged pool, swap it into the current frame.
    func focusLast() {
        guard let lastWin = lastWindow else {
            print("No previous window")
            return
        }

        // Is it in a frame?
        if let frame = root.leaves.first(where: { $0.window == lastWin }) {
            setFocus(frame)
            focused.window?.raise()
            return
        }

        // Is it in the unmanaged pool? Swap it into the current frame.
        if let idx = unmanaged.firstIndex(where: { $0 == lastWin }) {
            let win = unmanaged.remove(at: idx)
            if let current = focused.window {
                unmanaged.insert(current, at: 0)
            }
            focused.content = .window(win)
            applyLayout()
            return
        }

        print("Previous window no longer exists")
        lastWindow = nil
    }

    // MARK: - Auto-capture

    /// Capture all existing windows. First one goes into the root frame,
    /// the rest go into the unmanaged pool.
    func captureAllWindows() {
        let windows = AccessibilityHelper.allWindows()
        print("Found \(windows.count) windows")

        guard let first = windows.first else { return }

        focused.content = .window(first)

        for win in windows.dropFirst() {
            unmanaged.append(win)
        }

        applyLayout()
    }

    // MARK: - Frame operations

    /// Split the focused frame horizontally (left | right).
    /// Current window stays in the left frame, next unmanaged window goes right.
    func splitHorizontal() {
        guard focused.isLeaf else { return }
        let (left, right) = focused.split(direction: .horizontal)
        setFocus(left)

        // Pull next unmanaged window into the new frame
        if !unmanaged.isEmpty {
            right.content = .window(unmanaged.removeFirst())
        }

        applyLayout()
    }

    /// Split the focused frame vertically (top / bottom).
    /// Current window stays in the top frame, next unmanaged window goes bottom.
    func splitVertical() {
        guard focused.isLeaf else { return }
        let (top, bottom) = focused.split(direction: .vertical)
        setFocus(top)

        if !unmanaged.isEmpty {
            bottom.content = .window(unmanaged.removeFirst())
        }

        applyLayout()
    }

    /// Remove the focused frame, its sibling takes over.
    /// The window in the removed frame goes to the unmanaged pool.
    func removeFrame() {
        // Save the window before removing
        if let win = focused.window {
            unmanaged.insert(win, at: 0)
            focused.content = .empty
        }

        if let newFocus = focused.remove() {
            let target = newFocus.isLeaf ? newFocus : (newFocus.leaves.first ?? newFocus)
            setFocus(target)
            applyLayout()
        }
    }

    /// Remove all frames except the focused one (like ratpoison's "only")
    func only() {
        // Collect all windows from other frames into unmanaged
        for leaf in root.leaves where leaf !== focused {
            if let win = leaf.window {
                unmanaged.append(win)
            }
        }

        // Reset to a single frame with the focused window's content
        let currentContent = focused.content
        let screen = AccessibilityHelper.screenRect()
        root = Frame(rect: CGRect(
            x: screen.origin.x, y: screen.origin.y,
            width: screen.width, height: screen.height
        ))
        root.content = currentContent
        setFocus(root)
        applyLayout()
    }

    /// Focus the next leaf frame
    func focusNext() {
        let leaves = root.leaves
        guard let idx = leaves.firstIndex(where: { $0 === focused }) else { return }
        let next = (idx + 1) % leaves.count
        setFocus(leaves[next])
        focused.window?.raise()
    }

    /// Focus the previous leaf frame
    func focusPrev() {
        let leaves = root.leaves
        guard let idx = leaves.firstIndex(where: { $0 === focused }) else { return }
        let prev = (idx - 1 + leaves.count) % leaves.count
        setFocus(leaves[prev])
        focused.window?.raise()
    }

    /// Swap the window in the focused frame with the next frame's window
    func swapNext() {
        let leaves = root.leaves
        guard let idx = leaves.firstIndex(where: { $0 === focused }) else { return }
        let next = (idx + 1) % leaves.count

        let tmp = leaves[idx].content
        leaves[idx].content = leaves[next].content
        leaves[next].content = tmp

        applyLayout()
    }

    // MARK: - Window management

    /// Cycle through windows in the focused frame (swap current with next unmanaged)
    func nextWindowInFrame() {
        guard !unmanaged.isEmpty else {
            print("No other windows")
            return
        }

        if let current = focused.window {
            lastWindow = current
            unmanaged.append(current)
        }

        let win = unmanaged.removeFirst()
        focused.content = .window(win)
        applyLayout()
    }

    /// Cycle to the previous window in the unmanaged pool (reverse of nextWindowInFrame)
    func prevWindowInFrame() {
        guard !unmanaged.isEmpty else {
            print("No other windows")
            return
        }

        if let current = focused.window {
            lastWindow = current
            unmanaged.insert(current, at: 0)
        }

        let win = unmanaged.removeLast()
        focused.content = .window(win)
        applyLayout()
    }

    /// Pull the focused (frontmost) macOS window into the current frame
    func captureWindow() {
        guard let win = AccessibilityHelper.focusedWindow() else {
            print("No focused window to capture")
            return
        }

        // Remove from any existing frame
        for leaf in root.leaves {
            if leaf.window == win {
                leaf.content = .empty
            }
        }

        // Remove from unmanaged
        unmanaged.removeAll { $0 == win }

        // Put current frame's window back into unmanaged
        if let current = focused.window {
            unmanaged.insert(current, at: 0)
        }

        focused.content = .window(win)
        applyLayout()
    }

    /// Release the window in the focused frame (stop managing it)
    func releaseWindow() {
        if let win = focused.window {
            unmanaged.append(win)
        }
        focused.content = .empty
    }

    // MARK: - Layout

    /// Apply the current frame tree layout to all managed windows
    func applyLayout() {
        for leaf in root.leaves {
            if let win = leaf.window {
                win.moveResize(to: leaf.rect)
                if leaf === focused {
                    win.raise()
                }
            }
        }
        overlay.showBorder(around: focused.rect)
    }

    /// Recalculate everything (e.g. after screen size change)
    func rescreen() {
        let screen = AccessibilityHelper.screenRect()
        root.rect = CGRect(
            x: screen.origin.x,
            y: screen.origin.y,
            width: screen.width,
            height: screen.height
        )
        root.recalculateRects()
        applyLayout()
    }

    // MARK: - Info

    func printStatus() {
        let leaves = root.leaves
        print("Frames: \(leaves.count)")
        for (i, leaf) in leaves.enumerated() {
            let marker = (leaf === focused) ? " *" : ""
            let winTitle = leaf.window?.title ?? "(empty)"
            print("  [\(i)\(marker)] \(Int(leaf.rect.width))x\(Int(leaf.rect.height))+\(Int(leaf.rect.origin.x))+\(Int(leaf.rect.origin.y)) — \(winTitle)")
        }
        print("Unmanaged: \(unmanaged.count)")
    }
}

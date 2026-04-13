import Foundation
import CoreGraphics
import AppKit

/// Per-screen state: each screen has its own frame tree
class ScreenState {
    let screenIndex: Int
    var rect: CGRect
    var root: Frame
    var focused: Frame

    init(screenIndex: Int, rect: CGRect) {
        self.screenIndex = screenIndex
        self.rect = rect
        self.root = Frame(rect: rect)
        self.focused = root
    }
}

/// The core window manager state — manages frames and window assignments
class WindowManager {
    var screens: [ScreenState] = []
    var currentScreenIndex: Int = 0
    private var lastWindow: WindowRef?
    let overlay = Overlay()
    let commandPrompt = CommandPrompt()

    /// Windows not currently assigned to any frame
    var unmanaged: [WindowRef] = []

    /// Current screen state
    var current: ScreenState { screens[currentScreenIndex] }

    /// Convenience: root frame of current screen
    var root: Frame { current.root }

    /// Convenience: focused frame of current screen
    var focused: Frame {
        get { current.focused }
        set { current.focused = newValue }
    }

    // MARK: - Undo/Redo

    private struct Snapshot {
        let screenStates: [(root: Frame, focusedLeafIndex: Int)]
        let currentScreenIndex: Int
        let unmanaged: [WindowRef]
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let maxUndoLevels = 50

    private func saveSnapshot() {
        let states = screens.map { s in
            let (clonedRoot, focusIdx) = Frame.deepCopy(root: s.root, focused: s.focused)
            return (root: clonedRoot, focusedLeafIndex: focusIdx)
        }
        let snap = Snapshot(screenStates: states, currentScreenIndex: currentScreenIndex, unmanaged: unmanaged)
        undoStack.append(snap)
        if undoStack.count > maxUndoLevels { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func captureCurrentSnapshot() -> Snapshot {
        let states = screens.map { s in
            let (clonedRoot, focusIdx) = Frame.deepCopy(root: s.root, focused: s.focused)
            return (root: clonedRoot, focusedLeafIndex: focusIdx)
        }
        return Snapshot(screenStates: states, currentScreenIndex: currentScreenIndex, unmanaged: unmanaged)
    }

    private func restore(_ snap: Snapshot) {
        for (i, state) in snap.screenStates.enumerated() where i < screens.count {
            screens[i].root = state.root
            let leaves = state.root.leaves
            let idx = min(state.focusedLeafIndex, leaves.count - 1)
            screens[i].focused = leaves[max(idx, 0)]
        }
        currentScreenIndex = min(snap.currentScreenIndex, screens.count - 1)
        unmanaged = snap.unmanaged
        applyAllLayouts()
    }

    func undo() {
        guard let snap = undoStack.popLast() else {
            print("Nothing to undo")
            return
        }
        redoStack.append(captureCurrentSnapshot())
        restore(snap)
        print("Undo")
    }

    func redo() {
        guard let snap = redoStack.popLast() else {
            print("Nothing to redo")
            return
        }
        undoStack.append(captureCurrentSnapshot())
        restore(snap)
        print("Redo")
    }

    // MARK: - Init

    init() {
        let allScreens = AccessibilityHelper.allScreenRects()
        if allScreens.isEmpty {
            let rect = AccessibilityHelper.screenRect()
            screens = [ScreenState(screenIndex: 0, rect: rect)]
        } else {
            screens = allScreens.enumerated().map { (i, sr) in
                ScreenState(screenIndex: i, rect: sr.rect)
            }
        }
        currentScreenIndex = 0
        print("Screens: \(screens.count)")
        for (i, s) in screens.enumerated() {
            print("  [\(i)] \(Int(s.rect.width))x\(Int(s.rect.height))+\(Int(s.rect.origin.x))+\(Int(s.rect.origin.y))")
        }
    }

    // MARK: - Focus helpers

    private func setFocus(_ frame: Frame) {
        if let currentWin = focused.window, focused !== frame || frame.window != currentWin {
            lastWindow = currentWin
        }
        focused = frame
        showFocusOverlay()
    }

    private func showFocusOverlay() {
        let leaves = root.leaves
        guard let idx = leaves.firstIndex(where: { $0 === focused }) else { return }
        let winTitle = focused.window?.title ?? "(empty)"
        let screenLabel = screens.count > 1 ? "S\(currentScreenIndex):" : ""
        let msg = "\(screenLabel)[\(idx)] \(winTitle)"
        overlay.show(message: msg, in: focused.rect)
        overlay.showBorder(around: focused.rect)
    }

    /// All leaf frames across all screens
    private var allLeaves: [Frame] {
        screens.flatMap { $0.root.leaves }
    }

    // MARK: - Screen navigation

    /// Focus the next screen
    func focusNextScreen() {
        guard screens.count > 1 else { return }
        currentScreenIndex = (currentScreenIndex + 1) % screens.count
        setFocus(focused)
        focused.window?.raise()
    }

    /// Focus the previous screen
    func focusPrevScreen() {
        guard screens.count > 1 else { return }
        currentScreenIndex = (currentScreenIndex - 1 + screens.count) % screens.count
        setFocus(focused)
        focused.window?.raise()
    }

    /// Move the window in the focused frame to the next screen's focused frame
    func moveWindowToNextScreen() {
        guard screens.count > 1 else { return }
        guard let win = focused.window else { return }

        // Remove from current frame
        focused.content = .empty
        if !unmanaged.isEmpty {
            focused.content = .window(unmanaged.removeFirst())
        }

        // Switch to next screen
        let nextIdx = (currentScreenIndex + 1) % screens.count
        let target = screens[nextIdx]

        // Put current window of target into unmanaged, put our window there
        if let targetWin = target.focused.window {
            unmanaged.append(targetWin)
        }
        target.focused.content = .window(win)

        currentScreenIndex = nextIdx
        applyAllLayouts()
        showFocusOverlay()
    }

    // MARK: - Last window

    func focusLast() {
        guard let lastWin = lastWindow else {
            print("No previous window")
            return
        }

        // Check all screens for the window
        for (i, screen) in screens.enumerated() {
            if let frame = screen.root.leaves.first(where: { $0.window == lastWin }) {
                currentScreenIndex = i
                setFocus(frame)
                focused.window?.raise()
                return
            }
        }

        // Check unmanaged pool
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

    func captureAllWindows() {
        let windows = AccessibilityHelper.allWindows()
        print("Found \(windows.count) windows")

        // Put the first window on the first screen, rest in unmanaged
        guard let first = windows.first else { return }
        screens[0].focused.content = .window(first)

        for win in windows.dropFirst() {
            unmanaged.append(win)
        }

        applyAllLayouts()
    }

    // MARK: - Frame operations

    func splitHorizontal() {
        guard focused.isLeaf else { return }
        saveSnapshot()
        let (left, right) = focused.split(direction: .horizontal)
        setFocus(left)
        if !unmanaged.isEmpty {
            right.content = .window(unmanaged.removeFirst())
        }
        applyLayout()
    }

    func splitVertical() {
        guard focused.isLeaf else { return }
        saveSnapshot()
        let (top, bottom) = focused.split(direction: .vertical)
        setFocus(top)
        if !unmanaged.isEmpty {
            bottom.content = .window(unmanaged.removeFirst())
        }
        applyLayout()
    }

    func removeFrame() {
        saveSnapshot()
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

    func only() {
        saveSnapshot()
        for leaf in root.leaves where leaf !== focused {
            if let win = leaf.window {
                unmanaged.append(win)
            }
        }
        let currentContent = focused.content
        current.root = Frame(rect: current.rect)
        current.root.content = currentContent
        setFocus(current.root)
        applyLayout()
    }

    func focusNext() {
        let leaves = root.leaves
        guard let idx = leaves.firstIndex(where: { $0 === focused }) else { return }
        let next = (idx + 1) % leaves.count
        setFocus(leaves[next])
        focused.window?.raise()
    }

    func focusPrev() {
        let leaves = root.leaves
        guard let idx = leaves.firstIndex(where: { $0 === focused }) else { return }
        let prev = (idx - 1 + leaves.count) % leaves.count
        setFocus(leaves[prev])
        focused.window?.raise()
    }

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

    func captureWindow() {
        guard let win = AccessibilityHelper.focusedWindow() else {
            print("No focused window to capture")
            return
        }
        // Remove from any frame on any screen
        for screen in screens {
            for leaf in screen.root.leaves {
                if leaf.window == win { leaf.content = .empty }
            }
        }
        unmanaged.removeAll { $0 == win }
        if let current = focused.window {
            unmanaged.insert(current, at: 0)
        }
        focused.content = .window(win)
        applyLayout()
    }

    func releaseWindow() {
        if let win = focused.window {
            unmanaged.append(win)
        }
        focused.content = .empty
    }

    func killWindow() {
        guard let win = focused.window else {
            print("No window in focused frame")
            return
        }
        let app = NSRunningApplication(processIdentifier: win.pid)
        focused.content = .empty
        if !unmanaged.isEmpty {
            focused.content = .window(unmanaged.removeFirst())
        }
        app?.terminate()
        applyLayout()
    }

    // MARK: - Layout

    /// Apply layout for current screen only
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

    /// Apply layout for all screens
    func applyAllLayouts() {
        for screen in screens {
            for leaf in screen.root.leaves {
                if let win = leaf.window {
                    win.moveResize(to: leaf.rect)
                }
            }
        }
        focused.window?.raise()
        overlay.showBorder(around: focused.rect)
    }

    func rescreen() {
        let allScreens = AccessibilityHelper.allScreenRects()
        for (i, sr) in allScreens.enumerated() where i < screens.count {
            screens[i].rect = sr.rect
            screens[i].root.rect = sr.rect
            screens[i].root.recalculateRects()
        }
        applyAllLayouts()
    }

    // MARK: - Info

    func printStatus() {
        for (si, screen) in screens.enumerated() {
            let marker = si == currentScreenIndex ? " *" : ""
            print("Screen \(si)\(marker): \(Int(screen.rect.width))x\(Int(screen.rect.height))")
            let leaves = screen.root.leaves
            for (i, leaf) in leaves.enumerated() {
                let fmarker = (leaf === screen.focused) ? " *" : ""
                let winTitle = leaf.window?.title ?? "(empty)"
                print("  [\(i)\(fmarker)] \(Int(leaf.rect.width))x\(Int(leaf.rect.height))+\(Int(leaf.rect.origin.x))+\(Int(leaf.rect.origin.y)) — \(winTitle)")
            }
        }
        print("Unmanaged: \(unmanaged.count)")
    }
}

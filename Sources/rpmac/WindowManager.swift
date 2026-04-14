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

    /// When true, warp mouse cursor to the center of the focused window on raise
    var warp: Bool = false

    /// When true, clicking on a frame focuses it
    var clickToFocus: Bool = false

    /// Windows not currently assigned to any frame
    var unmanaged: [WindowRef] = []

    // MARK: - Window numbering

    /// Maps window number → window ref. Every managed window gets a persistent number.
    private var windowNumbers: [Int: WindowRef] = [:]

    /// Assign the lowest available number to a window. Returns the assigned number.
    @discardableResult
    func assignNumber(to win: WindowRef) -> Int {
        // Don't double-assign
        if let existing = windowNumbers.first(where: { $0.value == win }) {
            return existing.key
        }
        var n = 0
        while windowNumbers[n] != nil { n += 1 }
        windowNumbers[n] = win
        return n
    }

    /// Remove the number for a window.
    func freeNumber(for win: WindowRef) {
        if let key = windowNumbers.first(where: { $0.value == win })?.key {
            windowNumbers.removeValue(forKey: key)
        }
    }

    /// Get the number for a window, if it has one.
    func number(for win: WindowRef) -> Int? {
        windowNumbers.first(where: { $0.value == win })?.key
    }

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
        guard root.leaves.contains(where: { $0 === focused }) else { return }
        let winTitle = focused.window?.title ?? "(empty)"
        let winNum = focused.window.flatMap({ number(for: $0) }).map({ "\($0)" }) ?? "-"
        let screenLabel = screens.count > 1 ? "S\(currentScreenIndex):" : ""
        let msg = "\(screenLabel)\(winNum) \(winTitle)"
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
        focused.window?.raise(warp: warp)
    }

    /// Focus the previous screen
    func focusPrevScreen() {
        guard screens.count > 1 else { return }
        currentScreenIndex = (currentScreenIndex - 1 + screens.count) % screens.count
        setFocus(focused)
        focused.window?.raise(warp: warp)
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

    // MARK: - Directional focus

    enum Direction { case left, right, up, down }

    func focusDirection(_ dir: Direction) {
        let from = focused.rect

        // Collect all candidate leaves across all screens with their screen index
        var candidates: [(frame: Frame, screenIndex: Int)] = []
        for (i, screen) in screens.enumerated() {
            for leaf in screen.root.leaves where leaf !== focused {
                let r = leaf.rect
                let overlaps: Bool
                let closer: Bool
                switch dir {
                case .right:
                    overlaps = r.minY < from.maxY && r.maxY > from.minY
                    closer = r.minX >= from.maxX - 1
                case .left:
                    overlaps = r.minY < from.maxY && r.maxY > from.minY
                    closer = r.maxX <= from.minX + 1
                case .down:
                    overlaps = r.minX < from.maxX && r.maxX > from.minX
                    closer = r.minY >= from.maxY - 1
                case .up:
                    overlaps = r.minX < from.maxX && r.maxX > from.minX
                    closer = r.maxY <= from.minY + 1
                }
                if overlaps && closer {
                    candidates.append((frame: leaf, screenIndex: i))
                }
            }
        }

        // Pick the closest candidate
        let best = candidates.min(by: { a, b in
            distance(from: from, to: a.frame.rect, dir: dir) < distance(from: from, to: b.frame.rect, dir: dir)
        })

        if let best = best {
            currentScreenIndex = best.screenIndex
            setFocus(best.frame)
            focused.window?.raise(warp: warp)
        }
    }

    private func distance(from: CGRect, to: CGRect, dir: Direction) -> CGFloat {
        switch dir {
        case .right: return to.minX - from.maxX
        case .left:  return from.minX - to.maxX
        case .down:  return to.minY - from.maxY
        case .up:    return from.minY - to.maxY
        }
    }

    func exchangeDirection(_ dir: Direction) {
        let from = focused.rect

        var candidates: [(frame: Frame, screenIndex: Int)] = []
        for (i, screen) in screens.enumerated() {
            for leaf in screen.root.leaves where leaf !== focused {
                let r = leaf.rect
                let overlaps: Bool
                let closer: Bool
                switch dir {
                case .right:
                    overlaps = r.minY < from.maxY && r.maxY > from.minY
                    closer = r.minX >= from.maxX - 1
                case .left:
                    overlaps = r.minY < from.maxY && r.maxY > from.minY
                    closer = r.maxX <= from.minX + 1
                case .down:
                    overlaps = r.minX < from.maxX && r.maxX > from.minX
                    closer = r.minY >= from.maxY - 1
                case .up:
                    overlaps = r.minX < from.maxX && r.maxX > from.minX
                    closer = r.maxY <= from.minY + 1
                }
                if overlaps && closer {
                    candidates.append((frame: leaf, screenIndex: i))
                }
            }
        }

        if let best = candidates.min(by: { a, b in
            distance(from: from, to: a.frame.rect, dir: dir) < distance(from: from, to: b.frame.rect, dir: dir)
        }) {
            let tmp = focused.content
            focused.content = best.frame.content
            best.frame.content = tmp
            currentScreenIndex = best.screenIndex
            setFocus(best.frame)
            applyAllLayouts()
        }
    }

    // MARK: - Last window

    func focusLast() {
        guard let lastWin = lastWindow else {
            print("No previous window")
            return
        }

        // Save current window so we can toggle back
        let previousWindow = focused.window

        // Check all screens for the window
        for (i, screen) in screens.enumerated() {
            if let frame = screen.root.leaves.first(where: { $0.window == lastWin }) {
                currentScreenIndex = i
                lastWindow = previousWindow
                setFocus(frame)
                focused.window?.raise(warp: warp)
                return
            }
        }

        // Check unmanaged pool
        if let idx = unmanaged.firstIndex(where: { $0 == lastWin }) {
            let win = unmanaged.remove(at: idx)
            if let current = focused.window {
                unmanaged.insert(current, at: 0)
            }
            lastWindow = previousWindow
            focused.content = .window(win)
            applyLayout()
            return
        }

        print("Previous window no longer exists")
        lastWindow = nil
    }

    // MARK: - Window creation watcher

    private var watcher: WindowCreationWatcher?

    func startWatchingForNewWindows() {
        // Snapshot all existing AX window elements so we can ignore them in the observer
        var knownElements: [AXUIElement] = []
        for screen in screens {
            for leaf in screen.root.leaves {
                if let w = leaf.window { knownElements.append(w.element) }
            }
        }
        for w in unmanaged { knownElements.append(w.element) }

        let w = WindowCreationWatcher(
            onCreate: { [weak self] element, pid in

                guard let self = self else { return }

                // Skip pre-existing windows
                if knownElements.contains(where: { CFEqual($0, element) }) { return }

                let wref = WindowRef(pid: pid, element: element)
                guard wref.isNormalWindow else { return }

                // Skip if we already manage this window
                for screen in self.screens {
                    for leaf in screen.root.leaves {
                        if leaf.window == wref { return }
                    }
                }
                if self.unmanaged.contains(where: { $0 == wref }) { return }

                let n = self.assignNumber(to: wref)
                print("New window #\(n): \(wref.title ?? "(untitled)")")

                // Place into focused frame, pushing current window to unmanaged
                if let current = self.focused.window {
                    self.unmanaged.insert(current, at: 0)
                }
                self.focused.content = .window(wref)
                self.applyLayout()
            },
            onDestroy: { [weak self] element, pid in
                guard let self = self else { return }
                let wref = WindowRef(pid: pid, element: element)

                self.freeNumber(for: wref)

                // Remove from frames
                for screen in self.screens {
                    for leaf in screen.root.leaves {
                        if leaf.window == wref {
                            leaf.content = .empty
                            // Fill from unmanaged if available
                            if !self.unmanaged.isEmpty {
                                leaf.content = .window(self.unmanaged.removeFirst())
                            }
                            print("Window destroyed (was in frame): \(wref.title ?? "(untitled)")")
                            self.applyAllLayouts()
                            return
                        }
                    }
                }

                // Remove from unmanaged
                let countBefore = self.unmanaged.count
                self.unmanaged.removeAll(where: { $0 == wref })
                if self.unmanaged.count < countBefore {
                    print("Window destroyed (was unmanaged): \(wref.title ?? "(untitled)")")
                }

                // Clear lastWindow if it was this window
                if self.lastWindow == wref {
                    self.lastWindow = nil
                }
            },
            onFocus: { [weak self] element, pid in
                guard let self = self else { return }
                let wref = WindowRef(pid: pid, element: element)

                // Find the frame holding this window — if found, update focus
                for (i, screen) in self.screens.enumerated() {
                    if let frame = screen.root.leaves.first(where: { $0.window == wref }) {
                        if frame !== self.focused || i != self.currentScreenIndex {
                            self.currentScreenIndex = i
                            self.setFocus(frame)
                        }
                        return
                    }
                }
                // Window not in any frame — ignore (user can explicitly capture)
            }
        )
        w.start()
        self.watcher = w
    }

    // MARK: - Auto-capture

    func captureAllWindows() {
        let windows = AccessibilityHelper.allWindows()
        print("Found \(windows.count) windows")

        // Assign each window to the screen it's physically on.
        // First window per screen goes into the focused frame, rest into unmanaged.
        var placed = Set<Int>() // screen indices that already have a window
        var remaining: [WindowRef] = []

        for win in windows {
            assignNumber(to: win)
            if let winFrame = win.frame {
                let winCenter = CGPoint(x: winFrame.midX, y: winFrame.midY)
                if let screenIdx = screens.firstIndex(where: { $0.rect.contains(winCenter) }),
                   !placed.contains(screenIdx) {
                    screens[screenIdx].focused.content = .window(win)
                    placed.insert(screenIdx)
                    continue
                }
            }
            remaining.append(win)
        }

        unmanaged.append(contentsOf: remaining)
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
        focused.window?.raise(warp: warp)
    }

    func focusPrev() {
        let leaves = root.leaves
        guard let idx = leaves.firstIndex(where: { $0 === focused }) else { return }
        let prev = (idx - 1 + leaves.count) % leaves.count
        setFocus(leaves[prev])
        focused.window?.raise(warp: warp)
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
        assignNumber(to: win)
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
        freeNumber(for: win)
        let app = NSRunningApplication(processIdentifier: win.pid)
        focused.content = .empty
        if !unmanaged.isEmpty {
            focused.content = .window(unmanaged.removeFirst())
        }
        app?.terminate()
        applyLayout()
    }

    // MARK: - Select by number

    func selectWindow(number n: Int) {
        guard let win = windowNumbers[n] else {
            print("No window with number \(n)")
            return
        }

        // Already in the focused frame? Nothing to do.
        if focused.window == win { return }

        // Check if it's in a frame on any screen — swap with focused
        for screen in screens {
            if let frame = screen.root.leaves.first(where: { $0.window == win }) {
                let currentWin = focused.window
                focused.content = .window(win)
                frame.content = currentWin.map { .window($0) } ?? .empty
                setFocus(focused)
                applyAllLayouts()
                return
            }
        }

        // Must be in unmanaged — pull it into the focused frame
        if let idx = unmanaged.firstIndex(where: { $0 == win }) {
            unmanaged.remove(at: idx)
            if let current = focused.window {
                lastWindow = current
                unmanaged.insert(current, at: 0)
            }
            focused.content = .window(win)
            applyLayout()
        }
    }

    func windowList() -> String {
        var lines: [String] = []
        let sorted = windowNumbers.sorted(by: { $0.key < $1.key })
        for (n, win) in sorted {
            let title = win.title ?? "(untitled)"
            let location: String
            if focused.window == win {
                location = "*"
            } else {
                var inFrame = false
                for screen in screens {
                    if screen.root.leaves.contains(where: { $0.window == win }) {
                        inFrame = true
                        break
                    }
                }
                location = inFrame ? "f" : "-"
            }
            lines.append("\(n)\(location) \(title)")
        }
        return lines.joined(separator: "\n")
    }

    func showWindowList() {
        let list = windowList()
        print(list)
        overlay.show(message: list, in: focused.rect)
    }

    // MARK: - Layout

    /// Move mouse to the bottom-right corner of the current screen
    func banish() {
        let rect = current.rect
        let point = CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)
        CGWarpMouseCursorPosition(point)
    }

    /// Apply layout for current screen only
    func applyLayout() {
        for leaf in root.leaves {
            if let win = leaf.window {
                win.moveResize(to: leaf.rect)
                if leaf === focused {
                    win.raise(warp: warp)
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
        focused.window?.raise(warp: warp)
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
                let winNum = leaf.window.flatMap({ number(for: $0) }).map({ "#\($0)" }) ?? ""
                print("  [\(i)\(fmarker)] \(winNum) \(Int(leaf.rect.width))x\(Int(leaf.rect.height))+\(Int(leaf.rect.origin.x))+\(Int(leaf.rect.origin.y)) — \(winTitle)")
            }
        }
        print("Unmanaged: \(unmanaged.count)")
        for win in unmanaged {
            let winNum = number(for: win).map({ "#\($0)" }) ?? "?"
            print("  \(winNum) \(win.title ?? "(untitled)")")
        }
    }
}

import Foundation
import CoreGraphics

/// Direction of a frame split
enum SplitDirection {
    case horizontal // left | right
    case vertical   // top / bottom
}

/// A node in the frame tree. Either a leaf (holds a window) or an internal node (split into two children).
class Frame {
    var rect: CGRect
    var parent: Frame?
    var content: FrameContent

    init(rect: CGRect, parent: Frame? = nil) {
        self.rect = rect
        self.parent = parent
        self.content = .empty
    }

    enum FrameContent {
        case empty
        case window(WindowRef)
        case split(SplitDirection, Frame, Frame)
    }

    /// Whether this frame is a leaf (no children)
    var isLeaf: Bool {
        switch content {
        case .empty, .window: return true
        case .split: return false
        }
    }

    /// The window in this frame, if any
    var window: WindowRef? {
        switch content {
        case .window(let w): return w
        default: return nil
        }
    }

    /// All leaf frames in tree order
    var leaves: [Frame] {
        switch content {
        case .empty, .window:
            return [self]
        case .split(_, let a, let b):
            return a.leaves + b.leaves
        }
    }

    /// Split this leaf frame in the given direction. The current content goes into the first child.
    func split(direction: SplitDirection) -> (Frame, Frame) {
        let (r1, r2) = Self.splitRect(rect, direction: direction)
        let child1 = Frame(rect: r1, parent: self)
        let child2 = Frame(rect: r2, parent: self)

        // Move current content to child1
        child1.content = self.content
        child2.content = .empty

        self.content = .split(direction, child1, child2)
        return (child1, child2)
    }

    /// Remove this leaf frame. Its sibling takes over the parent's space.
    func remove() -> Frame? {
        guard let parent = self.parent else { return nil }

        guard case .split(_, let a, let b) = parent.content else { return nil }

        let sibling = (a === self) ? b : a

        // Sibling takes over parent's rect and position in the tree
        parent.content = sibling.content
        // parent keeps its rect, children will be resized below
        sibling.parent = nil

        // Re-parent sibling's children if it was a split
        if case .split(_, let sa, let sb) = parent.content {
            sa.parent = parent
            sb.parent = parent
        }

        parent.recalculateRects()
        return parent
    }

    /// Recalculate child rects after a resize
    func recalculateRects() {
        guard case .split(let dir, let a, let b) = content else { return }
        let (r1, r2) = Self.splitRect(rect, direction: dir)
        a.rect = r1
        b.rect = r2
        a.recalculateRects()
        b.recalculateRects()
    }

    /// Deep copy the frame tree. Returns (clonedRoot, focusedLeafIndex).
    /// `focusedLeafIndex` is the index in `leaves` of `originalFocused`, or 0 if not found.
    static func deepCopy(root: Frame, focused: Frame) -> (Frame, Int) {
        let cloned = root.clone(parent: nil)
        let origLeaves = root.leaves
        let focusIdx = origLeaves.firstIndex(where: { $0 === focused }) ?? 0
        return (cloned, focusIdx)
    }

    /// Clone this frame and all its children
    private func clone(parent: Frame?) -> Frame {
        let copy = Frame(rect: rect, parent: parent)
        switch content {
        case .empty:
            copy.content = .empty
        case .window(let w):
            copy.content = .window(w)
        case .split(let dir, let a, let b):
            let aCopy = a.clone(parent: copy)
            let bCopy = b.clone(parent: copy)
            copy.content = .split(dir, aCopy, bCopy)
        }
        return copy
    }

    /// Split a rect in half along the given direction
    private static func splitRect(_ rect: CGRect, direction: SplitDirection) -> (CGRect, CGRect) {
        switch direction {
        case .horizontal:
            let w = rect.width / 2
            return (
                CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            )
        case .vertical:
            let h = rect.height / 2
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h),
                CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            )
        }
    }
}

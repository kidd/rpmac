import AppKit

/// A borderless NSView that draws a colored border rect
class BorderView: NSView {
    var borderColor: NSColor = .systemBlue
    var borderWidth: CGFloat = 2

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))
        path.lineWidth = borderWidth
        borderColor.setStroke()
        path.stroke()
    }
}

/// Displays a brief message overlay in the center of a given screen rect,
/// and a persistent border around the focused frame.
class Overlay {
    private var window: NSWindow?
    private var borderWindow: NSWindow?
    private var hideTimer: Timer?

    /// How long the overlay stays visible (seconds)
    var displayDuration: TimeInterval = 0.7

    /// Border appearance (applied to BorderView)
    var borderWidth: CGFloat = 2 {
        didSet { (borderWindow?.contentView as? BorderView)?.borderWidth = borderWidth }
    }
    var borderColor: NSColor = .systemBlue {
        didSet { (borderWindow?.contentView as? BorderView)?.borderColor = borderColor }
    }

    /// Show the focus border around the given rect (persistent until moved)
    func showBorder(around rect: CGRect) {
        let flipped = flipToCocoaCoordinates(rect)

        if borderWindow == nil {
            borderWindow = makeBorderWindow()
        }

        guard let bw = borderWindow else { return }
        bw.setFrame(flipped, display: true)
        (bw.contentView as? BorderView)?.needsDisplay = true
        bw.orderFrontRegardless()
    }

    /// Hide the focus border
    func hideBorder() {
        borderWindow?.orderOut(nil)
    }

    private func makeBorderWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.contentView = BorderView()
        return w
    }

    /// Show a message centered in the given rect (in Accessibility/top-left coordinates)
    func show(message: String, in rect: CGRect) {
        hideTimer?.invalidate()

        let flipped = flipToCocoaCoordinates(rect)

        if let window = window {
            window.orderOut(nil)
            configure(window: window, message: message, screenRect: flipped)
        } else {
            let w = makeWindow()
            configure(window: w, message: message, screenRect: flipped)
            self.window = w
        }

        window?.orderFrontRegardless()

        hideTimer = Timer.scheduledTimer(withTimeInterval: displayDuration, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil

        // Fade out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
            self?.window?.alphaValue = 1
        })
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 50),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        return w
    }

    private func configure(window: NSWindow, message: String, screenRect: NSRect) {
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.sizeToFit()

        let padding: CGFloat = 24
        let bgWidth = label.frame.width + padding * 2
        let bgHeight = label.frame.height + padding

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: bgWidth, height: bgHeight))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10

        label.frame.origin = NSPoint(
            x: (bgWidth - label.frame.width) / 2,
            y: (bgHeight - label.frame.height) / 2
        )
        bg.addSubview(label)

        window.setContentSize(NSSize(width: bgWidth, height: bgHeight))
        window.contentView = bg

        // Center in the target frame
        let x = screenRect.midX - bgWidth / 2
        let y = screenRect.midY - bgHeight / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Convert from Accessibility coordinates (top-left origin) to Cocoa coordinates (bottom-left origin)
    private func flipToCocoaCoordinates(_ rect: CGRect) -> NSRect {
        guard let screen = NSScreen.main else { return NSRect(origin: .zero, size: rect.size) }
        let fullHeight = screen.frame.height
        return NSRect(
            x: rect.origin.x,
            y: fullHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

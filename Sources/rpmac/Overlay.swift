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

    /// Message bar colors (like ratpoison's fgcolor/bgcolor)
    var fgColor: NSColor = .white
    var bgColor: NSColor = NSColor(white: 0.2, alpha: 0.9)

    /// Bar padding
    var barPadding: CGFloat = 24

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
        label.textColor = fgColor
        label.alignment = .center
        label.backgroundColor = .clear
        label.sizeToFit()

        let bgWidth = label.frame.width + barPadding * 2
        let bgHeight = label.frame.height + barPadding

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: bgWidth, height: bgHeight))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = bgColor.cgColor
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

    // MARK: - Cursor indicator (command-wait mode)

    private var cursorWindow: NSWindow?
    private let cursorSize: CGFloat = 20

    func showCursorIndicator() {
        let mousePos = NSEvent.mouseLocation // Cocoa coordinates already
        let rect = NSRect(
            x: mousePos.x - cursorSize / 2,
            y: mousePos.y - cursorSize / 2,
            width: cursorSize,
            height: cursorSize
        )

        if cursorWindow == nil {
            let w = NSWindow(
                contentRect: rect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .screenSaver
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]

            let view = BorderView(frame: NSRect(x: 0, y: 0, width: cursorSize, height: cursorSize))
            view.borderColor = borderColor
            view.borderWidth = borderWidth
            w.contentView = view
            cursorWindow = w
        }

        cursorWindow?.setFrame(rect, display: true)
        if let view = cursorWindow?.contentView as? BorderView {
            view.borderColor = borderColor
            view.borderWidth = borderWidth
            view.needsDisplay = true
        }
        cursorWindow?.orderFrontRegardless()
    }

    func hideCursorIndicator() {
        cursorWindow?.orderOut(nil)
    }

    /// Convert from Accessibility coordinates (top-left origin) to Cocoa coordinates (bottom-left origin).
    /// In multi-monitor setups, the AX coordinate system uses the primary screen's top-left as (0,0).
    /// Cocoa uses the primary screen's bottom-left as (0,0). Both share the same X axis.
    /// The conversion only needs to flip Y using the primary screen's height.
    private func flipToCocoaCoordinates(_ rect: CGRect) -> NSRect {
        // Primary screen is always NSScreen.screens[0]
        guard let primaryScreen = NSScreen.screens.first else {
            return NSRect(origin: .zero, size: rect.size)
        }
        let primaryHeight = primaryScreen.frame.height
        return NSRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

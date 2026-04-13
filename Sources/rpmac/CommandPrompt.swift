import AppKit

/// Borderless window that can become key (receive keyboard input)
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A floating command prompt (like ratpoison's `Ctrl-t :`)
/// Shows a text field with autocomplete for entering commands.
class CommandPrompt: NSObject, NSTextFieldDelegate {
    private var window: NSWindow?
    private var textField: NSTextField?
    private var completionLabel: NSTextField?
    private var onCommand: ((String) -> Void)?

    private let commands = [
        "split-h", "split-v",
        "next", "prev",
        "next-frame", "prev-frame",
        "next-screen", "prev-screen", "move-to-screen",
        "last",
        "swap", "kill",
        "only", "remove",
        "capture", "release",
        "undo", "redo",
        "rescreen", "reload",
        "status",
        "quit",
    ]

    func show(onCommand: @escaping (String) -> Void) {
        self.onCommand = onCommand

        if window == nil {
            setupWindow()
        }

        textField?.stringValue = ""
        completionLabel?.stringValue = ""
        // Activate our app and make window key so text field receives input
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textField)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func setupWindow() {
        let width: CGFloat = 400
        let height: CGFloat = 32

        // Position at center-top of screen
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - 200

        let w = KeyableWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8

        // ":" prefix label
        let prefix = NSTextField(labelWithString: ":")
        prefix.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        prefix.textColor = .black
        prefix.frame = NSRect(x: 8, y: 4, width: 16, height: 24)
        bg.addSubview(prefix)

        // Input text field
        let tf = NSTextField(frame: NSRect(x: 24, y: 4, width: width - 160, height: 24))
        tf.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        tf.textColor = .black
        tf.backgroundColor = .clear
        tf.isBordered = false
        tf.focusRingType = .none
        tf.isEditable = true
        tf.isSelectable = true
        tf.delegate = self
        tf.target = self
        tf.action = #selector(textFieldAction(_:))
        bg.addSubview(tf)
        self.textField = tf

        // Completion hint label
        let cl = NSTextField(labelWithString: "")
        cl.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        cl.textColor = NSColor.white.withAlphaComponent(0.4)
        cl.frame = NSRect(x: width - 132, y: 5, width: 124, height: 22)
        cl.alignment = .right
        bg.addSubview(cl)
        self.completionLabel = cl

        w.contentView = bg
        self.window = w
    }

    @objc private func textFieldAction(_ sender: NSTextField) {
        let cmd = sender.stringValue.trimmingCharacters(in: .whitespaces)
        hide()
        onCommand?(cmd)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = textField else { return }
        let typed = tf.stringValue
        updateCompletion(for: typed)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape — dismiss
            hide()
            onCommand?("")
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            // Tab — accept completion
            if let completion = currentCompletion() {
                textField?.stringValue = completion
                completionLabel?.stringValue = ""
            }
            return true
        }
        return false
    }

    private func updateCompletion(for typed: String) {
        guard !typed.isEmpty else {
            completionLabel?.stringValue = ""
            return
        }
        if let match = commands.first(where: { $0.hasPrefix(typed) && $0 != typed }) {
            let rest = String(match.dropFirst(typed.count))
            completionLabel?.stringValue = rest
        } else {
            completionLabel?.stringValue = ""
        }
    }

    private func currentCompletion() -> String? {
        guard let typed = textField?.stringValue, !typed.isEmpty else { return nil }
        return commands.first(where: { $0.hasPrefix(typed) && $0 != typed })
    }
}

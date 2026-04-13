import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// Ratpoison-style prefix key + command key bindings using CGEventTap.
/// Default prefix: Ctrl-t (like ratpoison)
///
/// Both `Ctrl-t <key>` and `Ctrl-t Ctrl-<key>` work (holding ctrl throughout).
class KeyBinder {
    let wm: WindowManager
    var commandServer: CommandServer?
    private var waitingForCommand = false
    private var promptActive = false
    private var eventTap: CFMachPort?

    // Prefix key: Ctrl-t
    var prefixKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_T)

    // Command bindings: key -> action
    struct Binding {
        let key: CGKeyCode
        let action: (WindowManager) -> Void
        let description: String
    }

    lazy var bindings: [CGKeyCode: Binding] = {
        return [
            // Split
            CGKeyCode(kVK_ANSI_S): Binding(key: CGKeyCode(kVK_ANSI_S), action: { $0.splitVertical() }, description: "split vertical"),
            CGKeyCode(kVK_ANSI_V): Binding(key: CGKeyCode(kVK_ANSI_V), action: { $0.splitHorizontal() }, description: "split horizontal"),

            // Window cycling (next/prev window in current frame)
            CGKeyCode(kVK_ANSI_N): Binding(key: CGKeyCode(kVK_ANSI_N), action: { $0.nextWindowInFrame() }, description: "next window"),
            CGKeyCode(kVK_ANSI_P): Binding(key: CGKeyCode(kVK_ANSI_P), action: { $0.prevWindowInFrame() }, description: "prev window"),
            CGKeyCode(kVK_Space):  Binding(key: CGKeyCode(kVK_Space),  action: { $0.nextWindowInFrame() }, description: "next window"),

            // Frame navigation
            CGKeyCode(kVK_Tab):    Binding(key: CGKeyCode(kVK_Tab),    action: { $0.focusNext() }, description: "next frame"),

            // Frame management
            CGKeyCode(kVK_ANSI_Q): Binding(key: CGKeyCode(kVK_ANSI_Q), action: { $0.only() }, description: "only (remove all other frames)"),
            CGKeyCode(kVK_ANSI_O): Binding(key: CGKeyCode(kVK_ANSI_O), action: { $0.focusNext() }, description: "next frame"),

            // Window/frame swap
            CGKeyCode(kVK_ANSI_W): Binding(key: CGKeyCode(kVK_ANSI_W), action: { $0.swapNext() }, description: "swap with next frame"),
            CGKeyCode(kVK_ANSI_K): Binding(key: CGKeyCode(kVK_ANSI_K), action: { $0.killWindow() }, description: "kill window"),

            // Screen navigation
            CGKeyCode(kVK_ANSI_Period): Binding(key: CGKeyCode(kVK_ANSI_Period), action: { $0.focusNextScreen() }, description: "next screen"),
            CGKeyCode(kVK_ANSI_Comma):  Binding(key: CGKeyCode(kVK_ANSI_Comma),  action: { $0.focusPrevScreen() }, description: "prev screen"),
            CGKeyCode(kVK_ANSI_M):      Binding(key: CGKeyCode(kVK_ANSI_M),      action: { $0.moveWindowToNextScreen() }, description: "move window to next screen"),

            // Undo/Redo
            CGKeyCode(kVK_ANSI_U): Binding(key: CGKeyCode(kVK_ANSI_U), action: { $0.undo() }, description: "undo"),
            CGKeyCode(kVK_ANSI_R): Binding(key: CGKeyCode(kVK_ANSI_R), action: { $0.redo() }, description: "redo"),

            // Info
            CGKeyCode(kVK_ANSI_I): Binding(key: CGKeyCode(kVK_ANSI_I), action: { $0.printStatus() }, description: "show status"),
        ]
    }()

    init(wm: WindowManager) {
        self.wm = wm
    }

    func setPrefixKey(_ keyCode: CGKeyCode) {
        prefixKeyCode = keyCode
    }

    func addBinding(keyCode: CGKeyCode, keyName: String, command: String, server: CommandServer) {
        let b = Binding(key: keyCode, action: { _ in server.handleCommand(command) }, description: command)
        bindings[keyCode] = b
    }

    func removeBinding(keyCode: CGKeyCode) {
        bindings.removeValue(forKey: keyCode)
    }

    func start() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let binder = Unmanaged<KeyBinder>.fromOpaque(refcon).takeUnretainedValue()
                return binder.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            print("Failed to create event tap. Are accessibility permissions granted?")
            return false
        }

        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let enabled = CGEvent.tapIsEnabled(tap: tap)
        print("Event tap created, enabled: \(enabled)")
        if !enabled {
            print("⚠ Event tap is disabled. Check Input Monitoring permission:")
            print("  System Settings → Privacy & Security → Input Monitoring")
            print("  Add and enable your terminal (e.g. Alacritty).")
        }
        print("Keybindings active. Prefix: Ctrl-t")
        printBindings()
        return true
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it gets disabled (Chrome and other apps can cause this)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("⚠ Event tap was disabled (type=\(type.rawValue)), re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // When the command prompt is active, let all keys through to it
        if promptActive {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        let ctrlHeld = flags.contains(.maskControl)

        if waitingForCommand {
            waitingForCommand = false

            // Ctrl-t Ctrl-t: "last" — switch to previously focused frame
            // Ctrl-t t: pass a real t through to the app
            if keyCode == prefixKeyCode {
                if ctrlHeld {
                    print(">> last")
                    wm.focusLast()
                    wm.printStatus()
                    return nil
                } else {
                    // Pass through as plain t
                    return Unmanaged.passUnretained(event)
                }
            }

            // Shift-Tab → prev frame
            if keyCode == CGKeyCode(kVK_Tab) && flags.contains(.maskShift) {
                print(">> prev frame")
                wm.focusPrev()
                wm.printStatus()
                return nil
            }

            // : (Shift-;) → command prompt
            if keyCode == CGKeyCode(kVK_ANSI_Semicolon) && flags.contains(.maskShift) {
                print(">> command prompt")
                showCommandPrompt()
                return nil
            }

            // Look up binding by keyCode only — works whether ctrl is held or not
            if let binding = bindings[keyCode] {
                print(">> \(binding.description)")
                // Execute synchronously — we're on the main run loop already
                binding.action(self.wm)
                self.wm.printStatus()
                return nil // swallow the event
            } else {
                print("Unknown binding for keycode \(keyCode)")
                return nil
            }
        }

        // Check for prefix key: Ctrl-t
        if keyCode == prefixKeyCode && ctrlHeld {
            waitingForCommand = true
            return nil // swallow the prefix
        }

        // Not our key, pass through
        return Unmanaged.passUnretained(event)
    }

    private func showCommandPrompt() {
        promptActive = true
        wm.commandPrompt.show { [weak self] cmd in
            guard let self = self else { return }
            self.promptActive = false
            if !cmd.isEmpty {
                print(">> :\(cmd)")
                self.commandServer?.handleCommand(cmd)
            }
        }
    }

    func printBindings() {
        print("Bindings (after Ctrl-t):")
        let sorted = bindings.values.sorted { $0.description < $1.description }
        for b in sorted {
            let keyName = keyCodeName(b.key)
            print("  \(keyName) / Ctrl-\(keyName) → \(b.description)")
        }
        print("  Ctrl-t → last (switch to previous window)")
        print("  : → command prompt")
        print("  t → send t to app")
        print("")
    }

    private func keyCodeName(_ code: CGKeyCode) -> String {
        let names: [CGKeyCode: String] = [
            CGKeyCode(kVK_ANSI_S): "s",
            CGKeyCode(kVK_ANSI_V): "v",
            CGKeyCode(kVK_ANSI_N): "n",
            CGKeyCode(kVK_ANSI_P): "p",
            CGKeyCode(kVK_ANSI_Q): "q",
            CGKeyCode(kVK_ANSI_O): "o",
            CGKeyCode(kVK_ANSI_W): "w",
            CGKeyCode(kVK_ANSI_I): "i",
            CGKeyCode(kVK_ANSI_K): "k",
            CGKeyCode(kVK_ANSI_M): "m",
            CGKeyCode(kVK_ANSI_Period): ".",
            CGKeyCode(kVK_ANSI_Comma): ",",
            CGKeyCode(kVK_ANSI_U): "u",
            CGKeyCode(kVK_ANSI_R): "r",
            CGKeyCode(kVK_ANSI_T): "t",
            CGKeyCode(kVK_Tab):    "Tab",
            CGKeyCode(kVK_Space):  "Space",
        ]
        return names[code] ?? "key(\(code))"
    }
}

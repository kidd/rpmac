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

            // Window list / swap
            CGKeyCode(kVK_ANSI_W): Binding(key: CGKeyCode(kVK_ANSI_W), action: { $0.showWindowList() }, description: "window list"),
            CGKeyCode(kVK_ANSI_K): Binding(key: CGKeyCode(kVK_ANSI_K), action: { $0.killWindow() }, description: "kill window"),

            // Screen navigation
            CGKeyCode(kVK_ANSI_Period): Binding(key: CGKeyCode(kVK_ANSI_Period), action: { $0.focusNextScreen() }, description: "next screen"),
            CGKeyCode(kVK_ANSI_Comma):  Binding(key: CGKeyCode(kVK_ANSI_Comma),  action: { $0.focusPrevScreen() }, description: "prev screen"),
            CGKeyCode(kVK_ANSI_M):      Binding(key: CGKeyCode(kVK_ANSI_M),      action: { $0.moveWindowToNextScreen() }, description: "move window to next screen"),

            // Mouse
            CGKeyCode(kVK_ANSI_B): Binding(key: CGKeyCode(kVK_ANSI_B), action: { $0.banish() }, description: "banish mouse"),

            // Undo/Redo
            CGKeyCode(kVK_ANSI_U): Binding(key: CGKeyCode(kVK_ANSI_U), action: { $0.undo() }, description: "undo"),
            CGKeyCode(kVK_ANSI_R): Binding(key: CGKeyCode(kVK_ANSI_R), action: { $0.redo() }, description: "redo"),

            // Directional focus
            CGKeyCode(kVK_LeftArrow):  Binding(key: CGKeyCode(kVK_LeftArrow),  action: { $0.focusDirection(.left) },  description: "focus left"),
            CGKeyCode(kVK_RightArrow): Binding(key: CGKeyCode(kVK_RightArrow), action: { $0.focusDirection(.right) }, description: "focus right"),
            CGKeyCode(kVK_UpArrow):    Binding(key: CGKeyCode(kVK_UpArrow),    action: { $0.focusDirection(.up) },    description: "focus up"),
            CGKeyCode(kVK_DownArrow):  Binding(key: CGKeyCode(kVK_DownArrow),  action: { $0.focusDirection(.down) },  description: "focus down"),

            // Info
            CGKeyCode(kVK_ANSI_I): Binding(key: CGKeyCode(kVK_ANSI_I), action: { $0.printStatus() }, description: "show status"),

            // Window numbering (select by number)
            CGKeyCode(kVK_ANSI_0): Binding(key: CGKeyCode(kVK_ANSI_0), action: { $0.selectWindow(number: 0) }, description: "select window 0"),
            CGKeyCode(kVK_ANSI_1): Binding(key: CGKeyCode(kVK_ANSI_1), action: { $0.selectWindow(number: 1) }, description: "select window 1"),
            CGKeyCode(kVK_ANSI_2): Binding(key: CGKeyCode(kVK_ANSI_2), action: { $0.selectWindow(number: 2) }, description: "select window 2"),
            CGKeyCode(kVK_ANSI_3): Binding(key: CGKeyCode(kVK_ANSI_3), action: { $0.selectWindow(number: 3) }, description: "select window 3"),
            CGKeyCode(kVK_ANSI_4): Binding(key: CGKeyCode(kVK_ANSI_4), action: { $0.selectWindow(number: 4) }, description: "select window 4"),
            CGKeyCode(kVK_ANSI_5): Binding(key: CGKeyCode(kVK_ANSI_5), action: { $0.selectWindow(number: 5) }, description: "select window 5"),
            CGKeyCode(kVK_ANSI_6): Binding(key: CGKeyCode(kVK_ANSI_6), action: { $0.selectWindow(number: 6) }, description: "select window 6"),
            CGKeyCode(kVK_ANSI_7): Binding(key: CGKeyCode(kVK_ANSI_7), action: { $0.selectWindow(number: 7) }, description: "select window 7"),
            CGKeyCode(kVK_ANSI_8): Binding(key: CGKeyCode(kVK_ANSI_8), action: { $0.selectWindow(number: 8) }, description: "select window 8"),
            CGKeyCode(kVK_ANSI_9): Binding(key: CGKeyCode(kVK_ANSI_9), action: { $0.selectWindow(number: 9) }, description: "select window 9"),
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
            | (1 << CGEventType.leftMouseDown.rawValue)

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

        // Mouse click — update focus to the frame under the cursor
        if type == .leftMouseDown && wm.clickToFocus {
            let point = event.location
            for (i, screen) in wm.screens.enumerated() {
                for leaf in screen.root.leaves {
                    if leaf.rect.contains(point) && leaf !== wm.focused {
                        wm.currentScreenIndex = i
                        wm.focused = leaf
                        wm.overlay.showBorder(around: leaf.rect)
                    }
                }
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
            wm.overlay.hideCursorIndicator()

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

            // Shift-R → remove frame
            if keyCode == CGKeyCode(kVK_ANSI_R) && flags.contains(.maskShift) {
                print(">> remove frame")
                wm.removeFrame()
                wm.printStatus()
                return nil
            }

            // Ctrl-Arrow → exchange window in that direction
            if ctrlHeld {
                switch keyCode {
                case CGKeyCode(kVK_LeftArrow):
                    print(">> exchange left")
                    wm.exchangeDirection(.left)
                    wm.printStatus()
                    return nil
                case CGKeyCode(kVK_RightArrow):
                    print(">> exchange right")
                    wm.exchangeDirection(.right)
                    wm.printStatus()
                    return nil
                case CGKeyCode(kVK_UpArrow):
                    print(">> exchange up")
                    wm.exchangeDirection(.up)
                    wm.printStatus()
                    return nil
                case CGKeyCode(kVK_DownArrow):
                    print(">> exchange down")
                    wm.exchangeDirection(.down)
                    wm.printStatus()
                    return nil
                default: break
                }
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
            wm.overlay.showCursorIndicator()
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
            CGKeyCode(kVK_ANSI_B): "b",
            CGKeyCode(kVK_ANSI_K): "k",
            CGKeyCode(kVK_ANSI_M): "m",
            CGKeyCode(kVK_ANSI_Period): ".",
            CGKeyCode(kVK_ANSI_Comma): ",",

            CGKeyCode(kVK_ANSI_U): "u",
            CGKeyCode(kVK_ANSI_R): "r",
            CGKeyCode(kVK_ANSI_T): "t",
            CGKeyCode(kVK_Tab):    "Tab",
            CGKeyCode(kVK_Space):  "Space",
            CGKeyCode(kVK_ANSI_0): "0",
            CGKeyCode(kVK_ANSI_1): "1",
            CGKeyCode(kVK_ANSI_2): "2",
            CGKeyCode(kVK_ANSI_3): "3",
            CGKeyCode(kVK_ANSI_4): "4",
            CGKeyCode(kVK_ANSI_5): "5",
            CGKeyCode(kVK_ANSI_6): "6",
            CGKeyCode(kVK_ANSI_7): "7",
            CGKeyCode(kVK_ANSI_8): "8",
            CGKeyCode(kVK_ANSI_9): "9",
            CGKeyCode(kVK_LeftArrow): "Left",
            CGKeyCode(kVK_RightArrow): "Right",
            CGKeyCode(kVK_UpArrow): "Up",
            CGKeyCode(kVK_DownArrow): "Down",
        ]
        return names[code] ?? "key(\(code))"
    }
}

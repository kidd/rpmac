import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// Ratpoison-style prefix key + command key bindings using CGEventTap.
/// Default prefix: Ctrl-t (like ratpoison)
///
/// Both `Ctrl-t <key>` and `Ctrl-t Ctrl-<key>` work (holding ctrl throughout).
class KeyBinder {
    let wm: WindowManager
    private var waitingForCommand = false
    private var eventTap: CFMachPort?

    // Prefix key: Ctrl-t
    let prefixKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_T)

    // Command bindings: key -> action
    struct Binding {
        let key: CGKeyCode
        let action: (WindowManager) -> Void
        let description: String
    }

    lazy var bindings: [CGKeyCode: Binding] = {
        return [
            // Split
            CGKeyCode(kVK_ANSI_S): Binding(key: CGKeyCode(kVK_ANSI_S), action: { $0.splitHorizontal() }, description: "split horizontal"),
            CGKeyCode(kVK_ANSI_V): Binding(key: CGKeyCode(kVK_ANSI_V), action: { $0.splitVertical() }, description: "split vertical"),

            // Focus
            CGKeyCode(kVK_ANSI_N): Binding(key: CGKeyCode(kVK_ANSI_N), action: { $0.focusNext() }, description: "focus next"),
            CGKeyCode(kVK_ANSI_P): Binding(key: CGKeyCode(kVK_ANSI_P), action: { $0.focusPrev() }, description: "focus prev"),
            CGKeyCode(kVK_Tab):    Binding(key: CGKeyCode(kVK_Tab),    action: { $0.focusNext() }, description: "focus next"),

            // Frame management
            CGKeyCode(kVK_ANSI_Q): Binding(key: CGKeyCode(kVK_ANSI_Q), action: { $0.removeFrame() }, description: "remove frame"),
            CGKeyCode(kVK_ANSI_O): Binding(key: CGKeyCode(kVK_ANSI_O), action: { $0.only() }, description: "only (remove all other frames)"),

            // Window management
            CGKeyCode(kVK_ANSI_W): Binding(key: CGKeyCode(kVK_ANSI_W), action: { $0.swapNext() }, description: "swap with next"),
            CGKeyCode(kVK_Space):  Binding(key: CGKeyCode(kVK_Space),  action: { $0.nextWindowInFrame() }, description: "next window in frame"),

            // Info
            CGKeyCode(kVK_ANSI_I): Binding(key: CGKeyCode(kVK_ANSI_I), action: { $0.printStatus() }, description: "show status"),
        ]
    }()

    init(wm: WindowManager) {
        self.wm = wm
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

        print("Keybindings active. Prefix: Ctrl-t")
        printBindings()
        return true
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it gets disabled (happens under heavy load)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        let ctrlHeld = flags.contains(.maskControl)

        print("[key] code=\(keyCode) ctrl=\(ctrlHeld) waiting=\(waitingForCommand)")

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

    func printBindings() {
        print("Bindings (after Ctrl-t):")
        let sorted = bindings.values.sorted { $0.description < $1.description }
        for b in sorted {
            let keyName = keyCodeName(b.key)
            print("  \(keyName) / Ctrl-\(keyName) → \(b.description)")
        }
        print("  Ctrl-t → last (switch to previous frame)")
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
            CGKeyCode(kVK_ANSI_T): "t",
            CGKeyCode(kVK_Tab):    "Tab",
            CGKeyCode(kVK_Space):  "Space",
        ]
        return names[code] ?? "key(\(code))"
    }
}

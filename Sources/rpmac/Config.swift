import Foundation
import Carbon.HIToolbox
import CoreGraphics
import AppKit

/// Reads and applies ~/.rpmacrc configuration.
///
/// Format (one command per line, # for comments):
///   bind <key> <command>        — bind key after prefix
///   unbind <key>                — remove a binding
///   escape <key>                — change prefix key (e.g. "C-t", "C-s")
///   set border-width <n>        — border width in pixels
///   set border-color <hex>      — border color (e.g. #0000ff)
///   set overlay-duration <secs> — how long the overlay shows
///   set padding <n>             — gap in pixels between frames
///   <command>                   — run a command at startup (e.g. split-h)
///
/// Keys: a-z, 0-9, space, tab, return, semicolon, slash, etc.
/// Modifiers in bind: C- (ctrl), S- (shift)  e.g. "C-n", "S-tab"
class Config {
    let path: String

    init(path: String = NSString(string: "~/.rpmacrc").expandingTildeInPath) {
        self.path = path
    }

    struct ParsedConfig {
        var bindings: [(key: String, command: String)] = []
        var unbindings: [String] = []
        var escapeKey: String? = nil
        var settings: [(String, String)] = []
        var appRemaps: [(app: String, from: String, to: String)] = []
        var startupCommands: [String] = []
    }

    func parse() -> ParsedConfig {
        var config = ParsedConfig()

        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return config
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }

            switch parts[0] {
            case "bind" where parts.count >= 3:
                let key = parts[1]
                let command = parts[2...].joined(separator: " ")
                config.bindings.append((key: key, command: command))

            case "unbind" where parts.count >= 2:
                config.unbindings.append(parts[1])

            case "escape" where parts.count >= 2:
                config.escapeKey = parts[1]

            case "set" where parts.count >= 3:
                let name = parts[1]
                let value = parts[2...].joined(separator: " ")
                config.settings.append((name, value))

            case "appremap" where parts.count >= 4:
                // appremap "App Name" from-key to-key
                // Parse quoted app name
                let rest = line.dropFirst("appremap".count).trimmingCharacters(in: .whitespaces)
                if let (appName, remainder) = parseQuotedOrWord(rest) {
                    let remapParts = remainder.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if remapParts.count >= 2 {
                        config.appRemaps.append((app: appName, from: remapParts[0], to: remapParts[1]))
                    }
                }

            default:
                // Treat as a startup command
                config.startupCommands.append(line)
            }
        }

        return config
    }

    /// Apply parsed config to the keybinder, window manager, and command server
    func apply(parsed: ParsedConfig, keyBinder: KeyBinder, wm: WindowManager, server: CommandServer) {
        // Apply settings
        for (name, value) in parsed.settings {
            switch name {
            case "border-width":
                if let n = Double(value) {
                    // We'll apply this through the overlay
                    print("  border-width = \(n)")
                    applyBorderWidth(CGFloat(n), overlay: wm.overlay)
                }
            case "border-color":
                if let color = parseColor(value) {
                    print("  border-color = \(value)")
                    applyBorderColor(color, overlay: wm.overlay)
                }
            case "overlay-duration":
                if let n = Double(value) {
                    print("  overlay-duration = \(n)")
                    wm.overlay.displayDuration = n
                }
            case "fgcolor":
                if let color = parseColor(value) {
                    print("  fgcolor = \(value)")
                    wm.overlay.fgColor = color
                }
            case "bgcolor":
                if let color = parseColor(value) {
                    print("  bgcolor = \(value)")
                    wm.overlay.bgColor = color
                }
            case "barpadding":
                if let n = Double(value) {
                    print("  barpadding = \(n)")
                    wm.overlay.barPadding = CGFloat(n)
                }
            case "warp":
                let on = value == "1" || value.lowercased() == "true"
                print("  warp = \(on)")
                wm.warp = on
            case "framesels":
                print("  framesels = \(value)")
                wm.framesels = value
            case "clicktofocus":
                let on = value == "1" || value.lowercased() == "true"
                print("  clicktofocus = \(on)")
                wm.clickToFocus = on
            case "click-to-focus":
                let app = value.lowercased()
                WindowRef.clickToFocusApps.insert(app)
                print("  click-to-focus += \(app)")
            default:
                print("  Unknown setting: \(name)")
            }
        }

        // Change escape/prefix key
        if let escapeStr = parsed.escapeKey {
            if let (keyCode, _) = parseKeySpec(escapeStr) {
                print("  escape = \(escapeStr)")
                keyBinder.setPrefixKey(keyCode)
            }
        }

        // Unbind keys
        for keyStr in parsed.unbindings {
            if let (keyCode, _) = parseKeySpec(keyStr) {
                keyBinder.removeBinding(keyCode: keyCode)
                print("  unbind \(keyStr)")
            }
        }

        // Bind keys
        for (keyStr, command) in parsed.bindings {
            if let (keyCode, _) = parseKeySpec(keyStr) {
                keyBinder.addBinding(keyCode: keyCode, keyName: keyStr, command: command, server: server)
                print("  bind \(keyStr) → \(command)")
            }
        }

        // App remaps
        for remap in parsed.appRemaps {
            if let (fromKey, fromMods) = parseKeySpec(remap.from),
               let (toKey, toMods) = parseKeySpec(remap.to) {
                keyBinder.addRemap(app: remap.app, fromKey: fromKey, fromMods: fromMods, toKey: toKey, toMods: toMods)
                print("  appremap \"\(remap.app)\" \(remap.from) → \(remap.to)")
            }
        }

        // Run startup commands
        for cmd in parsed.startupCommands {
            print("  > \(cmd)")
            server.handleCommand(cmd)
        }
    }

    // MARK: - String parsing

    /// Parse a quoted string or a single word from the start of a string.
    /// Returns (parsed value, remainder) or nil if empty.
    private func parseQuotedOrWord(_ s: String) -> (String, String)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("\"") {
            let rest = trimmed.dropFirst()
            if let endQuote = rest.firstIndex(of: "\"") {
                let value = String(rest[rest.startIndex..<endQuote])
                let remainder = String(rest[rest.index(after: endQuote)...])
                return (value, remainder)
            }
            return (String(rest), "")
        } else {
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            let value = String(parts[0])
            let remainder = parts.count > 1 ? String(parts[1]) : ""
            return (value, remainder)
        }
    }

    // MARK: - Key parsing

    /// Parse a key spec like "n", "C-n", "S-tab", "M-b", "Cmd-d" into (keyCode, modifiers)
    func parseKeySpec(_ spec: String) -> (CGKeyCode, CGEventFlags)? {
        var remaining = spec
        var flags: CGEventFlags = []

        while remaining.count > 2 {
            if remaining.hasPrefix("C-") {
                flags.insert(.maskControl)
                remaining = String(remaining.dropFirst(2))
            } else if remaining.hasPrefix("S-") {
                flags.insert(.maskShift)
                remaining = String(remaining.dropFirst(2))
            } else if remaining.hasPrefix("M-") {
                flags.insert(.maskAlternate)
                remaining = String(remaining.dropFirst(2))
            } else if remaining.hasPrefix("Cmd-") {
                flags.insert(.maskCommand)
                remaining = String(remaining.dropFirst(4))
            } else {
                break
            }
        }

        guard let keyCode = keyNameToCode(remaining.lowercased()) else {
            print("  Unknown key: \(remaining)")
            return nil
        }

        return (keyCode, flags)
    }

    private func keyNameToCode(_ name: String) -> CGKeyCode? {
        let map: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "space": kVK_Space, "tab": kVK_Tab, "return": kVK_Return,
            "escape": kVK_Escape, "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "semicolon": kVK_ANSI_Semicolon, "colon": kVK_ANSI_Semicolon,
            "slash": kVK_ANSI_Slash, "backslash": kVK_ANSI_Backslash,
            "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period,
            "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal,
            "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow,
        ]
        guard let code = map[name] else { return nil }
        return CGKeyCode(code)
    }

    // MARK: - Settings helpers

    private func parseColor(_ hex: String) -> NSColor? {
        var str = hex
        if str.hasPrefix("#") { str = String(str.dropFirst()) }
        guard str.count == 6, let val = UInt64(str, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((val >> 16) & 0xFF) / 255,
            green: CGFloat((val >> 8) & 0xFF) / 255,
            blue: CGFloat(val & 0xFF) / 255,
            alpha: 1
        )
    }

    private func applyBorderWidth(_ width: CGFloat, overlay: Overlay) {
        overlay.borderWidth = width
    }

    private func applyBorderColor(_ color: NSColor, overlay: Overlay) {
        overlay.borderColor = color
    }
}

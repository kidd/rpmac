# rpmac

A [ratpoison](https://www.nongnu.org/ratpoison/)-style manual tiling window manager for macOS.

Unlike yabai or aerospace which do automatic tiling, rpmac follows ratpoison's model: manual frame splits, keyboard-driven, windows fill their frame, prefix key for all commands.

## How it works

- A **prefix key** (Ctrl-t by default) activates the command mode. After pressing Ctrl-t, the next key triggers a window management action.
- The screen is divided into **frames** using a binary tree. Each frame holds one window at a time.
- Windows not currently displayed live in an **unmanaged pool** and can be cycled through with next/prev.
- Each **screen** (monitor) has its own independent frame tree.

## Requirements

- macOS 13+
- Swift 5.9+
- Accessibility permissions (System Settings -> Privacy & Security -> Accessibility)

## Building

```sh
./build.sh
```

This builds a release binary, copies it into `rpmac.app`, and codesigns it.

Or manually:

```sh
swift build -c release
cp .build/release/rpmac rpmac.app/Contents/MacOS/rpmac
codesign --force --sign - rpmac.app
```

## Running

```sh
# As an app (background, no terminal needed):
open rpmac.app

# Or directly (shows log output):
.build/release/rpmac
```

To start on login: System Settings -> General -> Login Items -> add `rpmac.app`.

## Default keybindings

All bindings work as both `Ctrl-t <key>` and `Ctrl-t Ctrl-<key>` (holding ctrl throughout).

| Key | Action |
|-----|--------|
| `s` | Split vertical (top/bottom) |
| `v` | Split horizontal (left/right) |
| `n` / `Space` | Next window (cycle unmanaged pool into current frame) |
| `p` | Previous window |
| `o` / `Tab` | Next frame |
| `Shift-Tab` | Previous frame |
| `.` | Next screen |
| `,` | Previous screen |
| `m` | Move window to next screen |
| `q` | Only (remove all other frames, keep focused) |
| `w` | Swap window with next frame |
| `k` | Kill window (terminates the app) |
| `b` | Banish mouse to bottom-right corner |
| `u` | Undo (frame structure changes) |
| `r` | Redo |
| `i` | Print status to stdout |
| `Ctrl-t` | Last (toggle to previous window) |
| `:` | Command prompt (with tab-autocomplete) |
| `t` | Pass-through (send a literal `t` to the app) |

## Commands

Available via the command prompt (`:`) or the Unix socket:

| Command | Description |
|---------|-------------|
| `split-h` / `hsplit` | Split horizontal (left/right) |
| `split-v` / `vsplit` | Split vertical (top/bottom) |
| `next` | Next window in current frame |
| `prev` | Previous window in current frame |
| `next-frame` | Focus next frame |
| `prev-frame` | Focus previous frame |
| `next-screen` | Focus next screen |
| `prev-screen` | Focus previous screen |
| `move-to-screen` | Move current window to next screen |
| `last` | Switch to previously focused window |
| `swap` | Swap contents of current and next frame |
| `only` | Remove all frames except focused |
| `remove` | Remove current frame |
| `kill` | Kill the window's application |
| `capture` / `pull` | Capture the currently focused (OS-level) window |
| `release` | Release window from frame to unmanaged pool |
| `banish` | Move mouse to bottom-right corner |
| `undo` | Undo last frame operation |
| `redo` | Redo |
| `rescreen` | Recalculate screen rects (after display changes) |
| `reload` | Reload `~/.rpmacrc` configuration |
| `status` / `info` | Print frame tree status |
| `quit` | Shut down rpmac |

## Scripting via Unix socket

rpmac listens on `/tmp/rpmac.sock`. Send commands with:

```sh
echo "split-h" | nc -U /tmp/rpmac.sock
```

## Configuration

rpmac reads `~/.rpmacrc` on startup. See `rpmacrc.example` for full documentation.

```sh
# Change prefix key to Ctrl-s
escape C-s

# Appearance
set fgcolor #00ff00
set bgcolor #000000
set barpadding 16
set border-color #ff0000
set border-width 3
set overlay-duration 0.5

# Warp mouse to focused window on raise
set warp 1

# Apps that need a synthetic click to receive focus (default: alacritty)
set click-to-focus kitty

# Custom bindings
bind f next-frame
bind semicolon next-screen

# Remove a default binding
unbind w

# Startup commands (run on launch)
split-h
```

### Config syntax

| Directive | Description |
|-----------|-------------|
| `bind <key> <command>` | Bind key (after prefix) to a command |
| `unbind <key>` | Remove a binding |
| `escape <key>` | Change prefix key (e.g. `C-s`) |
| `set <option> <value>` | Change a setting |
| `<command>` | Run command at startup |

### Key names

- Letters: `a`-`z`
- Numbers: `0`-`9`
- Words: `space`, `tab`, `return`, `escape`, `delete`, `semicolon`, `colon`, `slash`, `backslash`, `comma`, `period`, `minus`, `equal`
- Arrows: `left`, `right`, `up`, `down`
- Modifiers: `C-` (ctrl), `S-` (shift) — e.g. `C-n`, `S-tab`

### Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `fgcolor` | `#ffffff` | Message bar text color |
| `bgcolor` | `#333333` | Message bar background color |
| `barpadding` | `24` | Message bar padding in pixels |
| `border-width` | `2` | Focus border width in pixels |
| `border-color` | system blue | Focus border color |
| `overlay-duration` | `0.7` | How long the message overlay shows (seconds) |
| `warp` | `0` | Warp mouse to focused window on raise |
| `click-to-focus` | `alacritty` | App name that needs a synthetic click to focus (repeatable) |

## Architecture

```
Sources/rpmac/
  main.swift            — Entry point: NSApplication setup, permission check, init, run loop
  WindowManager.swift   — Core state: per-screen frame trees, unmanaged pool, undo/redo
  FrameTree.swift       — Binary tree for frame splits (Frame class, split/remove/clone)
  WindowRef.swift       — AXUIElement wrapper: move/resize, raise, focus, synthetic click
  AccessibilityHelper.swift — AX permission check, window enumeration, screen rect conversion
  KeyBinder.swift       — CGEventTap prefix-key system, binding dispatch
  CommandServer.swift   — Unix socket IPC server, command dispatch
  CommandPrompt.swift   — Floating text input with tab-autocomplete (KeyableWindow)
  Config.swift          — ~/.rpmacrc parser and applier
  Overlay.swift         — Focus border (persistent) and message bar (timed), coordinate flip

rpmac.app/              — macOS app bundle (LSBackgroundOnly, no dock icon)
  Contents/
    Info.plist
    MacOS/rpmac         — Binary (copied by build.sh)
```

### Key design decisions

**Manual tiling, not automatic.** The user explicitly splits frames and assigns windows. Windows don't rearrange themselves. This is the fundamental difference from yabai/aerospace.

**Binary frame tree.** Each split divides a frame into exactly two children. This keeps the data structure simple and makes undo/redo straightforward (deep-copy snapshots of the tree).

**Prefix key model.** All commands go through a prefix key (Ctrl-t). This avoids conflicts with application shortcuts and matches ratpoison's UX. After the prefix, both `<key>` and `Ctrl-<key>` work, so you can hold ctrl throughout.

**Per-screen frame trees.** Each monitor has an independent frame tree with its own focused frame. Windows can be moved between screens.

**Unmanaged pool.** Windows not assigned to a frame live in a shared pool. `next`/`prev` cycle through this pool within the current frame.

**Accessibility API for window control.** macOS has no public window management API. rpmac uses `AXUIElement` to move, resize, and focus windows. This requires the Accessibility permission.

**CGEventTap for keyboard.** A session-level event tap intercepts all keystrokes. When the prefix key is detected, the next keystroke is consumed and dispatched. The tap re-enables itself if macOS disables it (Chrome and other apps can trigger this).

**Synthetic click for stubborn apps.** Some apps (like Alacritty) don't respond to AX focus attributes. For these, rpmac warps the cursor to the window center, sends a mouseDown+mouseUp, and warps back. The list of apps needing this is configurable via `set click-to-focus`.

**Coordinate systems.** macOS has two coordinate systems: Cocoa (bottom-left origin, used by NSScreen/NSWindow) and Accessibility/CoreGraphics (top-left origin). The primary screen's height is the reference for conversion. This is handled in `AccessibilityHelper.screenRect(for:)` and `Overlay.flipToCocoaCoordinates()`.

**NSApplication as accessory.** rpmac runs as `.accessory` — no dock icon, no menu bar. The app bundle has `LSBackgroundOnly` and `LSUIElement` set. An `NSApplication` run loop is still needed for overlay windows and timers.

**KeyableWindow.** Borderless `NSWindow` instances can't become key (receive keyboard input) by default. The command prompt uses a `KeyableWindow` subclass that overrides `canBecomeKey` to return `true`.

### Known issues and quirks

- **Cocoa Ctrl-N/P remapping.** macOS Cocoa text system can remap Ctrl-N/P/F/B to arrow keys in some apps. External tools like Karabiner can also cause this. If `Ctrl-t Ctrl-n` stops working in a specific app, check for Karabiner rules or similar remappers.

- **Event tap disabling.** Chrome and some other apps can cause macOS to disable the event tap. rpmac detects this and re-enables it automatically.

- **Alacritty focus.** Alacritty doesn't respond to AX focus changes alone. The `click-to-focus` mechanism handles this with a synthetic click. A 50ms delay is used before warping the cursor back so the click registers.

### References

- [ratpoison manual](https://www.nongnu.org/ratpoison/)
- [ratpoison command reference](https://ratpoison.sourceforge.net/docs/Commands.html)
- [macOS Accessibility API (AXUIElement)](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- [CGEventTap](https://developer.apple.com/documentation/coregraphics/cgevent)
- [NSScreen coordinate systems](https://developer.apple.com/documentation/appkit/nsscreen)
- [Carbon key codes (HIToolbox/Events.h)](https://developer.apple.com/documentation/carbon/hithunk_h)

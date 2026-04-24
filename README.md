# HyperVibe

A macOS menu-bar app that turns a paired Apple TV Siri Remote into a **trackpad, button controller, and Claude Code gesture pad** for your Mac.

> **Fork & improvements.** HyperVibe is built on top of [Remotastic](https://github.com/lauschue/Remotastic) by [@lauschue](https://github.com/lauschue), which provided the foundational Siri-Remote HID handling, MultitouchSupport integration, and menu-bar scaffolding. HyperVibe extends it with configurable Claude Code workflows, hold-capable push-to-talk, trackpad swipe commands, hardened-runtime signing for modern macOS, and a refreshed identity (name, icon, menu-bar glyph).

---

## Features

### Trackpad (Siri Remote surface)

- **Cursor movement** via single-finger drag
- **Two-finger scroll** (natural-scroll direction, configurable scale)
- **Tap-to-click** on the trackpad surface
- **Drag** by holding the trackpad click and moving
- **Trackpad swipe gestures** — single-finger flicks in each of four directions fire a configurable action (see "Swipe Gestures" below)

### Buttons

Each physical Siri Remote button is independently assignable via the menu bar → **Button Mappings**. Available actions:

| Action | Behavior |
|---|---|
| None | Do nothing |
| Enter: Submit prompt | Virtual Return |
| Up: Navigate Up | Up arrow |
| Down: Navigate Down | Down arrow |
| Esc: Navigate Back | Escape |
| Control + C: Cancel Prompt | Ctrl-C |
| Trackpad Click | Left mouse click at cursor |
| Space: Claude Voice Dictation *(hold)* | Mirrors HID press duration — virtual keyDown on press, keyUp on release |
| Right Command: 3rd-party Voice Dictation *(hold)* | Press-to-talk Right ⌘ |
| Right Option: 3rd-party Voice Dictation *(hold)* | Press-to-talk Right ⌥ |

**Hold-capable filtering.** Push-to-talk actions require buttons that emit both press and release HID events. Only Play/Pause, Volume Up, Volume Down, and Siri pass — so these voice-dictation options are hidden in the submenus for Menu and TV, which only fire on press.

**Defaults (first launch):**
- Trackpad Click → Trackpad Click
- Menu → Esc
- TV → Ctrl + C
- Siri → Space (Claude Voice Dictation)
- Play/Pause → Enter
- Volume Up → Up
- Volume Down → Down

![Default Siri Remote button mapping](siri-remote-button-mapping-default.png)

### Swipe Gestures

Four independently configurable single-finger swipe directions on the trackpad surface. Detection is velocity-gated: **distance ≥ 35%** of trackpad, **duration < 350 ms**, **dominant axis ≥ 2×** the other. Slow drags continue to move the cursor; only deliberate flicks trigger actions.

Assignable actions per direction:

- **Arrow keys (direction-matched)**: "Left: Navigate Left" offered only on Swipe Left; "Right: Navigate Right" offered only on Swipe Right.
- **Mode Switching (Shift + Tab)** — toggle between normal / plan / auto-accept modes in Claude Code.
- **`ultrathink`** — inserts the keyword (with trailing space) into the prompt.
- **Slash commands**: `/btw`, `/compact`, `/config`, `/context`, `/effort`, `/init`, `/model`, `/remote-control`, `/schedule`, `/tasks`, `/usage`.
- **None**.

**Trailing-space policy.** Commands that typically take an argument (`/btw`, `/schedule`, `ultrathink`) are typed with a trailing space so you can keep typing. Commands that stand alone or open an interactive picker (`/compact`, `/config`, `/context`, `/effort`, `/init`, `/model`, `/remote-control`, `/tasks`, `/usage`) are typed without a trailing space.

**Enter is never sent** — gestures type the command but leave Enter for the user, so the command can be reviewed, edited, or augmented with arguments.

**Defaults (first launch):**
- Swipe Up → `/usage`
- Swipe Down → `/compact`
- Swipe Left → `/model`
- Swipe Right → Mode Switching (Shift + Tab)

![Siri Remote swipe gesture mapping](siri-remote-gesture-mapping.png)

### Persistence

Button mappings and swipe mappings are saved to UserDefaults (`buttonMappings`, `swipeMappings`) and survive restarts. Schema versioning handles future upgrades (`buttonMappingsSchema`).

### Safety

- **Stuck-key prevention.** If the remote disconnects while a push-to-talk key is held, HyperVibe releases the virtual key automatically.
- **Stale-hold self-heal.** If a release HID event is ever missed, the next press closes the stale hold before opening a new one.
- **HID seize.** On connect, HyperVibe seizes the remote at the HID level so macOS no longer also sees media key events from it — no double-dispatch (e.g., to iTunes/Music), no system funk sound on unhandled keys.
- **No click sounds.** All `NSSound.beep()` feedback from the upstream project has been removed — silent operation.

### Identity

- **App name**: HyperVibe
- **Bundle identifier**: `com.hypervibe.app`
- **Menu-bar glyph**: custom-drawn walkie-talkie (template image, auto-tints for light/dark menu bar)
- **App icon**: white walkie-talkie silhouette on a warm-coral squircle (shades of `#F07654`: darker on top, base mid, lighter peach at the bottom); display and speaker are transparent cutouts showing the gradient through

---

## Building

### Prerequisites

- macOS 11 (Big Sur) or later
- Xcode Command Line Tools: `xcode-select --install`

### Build

```bash
./build.sh
```

This runs a single `swiftc` invocation over all the project's Swift files, linking IOKit, CoreGraphics, AudioToolbox, Carbon, AppKit, and the private MultitouchSupport framework via a bridging header. No Xcode project is required.

### Bundle and sign

```bash
./create_app_bundle.sh
```

Produces `HyperVibe.app` with:

- Info.plist entries (bundle ID, Bluetooth usage descriptions, `LSUIElement=true` for menu-bar-only behavior)
- Bundled `HyperVibe.icns` icon
- Hardened runtime + entitlements (`com.apple.security.device.bluetooth`, library validation disabled for MultitouchSupport)
- Ad-hoc code signature (`--sign -`). Swap in a Developer ID identity for distribution.

Hardened runtime with entitlements is **required** on macOS 14+ for `IOHIDManager` to deliver Bluetooth HID events from the Siri Remote.

### Regenerating the icon

```bash
swift gen_icon.swift            # renders PNGs into HyperVibe.iconset/
iconutil -c icns HyperVibe.iconset
```

---

## Installing and Running

1. Build and bundle: `./build.sh && ./create_app_bundle.sh`
2. Move `HyperVibe.app` to `/Applications` (optional but helps icon caching)
3. Launch it (`open HyperVibe.app`)
4. Grant permissions in **System Settings → Privacy & Security**:
   - **Accessibility** (for posting keyboard/mouse events)
   - **Input Monitoring** (for reading HID events)
   - **Bluetooth** (to communicate with the remote)
5. Pair the Siri Remote via **System Settings → Bluetooth** if it isn't already paired
6. Use the menu-bar walkie-talkie glyph to access Button Mappings and Swipe Gestures

A diagnostic log is written to `/tmp/hypervibe.log` (NSLog is redacted under hardened runtime, so HyperVibe uses file-based logging).

---

## Architecture

| File | Role |
|---|---|
| `main.swift` | NSApplication entry point |
| `SiriRemoteApp.swift` | AppDelegate — wires detector, input handler, touch handler, menu bar, and media-key interceptor |
| `RemoteDetector.swift` | IOHIDManager-based device discovery (matches on Apple vendor ID across Consumer / Digitizer / Apple Vendor / Generic Desktop usage pages) |
| `RemoteInputHandler.swift` | HID input callback, button identification, hold tracking, action dispatch |
| `TouchHandler.swift` | MultitouchSupport integration — cursor, scroll, tap, swipe detection |
| `CursorController.swift` | Mouse movement, clicks, drag |
| `MediaKeyInterceptor.swift` | `cghidEventTap` fallback for AVRCP media keys (with 200 ms debounce against the HID path) |
| `MenuBarManager.swift` | Menu bar UI, mappings, persistence, swipe execution |
| `SiriRemote-Bridging-Header.h` | Bridges the private MultitouchSupport C API to Swift |
| `gen_icon.swift` | Renders the app-icon PNG frames for `iconutil` |
| `build.sh` / `create_app_bundle.sh` | Build and bundle scripts |
| `HyperVibe.entitlements` | Hardened-runtime entitlements for Bluetooth HID |

### Why two paths for the same button?

A physical Siri Remote press can arrive two ways:

1. **HID (seized)** — `RemoteInputHandler` reads raw HID input.
2. **AVRCP → NX_SYSDEFINED** — Bluetooth media-key events `MediaKeyInterceptor` catches via an event tap.

Both paths converge on the same button mapping through a 200 ms debounce (static `lastProcessedButton`/`lastProcessedTime` on `RemoteInputHandler`), so a press fires the mapped action exactly once regardless of which path delivers it first.

---

## Caveats

- Uses Apple's **private `MultitouchSupport` framework** — not App Store compatible; Apple may change or remove this API in future macOS releases.
- Tested on **Siri Remote 1st-gen (A1513, product ID `0x266`)**. Button HID codes are a superset likely to cover the 2nd-gen Siri Remote (A2540) as well, but its click-ring directional presses and dedicated Mute button are not yet mapped in `identifyButton`.
- Ad-hoc signing ties TCC permission grants to the exact binary hash — rebuilds may require re-approval in System Settings.

---

## Credits and License

- Original project: [Remotastic](https://github.com/lauschue/Remotastic) by [@lauschue](https://github.com/lauschue) — HyperVibe is a fork that preserves the core trackpad/HID architecture while extending it for a Claude Code workflow.
- License: see `LICENSE`.

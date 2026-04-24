<img src="banner.png" alt="HyperVibe — a walkie-talkie for Claude Code">

# HyperVibe V0.1

A macOS menu-bar app that turns a paired Apple TV Siri Remote into **a walkie-talkie for Claude Code**.

Grab a remote, push to talk, and vibe-code with Claude Code without breaking flow. 

Hyper optimize your vibe coding workflow with a single hand!

<img src="demo.gif" alt="HyperVibe demo" width="70%">

Tested with the 1st-gen Siri Remote (Model A1513). Support for Xbox Adaptive Joystick coming soon.

> **Experimental release.** For now, HyperVibe ships as an experiment — there is no pre-built binary. You'll have to build the app bundle yourself (see [Building](#building)). Your mileage may vary.

---

## Demo

<video src="[demo-video.m4v](https://github.com/machinarii/hypervibe/blob/main/demo-video.mov)" controls width="70%"></video>

---

## Features

### Buttons

Each physical Siri Remote button is independently assignable via the menu bar.

<img src="siri-remote-button-mapping-default.png" alt="Default Siri Remote button mapping" width="50%">

<img src="screenshot-button-mapping.png" alt="Button Mappings menu screenshot" width="70%">

**Default Button Mapping (Customizable):**
- Menu → Esc
- TV → Ctrl + C
- Siri → Space (Claude voice dictation)
- Play/Pause → Enter
- Volume Up → Up arrow
- Volume Down → Down arrow

| Action | Behavior |
|---|---|
| Play/pause button | Enter (submit prompt) |
| Volume up button | Up arrow |
| Volume down button | Down arrow |
| Menu button | Esc (Navigate back) |
| TV button | Control + C (cancel prompt) |
| Trackpad click | Left mouse click |
| Siri/mic button | Space on hold (Claude voice dictation must be enabled |
| Siri/mic button | Right ⌘ on hold (3rd party voice dictation like VoiceInk) |
| Siri/mic button | Right ⌥ on hold (3rd party voice dictation like VoiceInk) |

**Hold-Capable Buttons:** Push-to-talk actions require buttons that emit both press and release HID events. Only Play/Pause, Volume Up, Volume Down, and Siri buttons allow for both events.


### Swipe Gestures

Four independently configurable single-finger swipe directions on the trackpad surface. Detection is velocity-gated: **distance ≥ 35%** of trackpad, **duration < 350 ms**, **dominant axis ≥ 2×** the other. Slow drags continue to move the cursor; only deliberate flicks trigger actions.

<img src="siri-remote-gesture-mapping.png" alt="Siri Remote swipe gesture mapping" width="50%">

<img src="screenshot-swipe-mapping.png" alt="Swipe Gestures menu screenshot" width="70%">

**Default Gesture Mapping (Customizable):**
- Swipe Up → `/usage`
- Swipe Down → `/compact`
- Swipe Left → `/model`
- Swipe Right → Mode Switching (Shift + Tab)

Assignable actions:

- **Arrow keys (direction-matched)**: "Left: Navigate Left" offered only on Swipe Left; "Right: Navigate Right" offered only on Swipe Right.
- **Mode Switching (Shift + Tab)** — toggle between normal / plan / auto-accept modes in Claude Code.
- **`ultrathink`** — inserts the keyword (with trailing space) into the prompt.
- **Slash commands**: `/btw`, `/compact`, `/config`, `/context`, `/effort`, `/init`, `/model`, `/remote-control`, `/schedule`, `/tasks`, `/usage`.
- **None**.

**Trailing-space policy.** Commands that typically take an argument (`/btw`, `/schedule`, `ultrathink`) are typed with a trailing space so you can keep typing. Commands that stand alone or open an interactive picker (`/compact`, `/config`, `/context`, `/effort`, `/init`, `/model`, `/remote-control`, `/tasks`, `/usage`) are typed without a trailing space.

**Enter is never sent** — gestures type the command but leave Enter for the user, so the command can be reviewed, edited, or augmented with arguments.

### Other Trackpad Inputs

- **Cursor movement** via single-finger drag
- **Two-finger scroll** (natural-scroll direction, configurable scale)
- **Tap-to-click** on the trackpad surface
- **Drag** by holding the trackpad click and moving

### Persistence

Button mappings and swipe mappings are saved to UserDefaults (`buttonMappings`, `swipeMappings`) and survive restarts. Schema versioning handles future upgrades (`buttonMappingsSchema`).

### Safety

- **Stuck-key prevention.** If the remote disconnects while a push-to-talk key is held, HyperVibe releases the virtual key automatically.
- **Stale-hold self-heal.** If a release HID event is ever missed, the next press closes the stale hold before opening a new one.
- **HID seize.** On connect, HyperVibe seizes the remote at the HID level so macOS no longer also sees media key events from it — no double-dispatch (e.g., to iTunes/Music), no system funk sound on unhandled keys.

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

### Why two paths for the same button?

A physical Siri Remote press can arrive two ways:

1. **HID (seized)** — `RemoteInputHandler` reads raw HID input.
2. **AVRCP → NX_SYSDEFINED** — Bluetooth media-key events `MediaKeyInterceptor` catches via an event tap.

Both paths converge on the same button mapping through a 200 ms debounce (static `lastProcessedButton`/`lastProcessedTime` on `RemoteInputHandler`), so a press fires the mapped action exactly once regardless of which path delivers it first.

### The NX_SYSDEFINED hack (media keys)

macOS has no public API for synthesizing or intercepting media keys (Play/Pause, Next, Previous, Volume, Mute). Both `MediaKeyInterceptor` and `MediaController` rely on the same undocumented `NSSystemDefined` event format used internally by the Human Interface Device stack:

- **Event type** `NX_SYSDEFINED` (raw value `14`) with **subtype `8`**.
- **Key code and state packed into `data1`** as a bitfield: `(nxKeyCode << 16) | (keyState << 8)`, where `0xA` = key down and `0xB` = key up.
- **Magic `modifierFlags`** (`0xa00` for down, `0xb00` for up) mirror the state nibble — real media key events arrive with these flags, and some consumers (e.g. Music.app) won't accept posted events without them.

`MediaKeyInterceptor` installs a **`.cghidEventTap`** at `.headInsertEventTap` so it sees `NX_SYSDEFINED` events *before* the system dispatcher routes them to Music/iTunes/etc. — a session-level tap would arrive too late. It then manually unpacks `data1` to recover the key code and down/up state. The tap is automatically re-enabled on `tapDisabledByTimeout`, `tapDisabledByUserInput`, and `NSWorkspace.didWakeNotification`, because macOS silently disables event taps across sleep/wake and input stalls.

`MediaController` goes the other way: it **fabricates** matching `NSSystemDefined` events via `NSEvent.otherEvent(...)` with the same magic flags, subtype, and `data1` packing, then posts the underlying `CGEvent` to the session tap. A **`usleep(50_000)`** gap between the down and up events is required — without the 50 ms pause, macOS coalesces or drops the pair and the media key is ignored.

This is the standard reverse-engineered technique (originally surfaced in projects like SPMediaKeyTap and Noteify), but it is entirely undocumented and can change without notice in any macOS release.

---

## Caveats

- Uses Apple's **private `MultitouchSupport` framework** — not App Store compatible; Apple may change or remove this API in future macOS releases.
- **NX_SYSDEFINED media-key synthesis and interception is undocumented** — relies on magic modifier-flag values (`0xa00`/`0xb00`), subtype `8`, and a manual `data1` bitfield layout. Apple could break this in any release.

### Long-term direction: Xbox Adaptive Joystick

Between the private `MultitouchSupport` framework and the undocumented `NX_SYSDEFINED` plumbing, the Siri Remote path is built on two proprietary, reverse-engineered interfaces that Apple can break at any time. HyperVibe may migrate its primary input to the **Xbox Adaptive Joystick**, which speaks standard USB HID / GameController.framework and avoids every proprietary hazard above. That gives a more permanent, App Store–viable foundation — and, as a bonus, a genuinely accessible input device — while the Siri Remote support remains as a best-effort path for users who already own one.
- Tested on **Siri Remote 1st-gen (A1513, product ID `0x266`)**. Button HID codes are a superset likely to cover the 2nd-gen Siri Remote (A2540) as well, but its click-ring directional presses and dedicated Mute button are not yet mapped in `identifyButton`.
- Ad-hoc signing ties TCC permission grants to the exact binary hash — rebuilds may require re-approval in System Settings.

---

## Credits and License

 **Fork & improvements.** HyperVibe is built on top of [Remotastic](https://github.com/lauschue/Remotastic) by [@lauschue](https://github.com/lauschue), which provided the foundational Siri-Remote HID handling, MultitouchSupport integration, and menu-bar scaffolding. HyperVibe extends it with configurable Claude Code workflows, keyboard shortcuts, push-to-talk and swipe gesture.
- License: see `LICENSE`.
- Diagram icons from [The Noun Project](https://thenounproject.com/):
  - [Arrow Up by Dayeong Kim](https://thenounproject.com/icon/arrow-up-6066125/)
  - [Microphone by Alvida](https://thenounproject.com/icon/microphone-8162320/)
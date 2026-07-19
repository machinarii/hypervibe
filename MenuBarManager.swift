//
//  MenuBarManager.swift
//  HyperVibe
//
//  Manages the menu bar icon and menu
//

import AppKit
import Carbon.HIToolbox

// Button actions that can be assigned
enum ButtonAction: String, CaseIterable {
    case enterKey = "Enter: Submit prompt"
    case upKey = "Up: Navigate Up"
    case downKey = "Down: Navigate Down"
    case escKey = "Esc: Navigate Back"
    case ctrlC = "Control + C: Cancel Prompt"
    case spaceKey = "Space: Claude Voice Dictation"
    case rightCmd = "Right Command: 3rd-party Voice Dictation"
    case rightOpt = "Right Option: 3rd-party Voice Dictation"
    case trackpadClick = "Mouse Click"
    case scrollUp = "Scroll Up"
    case scrollDown = "Scroll Down"
    case none = "None"

    /// Push-to-talk dictation needs the virtual key held for the full press duration.
    /// Only a subset of HID buttons emit reliable release events, so these actions are
    /// only offered for hold-capable buttons.
    var requiresHold: Bool {
        switch self {
        case .spaceKey, .rightCmd, .rightOpt: return true
        default: return false
        }
    }

    /// Actions that auto-repeat while the button is held (scroll). Offered on all
    /// buttons — on tap-only buttons they fire a single step per press.
    var repeatsWhileHeld: Bool {
        switch self {
        case .scrollUp, .scrollDown: return true
        default: return false
        }
    }
}

/// A button's assignment: a built-in action or a user-captured custom keystroke.
/// Persisted as the ButtonAction rawValue, or "customKey:<code>:<flagsHex>:<display>".
enum AssignedAction: Equatable {
    case builtin(ButtonAction)
    case customKey(keyCode: Int, flags: CGEventFlags, display: String)

    var persisted: String {
        switch self {
        case .builtin(let a): return a.rawValue
        case .customKey(let code, let flags, let display):
            return "customKey:\(code):\(String(flags.rawValue, radix: 16)):\(display)"
        }
    }

    static func from(persisted raw: String) -> AssignedAction? {
        if let builtin = ButtonAction(rawValue: raw) { return .builtin(builtin) }
        guard raw.hasPrefix("customKey:") else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let code = Int(parts[1]),
              let flagsRaw = UInt64(parts[2], radix: 16) else { return nil }
        return .customKey(keyCode: code, flags: CGEventFlags(rawValue: flagsRaw), display: String(parts[3]))
    }
}

/// A swipe's assignment: a built-in action or a user-entered text command.
/// Persisted as the SwipeAction rawValue, or "customCmd:<text>".
enum AssignedSwipe: Equatable {
    case builtin(SwipeAction)
    case customCmd(String)

    var persisted: String {
        switch self {
        case .builtin(let a): return a.rawValue
        case .customCmd(let text): return "customCmd:\(text)"
        }
    }

    static func from(persisted raw: String) -> AssignedSwipe? {
        if let builtin = SwipeAction(rawValue: raw) { return .builtin(builtin) }
        guard raw.hasPrefix("customCmd:") else { return nil }
        return .customCmd(String(raw.dropFirst("customCmd:".count)))
    }
}

/// HID buttons whose driver emits both press (value=1) and release (value=0) — verified via /tmp/hypervibe.log.
/// menu/tv/select are excluded: menu/tv are press-only on the Siri Remote, select is handled separately for click/drag.
let holdCapableButtons: Set<String> = ["playPause", "volumeUp", "volumeDown", "siri"]

/// Trackpad swipe directions (single-finger flicks). Detection happens in TouchHandler;
/// execution is dispatched here so mappings live alongside button mappings.
enum SwipeDirection: String, CaseIterable {
    case up, down, left, right
}

/// Action a swipe can trigger. Slash-command cases type the raw value (without Enter — user
/// presses Enter themselves). `leftArrow`/`rightArrow` send virtual arrow keys instead of text.
/// `init` is a Swift keyword so the case name is backtick-escaped; rawValue "/init" is what displays.
enum SwipeAction: String, CaseIterable {
    // Priority order: direction-matched arrow (filtered per submenu), then Mode Switching,
    // then ultrathink, then slash commands alphabetically, None last.
    case leftArrow     = "Left: Navigate Left"
    case rightArrow    = "Right: Navigate Right"
    case modeSwitch    = "Mode Switching (Shift + Tab)"
    case ultrathink    = "ultrathink"
    case btw           = "/btw"
    case compact       = "/compact"
    case config        = "/config"
    case context       = "/context"
    case effort        = "/effort"
    case `init`        = "/init"
    case model         = "/model"
    case remoteControl = "/remote-control"
    case schedule      = "/schedule"
    case tasks         = "/tasks"
    case usage         = "/usage"
    case none          = "None"
}

// Scroll speed options
enum ScrollSpeed: String, CaseIterable {
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"
    
    var scale: CGFloat {
        switch self {
        case .slow: return 150.0
        case .medium: return 300.0
        case .fast: return 500.0
        }
    }
}

class MenuBarManager {
    
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    
    // Button mappings (stored in UserDefaults)
    private var buttonMappings: [String: AssignedAction] = [:]

    // Swipe gesture mappings (stored in UserDefaults under "swipeMappings").
    private var swipeMappings: [SwipeDirection: AssignedSwipe] = [:]

    // Retained while a capture panel is open.
    private let keyCapture = KeyCaptureController()

    private static let defaultSwipeMappings: [SwipeDirection: AssignedSwipe] = [
        .up:    .builtin(.usage),
        .down:  .builtin(.compact),
        .left:  .builtin(.model),
        .right: .builtin(.modeSwitch),
    ]

    // Scroll speed (used for trackpad scroll scale; no menu, native multitouch)
    private(set) var scrollSpeed: ScrollSpeed = .medium

    /// Set by app delegate so menu bar can delegate media actions to MediaController.
    var mediaController: MediaController?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
        
        loadMappings()
        loadSwipeMappings()
        // Touchpad mode (default: full cursor + gestures).
        if UserDefaults.standard.object(forKey: "touchpadCursorEnabled") != nil {
            TouchHandler.cursorEnabled = UserDefaults.standard.bool(forKey: "touchpadCursorEnabled")
        }
        setupMenuBar()
    }

    @objc private func setTouchpadMode(_ sender: NSMenuItem) {
        guard let enabled = sender.representedObject as? Bool else { return }
        TouchHandler.cursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "touchpadCursorEnabled")
        rebuildMenu()
    }
    
    private func loadMappings() {
        // Default mappings (only used on first launch / after schema upgrade)
        let defaultMappings: [String: AssignedAction] = [
            "playPause": .builtin(.enterKey),
            "menu": .builtin(.escKey),
            "select": .builtin(.trackpadClick),
            "volumeUp": .builtin(.upKey),
            "volumeDown": .builtin(.downKey),
            "siri": .builtin(.spaceKey),
            "tv": .builtin(.ctrlC)
        ]

        // Schema version bumps:
        //   v3: old media-key actions removed — drop all saved button mappings
        //   v4: "select" default changed from .enterKey to .trackpadClick — reset just that entry
        let currentSchema = 4
        let savedSchema = UserDefaults.standard.integer(forKey: "buttonMappingsSchema")
        if savedSchema < 3 {
            UserDefaults.standard.removeObject(forKey: "buttonMappings")
        } else if savedSchema < 4 {
            // Targeted migration: reset "select" so the new default applies, preserve others.
            if var saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
                saved.removeValue(forKey: "select")
                UserDefaults.standard.set(saved, forKey: "buttonMappings")
            }
        }
        if savedSchema < currentSchema {
            UserDefaults.standard.set(currentSchema, forKey: "buttonMappingsSchema")
        }

        if let saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
            for (button, actionRaw) in saved {
                if let action = AssignedAction.from(persisted: actionRaw) {
                    buttonMappings[button] = action
                }
            }
            for (button, action) in defaultMappings {
                if buttonMappings[button] == nil {
                    buttonMappings[button] = action
                }
            }
            // Defensive: if a hold-required action got persisted against a tap-only button, reset to none.
            for (button, action) in buttonMappings {
                if case .builtin(let builtin) = action,
                   builtin.requiresHold, !holdCapableButtons.contains(button) {
                    buttonMappings[button] = .builtin(.none)
                }
            }
        } else {
            buttonMappings = defaultMappings
            saveMappings()
        }
    }

    private func saveMappings() {
        var toSave: [String: String] = [:]
        for (button, action) in buttonMappings {
            toSave[button] = action.persisted
        }
        UserDefaults.standard.set(toSave, forKey: "buttonMappings")
    }
    
    /// Procedurally draw the menu-bar icon — a walkie-talkie glyph mirroring the
    /// Figma reference (36-unit viewBox: antenna + body with display + speaker
    /// holes via even-odd fill). 2× centered scale matches the menu-bar reading
    /// size; overflow clips at the canvas edges by design.
    private static func makeWaveIcon() -> NSImage {
        let pt: CGFloat = 18
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width

            ctx.translateBy(x: s / 2, y: s / 2)
            ctx.scaleBy(x: 2, y: 2)
            ctx.translateBy(x: -s / 2, y: -s / 2)

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            let antenna = CGRect(x: 0.5260 * s, y: 0.1944 * s,
                                 width: 0.0638 * s, height: 0.1594 * s)
            let body    = CGRect(x: 0.3348 * s, y: 0.3538 * s,
                                 width: 0.3187 * s, height: 0.4462 * s)
            let display = CGRect(x: 0.3986 * s, y: 0.6406 * s,
                                 width: 0.1911 * s, height: 0.0956 * s)
            let speakerR: CGFloat = 0.0956 * s
            let speaker = CGRect(x: 0.4942 * s - speakerR, y: 0.5131 * s - speakerR,
                                 width: 2 * speakerR, height: 2 * speakerR)

            let path = CGMutablePath()
            path.addPath(CGPath(roundedRect: antenna,
                                cornerWidth: 0.0278 * s, cornerHeight: 0.0278 * s, transform: nil))
            path.addPath(CGPath(roundedRect: body,
                                cornerWidth: 0.0556 * s, cornerHeight: 0.0556 * s, transform: nil))
            path.addPath(CGPath(roundedRect: display,
                                cornerWidth: 0.0278 * s, cornerHeight: 0.0278 * s, transform: nil))
            path.addEllipse(in: speaker)

            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupMenuBar() {
        // Configure the button (the visible icon in menu bar)
        guard let button = statusItem.button else {
            return
        }
        
        button.image = Self.makeWaveIcon()
        button.title = ""
        
        rebuildMenu()
        statusItem.menu = menu
    }
    
    private func rebuildMenu() {
        menu.removeAllItems()
        
        // Title
        let titleItem = NSMenuItem(title: "Siri Remote", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Status
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Button Mappings submenu
        let mappingsItem = NSMenuItem(title: "Button Mappings", action: nil, keyEquivalent: "")
        let mappingsSubmenu = NSMenu()
        
        let buttons = [
            ("select", "Trackpad Click"),
            ("menu", "Menu Button"),
            ("tv", "TV Button"),
            ("siri", "Siri Button"),
            ("playPause", "Play/Pause Button"),
            ("volumeUp", "Volume Up"),
            ("volumeDown", "Volume Down"),
        ]
        
        for (key, label) in buttons {
            let buttonItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let actionSubmenu = NSMenu()
            let canHold = holdCapableButtons.contains(key)

            for action in ButtonAction.allCases {
                // Voice-dictation actions require press+release tracking; hide them on tap-only buttons.
                if action.requiresHold && !canHold { continue }
                // Mouse Click is only meaningful for the trackpad click button.
                if action == .trackpadClick && key != "select" { continue }

                let actionItem = NSMenuItem(title: action.rawValue, action: #selector(changeMapping(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = (key, action)

                if buttonMappings[key] == .builtin(action) {
                    actionItem.state = .on
                }

                actionSubmenu.addItem(actionItem)
            }

            // Custom keystroke assignment. Not offered for "select": its press is consumed
            // by click/drag handling before mappings are consulted.
            if key != "select" {
                actionSubmenu.addItem(NSMenuItem.separator())
                if case .customKey(_, _, let display)? = buttonMappings[key] {
                    let current = NSMenuItem(title: "Custom: \(display)", action: nil, keyEquivalent: "")
                    current.state = .on
                    actionSubmenu.addItem(current)
                }
                let captureItem = NSMenuItem(title: "Custom Key…", action: #selector(captureCustomKey(_:)), keyEquivalent: "")
                captureItem.target = self
                captureItem.representedObject = (key, label)
                actionSubmenu.addItem(captureItem)
            }

            buttonItem.submenu = actionSubmenu
            mappingsSubmenu.addItem(buttonItem)
        }
        
        mappingsItem.submenu = mappingsSubmenu
        menu.addItem(mappingsItem)

        // Swipe Gestures submenu
        let swipeItem = NSMenuItem(title: "Swipe Gestures", action: nil, keyEquivalent: "")
        let swipeSubmenu = NSMenu()
        let swipes: [(SwipeDirection, String)] = [
            (.up,    "Swipe Up"),
            (.down,  "Swipe Down"),
            (.left,  "Swipe Left"),
            (.right, "Swipe Right"),
        ]
        for (direction, label) in swipes {
            let dirItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let actionsMenu = NSMenu()
            for action in SwipeAction.allCases {
                // Each arrow-key action only appears on its matching swipe direction.
                if action == .leftArrow  && direction != .left  { continue }
                if action == .rightArrow && direction != .right { continue }

                let actionItem = NSMenuItem(title: action.rawValue, action: #selector(changeSwipeMapping(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = (direction, action)
                if swipeMappings[direction] == .builtin(action) {
                    actionItem.state = .on
                }
                actionsMenu.addItem(actionItem)
            }

            // Custom text command (typed verbatim on swipe).
            actionsMenu.addItem(NSMenuItem.separator())
            if case .customCmd(let text)? = swipeMappings[direction] {
                let current = NSMenuItem(title: "Custom: \(text)", action: nil, keyEquivalent: "")
                current.state = .on
                actionsMenu.addItem(current)
            }
            let promptItem = NSMenuItem(title: "Custom Command…", action: #selector(promptCustomCommand(_:)), keyEquivalent: "")
            promptItem.target = self
            promptItem.representedObject = (direction, label)
            actionsMenu.addItem(promptItem)

            dirItem.submenu = actionsMenu
            swipeSubmenu.addItem(dirItem)
        }
        swipeItem.submenu = swipeSubmenu
        menu.addItem(swipeItem)

        // Touchpad mode: full (cursor + gestures) vs gestures-only (no cursor, no tap-click).
        let modeItem = NSMenuItem(title: "Touchpad Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        let fullItem = NSMenuItem(title: "Cursor + Gestures", action: #selector(setTouchpadMode(_:)), keyEquivalent: "")
        fullItem.target = self
        fullItem.representedObject = true
        fullItem.state = TouchHandler.cursorEnabled ? .on : .off
        modeMenu.addItem(fullItem)
        let gesturesItem = NSMenuItem(title: "Gestures Only (no cursor)", action: #selector(setTouchpadMode(_:)), keyEquivalent: "")
        gesturesItem.target = self
        gesturesItem.representedObject = false
        gesturesItem.state = TouchHandler.cursorEnabled ? .off : .on
        modeMenu.addItem(gesturesItem)
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc private func changeMapping(_ sender: NSMenuItem) {
        guard let (buttonKey, action) = sender.representedObject as? (String, ButtonAction) else {
            return
        }
        buttonMappings[buttonKey] = .builtin(action)
        saveMappings()
        rebuildMenu()
    }

    @objc private func changeSwipeMapping(_ sender: NSMenuItem) {
        guard let (direction, action) = sender.representedObject as? (SwipeDirection, SwipeAction) else {
            return
        }
        swipeMappings[direction] = .builtin(action)
        saveSwipeMappings()
        rebuildMenu()
    }

    @objc private func captureCustomKey(_ sender: NSMenuItem) {
        guard let (buttonKey, label) = sender.representedObject as? (String, String) else { return }
        keyCapture.begin(forButtonLabel: label) { [weak self] captured in
            guard let self = self, let captured = captured else { return }
            self.buttonMappings[buttonKey] = .customKey(keyCode: captured.keyCode,
                                                        flags: captured.flags,
                                                        display: captured.display)
            self.saveMappings()
            self.rebuildMenu()
        }
    }

    @objc private func promptCustomCommand(_ sender: NSMenuItem) {
        guard let (direction, label) = sender.representedObject as? (SwipeDirection, String) else { return }
        let alert = NSAlert()
        alert.messageText = "Custom Command — \(label)"
        alert.informativeText = "Whatever you enter is typed into the focused window, exactly as written."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        if case .customCmd(let existing)? = swipeMappings[direction] {
            field.stringValue = existing
        } else {
            field.stringValue = "/"
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            // Keep the text verbatim — leading/trailing spaces are intentional (e.g. a
            // slash command plus trailing space, ready for dictation). Trim only to
            // reject an effectively-empty entry.
            let text = field.stringValue
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            swipeMappings[direction] = .customCmd(text)
            saveSwipeMappings()
            rebuildMenu()
        }
    }
    
    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusMenuItem.title = connected ? "Status: Connected ✓" : "Status: Disconnected"
            self.statusItem.button?.appearsDisabled = !connected
        }
    }
    
    func getMapping(for button: String) -> AssignedAction {
        return buttonMappings[button] ?? .builtin(.none)
    }
    
    // Map HID codes to button names
    private let hidCodeToButton: [String: String] = [
        "0x000C:0x00CD": "playPause",    // Play/Pause
        "0x000C:0x00B5": "nextTrack",    // Next (not a physical button but for mapping)
        "0x000C:0x00B6": "prevTrack",    // Previous (not a physical button but for mapping)
        "0x000C:0x00E9": "volumeUp",     // Volume Up
        "0x000C:0x00EA": "volumeDown",   // Volume Down
        "0x0001:0x0086": "menu",         // Menu button (System Menu Main)
        "0x000C:0x0080": "select",       // Select button
        "0x000C:0x0040": "menu",         // Menu (alternate)
        "0x000C:0x0223": "menu",         // Home
        "0x000C:0x0224": "back",         // Back
    ]
    
    /// Get the action name for a given HID code (for event interception)
    func getMappingForHIDCode(_ hidCode: String) -> String? {
        guard let buttonName = hidCodeToButton[hidCode],
              let action = buttonMappings[buttonName] else {
            return nil
        }
        return action.persisted
    }
    
    private func loadSwipeMappings() {
        if let saved = UserDefaults.standard.dictionary(forKey: "swipeMappings") as? [String: String] {
            for (dirRaw, actionRaw) in saved {
                if let dir = SwipeDirection(rawValue: dirRaw),
                   let act = AssignedSwipe.from(persisted: actionRaw) {
                    swipeMappings[dir] = act
                }
            }
        }
        // Fill any missing directions with defaults.
        for (dir, act) in Self.defaultSwipeMappings where swipeMappings[dir] == nil {
            swipeMappings[dir] = act
        }
    }

    private func saveSwipeMappings() {
        var toSave: [String: String] = [:]
        for (dir, act) in swipeMappings {
            toSave[dir.rawValue] = act.persisted
        }
        UserDefaults.standard.set(toSave, forKey: "swipeMappings")
    }

    func getSwipeMapping(for direction: SwipeDirection) -> AssignedSwipe {
        return swipeMappings[direction] ?? .builtin(.none)
    }

    /// Execute the action bound to a swipe direction. Slash-command actions type text
    /// (no Enter — user presses Enter themselves). Arrow/modifier actions send key events.
    func executeSwipe(_ direction: SwipeDirection) {
        switch swipeMappings[direction] ?? .builtin(.none) {
        case .customCmd(let text):
            // User-entered text, typed verbatim (no Enter — same convention as built-ins).
            typeString(text)
        case .builtin(let action):
            switch action {
            case .none:
                break
            case .leftArrow:
                sendKey(kVK_LeftArrow)
            case .rightArrow:
                sendKey(kVK_RightArrow)
            case .modeSwitch:
                sendKey(kVK_Tab, flags: .maskShift)
            case .btw, .schedule, .ultrathink:
                // Trailing space: user typically continues with an argument or prose.
                typeString(action.rawValue + " ")
            case .compact, .config, .context, .effort, .`init`,
                 .model, .remoteControl, .tasks, .usage:
                // No trailing space: these commands stand alone or open an interactive picker.
                typeString(action.rawValue)
            }
        }
    }

    /// Post the given string as a single keyboard event via `keyboardSetUnicodeString`.
    /// Works across terminals and most text fields; bypasses layout-specific key codes.
    private func typeString(_ s: String) {
        let utf16 = Array(s.utf16)
        let count = utf16.count
        guard count > 0 else { return }
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
            down?.post(tap: .cghidEventTap)
            usleep(5000)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Execute an action by persisted name (built-in rawValue or custom-key spec).
    func executeAction(_ actionName: String) {
        guard let assigned = AssignedAction.from(persisted: actionName) else { return }

        switch assigned {
        case .customKey(let keyCode, let flags, _):
            sendKey(keyCode, flags: flags)
        case .builtin(let action):
            switch action {
            case .none:
                break
            case .enterKey:
                sendKey(kVK_Return)
            case .upKey:
                sendKey(kVK_UpArrow)
            case .downKey:
                sendKey(kVK_DownArrow)
            case .escKey:
                sendKey(kVK_Escape)
            case .ctrlC:
                sendKey(kVK_ANSI_C, flags: .maskControl)
            case .spaceKey:
                sendKey(kVK_Space)
            case .rightCmd:
                sendModifierTap(kVK_RightCommand, flag: .maskCommand)
            case .rightOpt:
                sendModifierTap(kVK_RightOption, flag: .maskAlternate)
            case .trackpadClick:
                performClick()
            case .scrollUp:
                Self.postScroll(lines: 3)
            case .scrollDown:
                Self.postScroll(lines: -3)
            }
        }
    }

    /// Post a synthetic scroll-wheel event. Positive lines scroll up (content down).
    static func postScroll(lines: Int32) {
        let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
                            units: .line, wheelCount: 1,
                            wheel1: lines, wheel2: 0, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    private func performClick() {
        let pos = NSEvent.mouseLocation
        let screenH = NSScreen.main?.frame.height ?? 0
        let cgPos = CGPoint(x: pos.x, y: screenH - pos.y)

        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cgPos, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cgPos, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }

    /// Tap a modifier key alone (e.g. Right Command) — used to trigger push-to-talk dictation.
    private func sendModifierTap(_ keyCode: Int, flag: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = flag
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
    }
    
    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }
}

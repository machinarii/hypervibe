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
    case none = "None"
    case enterKey = "Enter: Submit prompt"
    case upKey = "Up: Navigate Up"
    case downKey = "Down: Navigate Down"
    case escKey = "Esc: Navigate Back"
    case ctrlC = "Control + C: Cancel Prompt"
    case spaceKey = "Space: Claude Voice Dictation"
    case rightCmd = "Right Command: 3rd-party Voice Dictation"
    case rightOpt = "Right Option: 3rd-party Voice Dictation"
    case trackpadClick = "Trackpad Click"

    /// Push-to-talk dictation needs the virtual key held for the full press duration.
    /// Only a subset of HID buttons emit reliable release events, so these actions are
    /// only offered for hold-capable buttons.
    var requiresHold: Bool {
        switch self {
        case .spaceKey, .rightCmd, .rightOpt: return true
        default: return false
        }
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
    private var buttonMappings: [String: ButtonAction] = [:]

    // Swipe gesture mappings (stored in UserDefaults under "swipeMappings").
    private var swipeMappings: [SwipeDirection: SwipeAction] = [:]

    private static let defaultSwipeMappings: [SwipeDirection: SwipeAction] = [
        .up:    .usage,
        .down:  .compact,
        .left:  .model,
        .right: .modeSwitch,
    ]

    // Scroll speed (used for trackpad scroll scale; no menu, native multitouch)
    private(set) var scrollSpeed: ScrollSpeed = .medium

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
        
        loadMappings()
        loadSwipeMappings()
        setupMenuBar()
    }
    
    private func loadMappings() {
        // Default mappings (only used on first launch / after schema upgrade)
        let defaultMappings: [String: ButtonAction] = [
            "playPause": .enterKey,
            "menu": .escKey,
            "select": .trackpadClick,
            "volumeUp": .upKey,
            "volumeDown": .downKey,
            "siri": .spaceKey,
            "tv": .ctrlC
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
                if let action = ButtonAction(rawValue: actionRaw) {
                    buttonMappings[button] = action
                }
            }
            for (button, action) in defaultMappings {
                if buttonMappings[button] == nil {
                    buttonMappings[button] = action
                }
            }
            // Defensive: if a hold-required action got persisted against a tap-only button, reset to none.
            for (button, action) in buttonMappings where action.requiresHold && !holdCapableButtons.contains(button) {
                buttonMappings[button] = ButtonAction.none
            }
        } else {
            buttonMappings = defaultMappings
            saveMappings()
        }
    }
    
    private func saveMappings() {
        var toSave: [String: String] = [:]
        for (button, action) in buttonMappings {
            toSave[button] = action.rawValue
        }
        UserDefaults.standard.set(toSave, forKey: "buttonMappings")
    }
    
    /// Draw a walkie-talkie silhouette for the menu-bar icon. Template image → auto-tinted by macOS.
    /// Body is filled with even-odd rule so the display and speaker openings are transparent holes.
    private static func makeWaveIcon() -> NSImage {
        // Scaled 20% down from the original 16×22 design; antenna is thicker relative to the body.
        let scale: CGFloat = 0.8
        let size = NSSize(width: 16 * scale, height: 22 * scale)
        let image = NSImage(size: size, flipped: false) { rect in
            // Coordinate system: origin bottom-left. All rects scaled uniformly.
            let bodyRect    = NSRect(x: 2 * scale,  y: 0,            width: 12 * scale, height: 16 * scale)
            let displayRect = NSRect(x: 4 * scale,  y: 12 * scale,   width: 8 * scale,  height: 2.4 * scale)
            let speakerRect = NSRect(x: 5 * scale,  y: 2 * scale,    width: 6 * scale,  height: 6 * scale)
            let bodyRadius:    CGFloat = 1.6 * scale
            let displayRadius: CGFloat = 0.5 * scale

            // Body + cutouts as one even-odd path so the holes are truly transparent (required for template tinting).
            let body = NSBezierPath()
            body.appendRoundedRect(bodyRect, xRadius: bodyRadius, yRadius: bodyRadius)
            body.appendRoundedRect(displayRect, xRadius: displayRadius, yRadius: displayRadius)
            body.appendOval(in: speakerRect)
            body.windingRule = .evenOdd
            NSColor.black.setFill()
            body.fill()

            // Single antenna rising from left-of-center. Line width is not scaled down with the
            // body — boosted to 1.6pt so it reads thicker than the original 1.2pt despite the 20% shrink.
            NSColor.black.setStroke()
            let antenna = NSBezierPath()
            antenna.lineWidth = 1.6
            antenna.lineCapStyle = .round
            antenna.move(to: NSPoint(x: 5.5 * scale, y: 16 * scale))
            antenna.line(to: NSPoint(x: 5.5 * scale, y: 21.2 * scale))
            antenna.stroke()

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

                let actionItem = NSMenuItem(title: action.rawValue, action: #selector(changeMapping(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = (key, action)

                if buttonMappings[key] == action {
                    actionItem.state = .on
                }

                actionSubmenu.addItem(actionItem)
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
                if swipeMappings[direction] == action {
                    actionItem.state = .on
                }
                actionsMenu.addItem(actionItem)
            }
            dirItem.submenu = actionsMenu
            swipeSubmenu.addItem(dirItem)
        }
        swipeItem.submenu = swipeSubmenu
        menu.addItem(swipeItem)

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
        buttonMappings[buttonKey] = action
        saveMappings()
        rebuildMenu()
    }

    @objc private func changeSwipeMapping(_ sender: NSMenuItem) {
        guard let (direction, action) = sender.representedObject as? (SwipeDirection, SwipeAction) else {
            return
        }
        swipeMappings[direction] = action
        saveSwipeMappings()
        rebuildMenu()
    }
    
    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusMenuItem.title = connected ? "Status: Connected ✓" : "Status: Disconnected"
            self.statusItem.button?.appearsDisabled = !connected
        }
    }
    
    func getMapping(for button: String) -> ButtonAction {
        return buttonMappings[button] ?? .none
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
        return action.rawValue
    }
    
    private func loadSwipeMappings() {
        if let saved = UserDefaults.standard.dictionary(forKey: "swipeMappings") as? [String: String] {
            for (dirRaw, actionRaw) in saved {
                if let dir = SwipeDirection(rawValue: dirRaw),
                   let act = SwipeAction(rawValue: actionRaw) {
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
            toSave[dir.rawValue] = act.rawValue
        }
        UserDefaults.standard.set(toSave, forKey: "swipeMappings")
    }

    func getSwipeMapping(for direction: SwipeDirection) -> SwipeAction {
        return swipeMappings[direction] ?? .none
    }

    /// Execute the action bound to a swipe direction. Slash-command actions type text
    /// (no Enter — user presses Enter themselves). Arrow/modifier actions send key events.
    func executeSwipe(_ direction: SwipeDirection) {
        let action = swipeMappings[direction] ?? SwipeAction.none
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

    /// Execute an action by name
    func executeAction(_ actionName: String) {
        guard let action = ButtonAction(rawValue: actionName) else { return }

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
        }
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

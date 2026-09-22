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
    case customShortcut = "Custom Shortcut"
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
}

/// A keyboard shortcut recorded from the user. Modifier key codes are stored directly so
/// left and right Command/Option/Control/Shift remain distinct when replayed.
private struct CustomShortcut: Codable {
    let keyCode: UInt16?
    let keyDisplay: String?
    let modifierKeyCodes: [UInt16]

    var displayName: String {
        let modifiers = modifierKeyCodes.map(Self.modifierDisplay).joined(separator: " + ")
        let key = keyDisplay ?? ""
        if modifiers.isEmpty { return key }
        if key.isEmpty { return modifiers }
        return "\(modifiers) + \(key)"
    }

    private static func modifierDisplay(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Command:      return "Left Command"
        case kVK_RightCommand: return "Right Command"
        case kVK_Option:       return "Left Option"
        case kVK_RightOption:  return "Right Option"
        case kVK_Control:      return "Left Control"
        case kVK_RightControl: return "Right Control"
        case kVK_Shift:        return "Left Shift"
        case kVK_RightShift:   return "Right Shift"
        case kVK_Function:     return "Fn"
        case kVK_CapsLock:     return "Caps Lock"
        default:               return "Key \(keyCode)"
        }
    }
}

/// Collects one shortcut while an alert is open. It records physical modifier key codes from
/// flagsChanged events, rather than only modifier flags, to preserve left/right modifiers.
private final class ShortcutRecorder {
    private static let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command), UInt16(kVK_RightCommand),
        UInt16(kVK_Option), UInt16(kVK_RightOption),
        UInt16(kVK_Control), UInt16(kVK_RightControl),
        UInt16(kVK_Shift), UInt16(kVK_RightShift),
        UInt16(kVK_Function), UInt16(kVK_CapsLock),
    ]

    private var recordedModifierKeyCodes: Set<UInt16> = []
    private(set) var shortcut: CustomShortcut?

    @discardableResult
    func record(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            guard Self.modifierKeyCodes.contains(event.keyCode) else { return false }
            recordedModifierKeyCodes.insert(event.keyCode)
            shortcut = CustomShortcut(
                keyCode: nil,
                keyDisplay: nil,
                modifierKeyCodes: orderedModifiers()
            )
            return true
        case .keyDown:
            guard !event.isARepeat else { return true }
            if Self.modifierKeyCodes.contains(event.keyCode) {
                recordedModifierKeyCodes.insert(event.keyCode)
                shortcut = CustomShortcut(
                    keyCode: nil,
                    keyDisplay: nil,
                    modifierKeyCodes: orderedModifiers()
                )
            } else {
                shortcut = CustomShortcut(
                    keyCode: event.keyCode,
                    keyDisplay: Self.displayName(for: event),
                    modifierKeyCodes: orderedModifiers()
                )
            }
            return true
        default:
            return false
        }
    }

    private func orderedModifiers() -> [UInt16] {
        recordedModifierKeyCodes.sorted()
    }

    private static func displayName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Return:       return "Return"
        case kVK_Tab:          return "Tab"
        case kVK_Space:        return "Space"
        case kVK_Delete:       return "Delete"
        case kVK_ForwardDelete:return "Forward Delete"
        case kVK_Escape:       return "Escape"
        case kVK_LeftArrow:    return "Left Arrow"
        case kVK_RightArrow:   return "Right Arrow"
        case kVK_UpArrow:      return "Up Arrow"
        case kVK_DownArrow:    return "Down Arrow"
        case kVK_Home:         return "Home"
        case kVK_End:          return "End"
        case kVK_PageUp:       return "Page Up"
        case kVK_PageDown:     return "Page Down"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
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

    // Custom keyboard shortcuts, stored separately from the built-in action selection.
    private var customShortcuts: [String: CustomShortcut] = [:]

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

    /// Set by app delegate so menu bar can delegate media actions to MediaController.
    var mediaController: MediaController?

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

        loadCustomShortcuts()

        // Schema version bumps:
        //   v3: old media-key actions removed — drop all saved button mappings
        //   v4: "select" default changed from .enterKey to .trackpadClick — reset just that entry
        //   v5: custom shortcut mappings added (no migration needed)
        let currentSchema = 5
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
            // A saved custom action without its accompanying shortcut cannot be dispatched.
            for (button, action) in buttonMappings where action == .customShortcut && customShortcuts[button] == nil {
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
        saveCustomShortcuts()
    }

    private func loadCustomShortcuts() {
        guard let data = UserDefaults.standard.data(forKey: "customButtonShortcuts") else { return }
        customShortcuts = (try? JSONDecoder().decode([String: CustomShortcut].self, from: data)) ?? [:]
    }

    private func saveCustomShortcuts() {
        guard let data = try? JSONEncoder().encode(customShortcuts) else { return }
        UserDefaults.standard.set(data, forKey: "customButtonShortcuts")
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
                // Trackpad Click remains reserved for pointer click/drag behavior.
                if action == .customShortcut && key == "select" { continue }

                let isCustomShortcut = action == .customShortcut
                let actionTitle: String
                if isCustomShortcut, let shortcut = customShortcuts[key] {
                    actionTitle = "Custom: \(shortcut.displayName)"
                } else {
                    actionTitle = action.rawValue + (isCustomShortcut ? "…" : "")
                }
                let actionItem = NSMenuItem(
                    title: actionTitle,
                    action: isCustomShortcut ? #selector(editCustomShortcut(_:)) : #selector(changeMapping(_:)),
                    keyEquivalent: ""
                )
                actionItem.target = self
                actionItem.representedObject = isCustomShortcut ? key : (key, action)

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
        customShortcuts.removeValue(forKey: buttonKey)
        saveMappings()
        rebuildMenu()
    }

    @objc private func editCustomShortcut(_ sender: NSMenuItem) {
        guard let buttonKey = sender.representedObject as? String else { return }

        let alert = NSAlert()
        alert.messageText = "Custom Shortcut"
        alert.informativeText = "Press any key combination, then click Save. Escape is recorded as a shortcut."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")

        let recordingLabel = NSTextField(labelWithString: "Waiting for shortcut…")
        recordingLabel.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        alert.accessoryView = recordingLabel
        alert.buttons.first?.isEnabled = false

        let recorder = ShortcutRecorder()
        guard let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged],
            handler: { event in
                guard recorder.record(event) else { return event }
                if let shortcut = recorder.shortcut {
                    recordingLabel.stringValue = shortcut.displayName
                    alert.buttons.first?.isEnabled = true
                }
                return nil
            }
        ) else { return }
        defer { NSEvent.removeMonitor(monitor) }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let shortcut = recorder.shortcut else { return }
            buttonMappings[buttonKey] = .customShortcut
            customShortcuts[buttonKey] = shortcut
        case .alertThirdButtonReturn:
            buttonMappings[buttonKey] = ButtonAction.none
            customShortcuts.removeValue(forKey: buttonKey)
        default:
            return
        }
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

    func executeCustomShortcut(for button: String) {
        guard let shortcut = customShortcuts[button] else { return }
        sendShortcut(shortcut)
    }

    func executeButtonMapping(for button: String) {
        let action = getMapping(for: button)
        if action == .customShortcut {
            executeCustomShortcut(for: button)
        } else {
            executeAction(action.rawValue)
        }
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
        case .customShortcut:
            break // dispatched with the button key by executeButtonMapping(for:)
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

    private func sendShortcut(_ shortcut: CustomShortcut) {
        var activeModifiers: [UInt16] = []
        for keyCode in shortcut.modifierKeyCodes {
            activeModifiers.append(keyCode)
            postKey(Int(keyCode), flags: flags(for: activeModifiers), keyDown: true)
        }

        if let keyCode = shortcut.keyCode {
            let flags = flags(for: activeModifiers)
            postKey(Int(keyCode), flags: flags, keyDown: true)
            usleep(10000)
            postKey(Int(keyCode), flags: flags, keyDown: false)
        } else {
            usleep(10000)
        }

        for keyCode in activeModifiers.reversed() {
            activeModifiers.removeLast()
            postKey(Int(keyCode), flags: flags(for: activeModifiers), keyDown: false)
        }
    }

    private func postKey(_ keyCode: Int, flags: CGEventFlags, keyDown: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func flags(for modifierKeyCodes: [UInt16]) -> CGEventFlags {
        modifierKeyCodes.reduce(into: []) { flags, keyCode in
            switch Int(keyCode) {
            case kVK_Command, kVK_RightCommand:
                flags.insert(.maskCommand)
            case kVK_Option, kVK_RightOption:
                flags.insert(.maskAlternate)
            case kVK_Control, kVK_RightControl:
                flags.insert(.maskControl)
            case kVK_Shift, kVK_RightShift:
                flags.insert(.maskShift)
            case kVK_Function:
                flags.insert(.maskSecondaryFn)
            case kVK_CapsLock:
                flags.insert(.maskAlphaShift)
            default:
                break
            }
        }
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

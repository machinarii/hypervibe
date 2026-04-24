//
//  MenuBarManager.swift
//  Remotastic
//
//  Manages the menu bar icon and menu
//

import AppKit
import Carbon.HIToolbox

// Button actions that can be assigned
enum ButtonAction: String, CaseIterable {
    case none = "None"
    case playPause = "Play/Pause"
    case nextTrack = "Next Track"
    case previousTrack = "Previous Track"
    case volumeUp = "Volume Up"
    case volumeDown = "Volume Down"
    case mute = "Mute"
    case click = "Mouse Click"
    case rightClick = "Right Click"
    case escape = "Escape"
    case space = "Space"
    case enter = "Enter"
    case missionControl = "Mission Control"
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
    
    // Scroll speed (used for trackpad scroll scale; no menu, native multitouch)
    private(set) var scrollSpeed: ScrollSpeed = .medium
    
    // Callback for when mappings change
    var onMappingsChanged: (([String: ButtonAction]) -> Void)?
    
    /// Set by app delegate so menu bar can delegate media actions to MediaController (one path for CLI and app).
    var mediaController: MediaController?
    
    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
        
        loadMappings()
        setupMenuBar()
    }
    
    private func loadMappings() {
        // Default mappings (only used on first launch)
        let defaultMappings: [String: ButtonAction] = [
            "playPause": .playPause,
            "menu": .missionControl,
            "select": .click,
            "volumeUp": .volumeUp,
            "volumeDown": .volumeDown,
            "siri": .space,
            "tv": .rightClick
        ]
        
        // Load saved mappings from UserDefaults
        if let saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
            // User has saved mappings - use those (migrate old "Toggle Trackpad Mode" to .escape)
            for (button, actionRaw) in saved {
                if let action = ButtonAction(rawValue: actionRaw) {
                    buttonMappings[button] = action
                } else if actionRaw == "Toggle Trackpad Mode" {
                    buttonMappings[button] = .escape
                }
            }
            // Fill in any missing buttons with defaults
            for (button, action) in defaultMappings {
                if buttonMappings[button] == nil {
                    buttonMappings[button] = action
                }
            }
            // One-time migration: Menu was default Escape; prefer Mission Control for Expose
            if buttonMappings["menu"] == .escape {
                buttonMappings["menu"] = .missionControl
                saveMappings()
            }
        } else {
            // First launch - use defaults
            buttonMappings = defaultMappings
            saveMappings() // Save defaults immediately
        }
    }
    
    private func saveMappings() {
        var toSave: [String: String] = [:]
        for (button, action) in buttonMappings {
            toSave[button] = action.rawValue
        }
        UserDefaults.standard.set(toSave, forKey: "buttonMappings")
        onMappingsChanged?(buttonMappings)
    }
    
    private func setupMenuBar() {
        // Configure the button (the visible icon in menu bar)
        guard let button = statusItem.button else {
            return
        }
        
        button.title = "SR"
        
        // Try SF Symbol if available
        if #available(macOS 11.0, *) {
            let symbolNames = ["appletvremote.gen4", "tv.and.mediabox", "remote"]
            for name in symbolNames {
                if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Siri Remote") {
                    image.isTemplate = true
                    button.image = image
                    button.title = ""
                    break
                }
            }
        }
        
        rebuildMenu()
        statusItem.menu = menu
    }
    
    private func rebuildMenu() {
        menu.removeAllItems()
        
        // Title
        let titleItem = NSMenuItem(title: "Siri Remote Controller", action: nil, keyEquivalent: "")
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
            ("playPause", "Play/Pause Button"),
            ("menu", "Menu Button"),
            ("select", "Select (Click)"),
            ("volumeUp", "Volume Up"),
            ("volumeDown", "Volume Down"),
            ("tv", "TV Button"),
            ("siri", "Siri Button")
        ]
        
        for (key, label) in buttons {
            let buttonItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let actionSubmenu = NSMenu()
            
            for action in ButtonAction.allCases {
                let actionItem = NSMenuItem(title: action.rawValue, action: #selector(changeMapping(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = (key, action)
                
                // Mark current selection
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
    
    /// Execute an action by name
    func executeAction(_ actionName: String) {
        guard let action = ButtonAction(rawValue: actionName) else { return }
        
        switch action {
        case .none:
            break
        case .playPause:
            mediaController?.sendMediaKey(.playPause)
        case .nextTrack:
            mediaController?.sendMediaKey(.next)
        case .previousTrack:
            mediaController?.sendMediaKey(.previous)
        case .volumeUp:
            mediaController?.sendMediaKey(.volumeUp)
        case .volumeDown:
            mediaController?.sendMediaKey(.volumeDown)
        case .mute:
            mediaController?.sendMediaKey(.mute)
        case .click:
            performClick()
        case .rightClick:
            performRightClick()
        case .escape:
            sendKey(kVK_Escape)
        case .space:
            sendKey(kVK_Space)
        case .enter:
            sendKey(kVK_Return)
        case .missionControl:
            sendMissionControlKey()
        }
    }
    
    private func sendMissionControlKey() {
        openMissionControl()
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
    
    private func performRightClick() {
        let pos = NSEvent.mouseLocation
        let screenH = NSScreen.main?.frame.height ?? 0
        let cgPos = CGPoint(x: pos.x, y: screenH - pos.y)
        
        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: cgPos, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: cgPos, mouseButton: .right)
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }
    
    private func sendKey(_ keyCode: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)?.post(tap: .cghidEventTap)
        usleep(10000)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)?.post(tap: .cghidEventTap)
    }
    
    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }
}

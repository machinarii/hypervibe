//
//  RemoteInputHandler.swift
//  HyperVibe
//
//  Processes HID input events from Siri Remote
//

import IOKit
import IOKit.hid
import Foundation
import Carbon.HIToolbox
import AppKit

class RemoteInputHandler {
    private let cursorController: CursorController
    private let mediaController: MediaController
    private weak var menuBarManager: MenuBarManager?
    private var devices: [IOHIDDevice] = []
    
    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?
    
    // First press after connection: do not perform action (sound already played at connect).
    private var isFirstPressAfterConnection = false
    
    // Click/drag state
    private var isSelectPressed = false
    private var selectPressTime: UInt64 = 0
    private var isDragging = false
    private let clickThreshold: Double = 0.25
    
    // Prevent double-processing with MediaKeyInterceptor
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0

    /// Virtual keys currently held down, keyed by the HID button that initiated the hold.
    /// Captured at press time so release can fire the correct keyUp even if the user
    /// rebinds the button mid-hold. Cleared on device removal to avoid stuck modifiers.
    private var heldKeys: [String: (keyCode: Int, flags: CGEventFlags)] = [:]
    
    init(cursorController: CursorController, mediaController: MediaController, menuBarManager: MenuBarManager) {
        self.cursorController = cursorController
        self.mediaController = mediaController
        self.menuBarManager = menuBarManager
    }
    
    func setRemoteDevice(_ device: IOHIDDevice?) {
        guard let device = device else {
            releaseAllHeldKeys()
            for d in devices {
                IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
                IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            devices.removeAll()
            isFirstPressAfterConnection = false
            return
        }
        
        guard !devices.contains(where: { $0 == device }) else { return }
        
        // Seize device to prevent system from handling events
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

        if openResult == kIOReturnSuccess {
            rmDebug(String(format: "🔒 SEIZED HID device (vendor=0x%X product=0x%X)",
                  IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0,
                  IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0))
            IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            devices.append(device)
            isFirstPressAfterConnection = true
        } else {
            rmDebug(String(format: "⚠️ FAILED to seize HID device (IOReturn=0x%X) — opening unseized", openResult))
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                devices.append(device)
                isFirstPressAfterConnection = true
            }
        }
    }
    
    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let identified = identifyButton(page: usagePage, usage: usage)
        rmDebug(String(format: "🎮 HID event: page=0x%X usage=0x%X value=%d → %@",
                       usagePage, usage, intValue, identified ?? "<unmapped>"))
        guard let buttonName = identified else { return }

        onButtonActivity?()

        // First key-down after connection: skip so the connect handshake doesn't fire an action.
        if intValue == 1 && isFirstPressAfterConnection {
            isFirstPressAfterConnection = false
            return
        }

        // Select is the trackpad click — handled separately for click/drag semantics.
        if buttonName == "select" {
            handleSelectButton(pressed: intValue == 1)
            return
        }

        let pressed = (intValue == 1)

        // Debounce only on press — release just closes an existing hold.
        if pressed {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
        }

        let action = menuBarManager?.getMapping(for: buttonName) ?? ButtonAction.none
        if pressed {
            print("🔘 Button pressed: \(buttonName) → \(action.rawValue)")
        }
        executeAction(action, button: buttonName, pressed: pressed)
    }
    
    private func handleSelectButton(pressed: Bool) {
        if pressed && !isSelectPressed {
            isSelectPressed = true
            isDragging = false
            selectPressTime = mach_absolute_time()
            cursorController.isClickActive = true
            
            // Start drag after threshold
            DispatchQueue.main.asyncAfter(deadline: .now() + clickThreshold) { [weak self] in
                guard let self = self, self.isSelectPressed && !self.isDragging else { return }
                print("🔘 Select button: Drag started")
                self.isDragging = true
                self.cursorController.isDragging = true
                self.cursorController.mouseDown()
            }
        } else if !pressed && isSelectPressed {
            isSelectPressed = false
            
            if isDragging {
                print("🔘 Select button: Drag ended")
                cursorController.isDragging = false
                cursorController.mouseUp()
            } else {
                print("🔘 Select button: Click")
                cursorController.performClick()
            }
            isDragging = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.cursorController.isClickActive = false
            }
        }
    }
    
    // MARK: - Button Identification
    
    private func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        // Generic Desktop Page (0x01)
        case (0x01, 0x86): return "menu"          // System Menu Main
        case (0x01, 0x40): return "menu"          // Menu (alternative)
        
        // Consumer Page (0x0C)  
        case (0x0C, 0x04): return "siri"          // Siri button (actual)
        case (0x0C, 0x60): return "tv"            // TV button (actual)
        case (0x0C, 0x80): return "select"        // Selection
        case (0x0C, 0x41): return "select"        // Menu Select (alternative)
        case (0x0C, 0xCD): return "playPause"     // Play/Pause
        case (0x0C, 0xE9): return "volumeUp"      // Volume Increment
        case (0x0C, 0xEA): return "volumeDown"    // Volume Decrement
        case (0x0C, 0xB5): return "nextTrack"     // Scan Next Track
        case (0x0C, 0xB6): return "prevTrack"     // Scan Previous Track
        case (0x0C, 0x223): return "tv"           // AC Home (TV button alternative)
        case (0x0C, 0x224): return "back"         // AC Back
        case (0x0C, 0x40): return "menu"          // Menu
        case (0x0C, 0x30): return "power"         // Power
        case (0x0C, 0x20): return "mute"          // Mute (some remotes)
        
        // Button Page (0x09)
        case (0x09, 0x01): return "select"        // Button 1
        
        // Apple Vendor Page (0xFF00) - Siri button
        case (0xFF00, 0x01): return "siri"        // Siri button
        case (0xFF00, 0x02): return "siri"        // Siri button (alternative)
        case (0xFF00, 0x03): return "siri"        // Siri button (alternative)
        case (0xFF00, _): return "siri"           // Any Apple vendor usage = likely Siri
        
        // Telephony Page (0x0B) - sometimes used for Siri
        case (0x0B, 0x21): return "siri"          // Flash
        case (0x0B, 0x2F): return "siri"          // Phone Mute
        
        default: return nil
        }
    }
    
    // MARK: - Action Execution
    
    private func executeAction(_ action: ButtonAction, button: String, pressed: Bool) {
        if action.requiresHold {
            handleHoldAction(action, button: button, pressed: pressed)
            return
        }
        // Tap actions fire once, on press only.
        guard pressed else { return }
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
        case .spaceKey, .rightCmd, .rightOpt:
            break // handled by handleHoldAction
        case .trackpadClick:
            cursorController.performClick()
        }
    }

    /// Press/release a virtual key mirroring the HID press duration (push-to-talk).
    private func handleHoldAction(_ action: ButtonAction, button: String, pressed: Bool) {
        let spec: (keyCode: Int, flags: CGEventFlags)
        switch action {
        case .spaceKey: spec = (kVK_Space,        [])
        case .rightCmd: spec = (kVK_RightCommand, .maskCommand)
        case .rightOpt: spec = (kVK_RightOption,  .maskAlternate)
        default: return
        }

        if pressed {
            // Defensive: if a prior release was missed, close the stale hold before opening a new one.
            if let stale = heldKeys.removeValue(forKey: button) {
                postKey(keyCode: stale.keyCode, flags: [], keyDown: false)
            }
            postKey(keyCode: spec.keyCode, flags: spec.flags, keyDown: true)
            heldKeys[button] = spec
        } else {
            guard let held = heldKeys.removeValue(forKey: button) else { return }
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
    }

    /// Called on device removal to avoid stuck modifiers if the remote disconnects mid-hold.
    private func releaseAllHeldKeys() {
        for (_, held) in heldKeys {
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
        heldKeys.removeAll()
    }

    private func postKey(keyCode: Int, flags: CGEventFlags, keyDown: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        postKey(keyCode: keyCode, flags: flags, keyDown: true)
        usleep(10000)
        postKey(keyCode: keyCode, flags: flags, keyDown: false)
    }
}

/// Opens Mission Control (one path for CLI and app).
func openMissionControl() {
    let bundleID = "com.apple.exposelauncher"
    if Bundle.main.bundlePath.hasSuffix(".app"),
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        return
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = ["-b", bundleID]
    try? proc.run()
}

// C callback
private func inputValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context = context else { return }
    Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}

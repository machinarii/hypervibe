//
//  KeyCaptureController.swift
//  HyperVibe
//
//  Fluid-style key capture panel: arm, press the key or keys, confirm.
//  Local event monitor only — captures the app's own events, no extra permissions.
//

import AppKit
import Carbon.HIToolbox

/// A captured keystroke: hardware key code + modifier flags + human-readable name.
struct CapturedKey {
    let keyCode: Int
    let flags: CGEventFlags
    let display: String
}

final class KeyCaptureController: NSObject {

    private var window: NSWindow?
    private var monitor: Any?
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var captured: CapturedKey?
    private var completion: ((CapturedKey?) -> Void)?

    private let promptLabel = NSTextField(labelWithString: "")
    private let capturedLabel = NSTextField(labelWithString: " ")
    private let useButton = NSButton(title: "Use", target: nil, action: nil)

    /// Present the capture panel. Completion fires with the confirmed key, or nil on cancel.
    func begin(forButtonLabel buttonLabel: String, completion: @escaping (CapturedKey?) -> Void) {
        self.completion = completion
        self.captured = nil

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                             styleMask: [.titled],
                             backing: .buffered, defer: false)
        panel.title = "Assign Key — \(buttonLabel)"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()

        promptLabel.stringValue = "Press the key or keys to assign to this button"
        promptLabel.alignment = .center
        promptLabel.font = NSFont.systemFont(ofSize: 13)

        capturedLabel.alignment = .center
        capturedLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        capturedLabel.stringValue = " "

        let hint = NSTextField(labelWithString: "Esc cancels · press again to change")
        hint.alignment = .center
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        useButton.target = self
        useButton.action = #selector(confirm)
        useButton.isEnabled = false
        useButton.keyEquivalent = ""
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))

        let buttons = NSStackView(views: [cancelButton, useButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [promptLabel, capturedLabel, hint, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        panel.contentView = stack

        // Capture via a session event tap: it sees keys BEFORE global-hotkey routing, so
        // keys already registered as hotkeys by other apps (e.g. a dictation app's PTT key)
        // are both capturable and consumed — the other app's hotkey won't fire mid-capture.
        // Requires Input Monitoring, which the app already holds. Local monitor is the
        // fallback if tap creation fails.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                       place: .headInsertEventTap,
                                       options: .defaultTap,
                                       eventsOfInterest: mask,
                                       callback: { _, _, cgEvent, refcon in
                                           guard let refcon = refcon else { return Unmanaged.passUnretained(cgEvent) }
                                           let controller = Unmanaged<KeyCaptureController>.fromOpaque(refcon).takeUnretainedValue()
                                           return controller.handleTapEvent(cgEvent)
                                       },
                                       userInfo: refcon) {
            eventTap = tap
            tapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                if event.keyCode == UInt16(kVK_Escape) {
                    self.cancel()
                    return nil
                }
                let flags = Self.cgFlags(from: event.modifierFlags)
                let display = Self.describe(keyCode: Int(event.keyCode), event: event)
                self.captured = CapturedKey(keyCode: Int(event.keyCode), flags: flags, display: display)
                self.capturedLabel.stringValue = display
                self.useButton.isEnabled = true
                return nil // swallow — this press is being recorded, not typed
            }
        }

        self.window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Event-tap path: record the key, swallow the event (returning nil suppresses
    /// delivery to global hotkeys and the focused app alike).
    private func handleTapEvent(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
        let flags = cgEvent.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn])
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if keyCode == kVK_Escape {
                self.cancel()
                return
            }
            let nsEvent = NSEvent(cgEvent: cgEvent)
            let display = Self.describe(keyCode: keyCode, cgFlags: flags, nsEvent: nsEvent)
            self.captured = CapturedKey(keyCode: keyCode, flags: flags, display: display)
            self.capturedLabel.stringValue = display
            self.useButton.isEnabled = true
        }
        return nil
    }

    @objc private func confirm() { finish(with: captured) }
    @objc private func cancel() { finish(with: nil) }

    private func finish(with result: CapturedKey?) {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = tapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            tapRunLoopSource = nil
        }
        window?.orderOut(nil)
        window = nil
        let cb = completion
        completion = nil
        cb?(result)
    }

    // MARK: - Naming

    private static func cgFlags(from mods: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods.contains(.command)  { flags.insert(.maskCommand) }
        if mods.contains(.shift)    { flags.insert(.maskShift) }
        if mods.contains(.option)   { flags.insert(.maskAlternate) }
        if mods.contains(.control)  { flags.insert(.maskControl) }
        if mods.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    static func describe(keyCode: Int, event: NSEvent?) -> String {
        return describe(keyCode: keyCode,
                        cgFlags: cgFlags(from: event?.modifierFlags ?? []),
                        nsEvent: event)
    }

    static func describe(keyCode: Int, cgFlags: CGEventFlags, nsEvent: NSEvent?) -> String {
        var parts: [String] = []
        if cgFlags.contains(.maskControl)   { parts.append("⌃") }
        if cgFlags.contains(.maskAlternate) { parts.append("⌥") }
        if cgFlags.contains(.maskShift)     { parts.append("⇧") }
        if cgFlags.contains(.maskCommand)   { parts.append("⌘") }
        parts.append(keyName(keyCode: keyCode, event: nsEvent))
        return parts.joined()
    }

    /// Human name for a key code; falls back to the event's characters, then "key N".
    private static func keyName(keyCode: Int, event: NSEvent?) -> String {
        switch keyCode {
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "FwdDelete"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "PageUp"
        case kVK_PageDown: return "PageDown"
        case kVK_LeftArrow: return "Left"
        case kVK_RightArrow: return "Right"
        case kVK_UpArrow: return "Up"
        case kVK_DownArrow: return "Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            if let chars = event?.charactersIgnoringModifiers, !chars.isEmpty {
                return chars.uppercased()
            }
            return "key \(keyCode)"
        }
    }
}

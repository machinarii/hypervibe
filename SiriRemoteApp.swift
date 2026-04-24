//
//  SiriRemoteApp.swift
//  HyperVibe
//
//  Menu bar application for controlling Mac with Siri Remote
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var statusItem: NSStatusItem!
    private var menuBarManager: MenuBarManager!
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var touchHandler: TouchHandler?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 HyperVibe starting...")

        // Install the volume-revert listener before any HID press can fire, so the first
        // remote volume press is guarded — not just subsequent ones.
        VolumeRevertGuard.shared.prewarm()

        // Suppress OSDUIHelper (the volume/brightness/caps-lock bezel) for the session so
        // AVRCP-origin volume changes don't render a HUD before we can revert. Restored on
        // clean exit. This is system-wide while HyperVibe runs: keyboard volume/brightness
        // HUDs are also suppressed until quit.
        OSDHelperControl.suspend()

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem else {
            NSApp.terminate(nil)
            return
        }
        statusItem.isVisible = true
        
        // Initialize menu bar manager
        menuBarManager = MenuBarManager(statusItem: statusItem)
        
        // Check accessibility permissions
        checkAccessibilityPermissions()
        
        // Initialize controllers
        let cursorController = CursorController()

        remoteInputHandler = RemoteInputHandler(
            cursorController: cursorController,
            menuBarManager: menuBarManager
        )
        
        // Start touch handler for trackpad (before remote detection so we can wire the callback)
        touchHandler = TouchHandler(cursorController: cursorController)
        touchHandler?.scrollScale = menuBarManager.scrollSpeed.scale
        touchHandler?.onSwipe = { [weak menuBarManager] direction in
            menuBarManager?.executeSwipe(direction)
        }
        touchHandler?.start()
        remoteInputHandler?.onButtonActivity = { [weak self] in
            self?.touchHandler?.tryReconnectTrackpad()
        }
        
        // Start remote detection
        remoteDetector = RemoteDetector { [weak self] device in
            DispatchQueue.main.async {
                self?.remoteInputHandler?.setRemoteDevice(device)
                self?.menuBarManager.updateConnectionStatus(connected: device != nil)
            }
        }
        remoteDetector?.startDetection()
        
        // Request Input Monitoring so media key tap works in both CLI and .app
        if #available(macOS 10.15, *) {
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
        }
        
        // Start media key interceptor
        mediaKeyInterceptor = MediaKeyInterceptor()
        mediaKeyInterceptor?.onMediaKey = { [weak self] keyType in
            guard let self = self else { return false }
            return self.handleInterceptedMediaKey(keyType)
        }
        mediaKeyInterceptor?.start()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cleanup()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    private func cleanup() {
        touchHandler?.stop()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
        OSDHelperControl.restore()
    }
    
    // MARK: - Media Key Handling

    /// Convert mach_absolute_time() delta to seconds (machine ticks vary; use timebase).
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()

    private static func machDeltaToSeconds(from start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        let now = mach_absolute_time()
        let delta = now >= start ? (now - start) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private func handleInterceptedMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType) -> Bool {
        let buttonName: String
        switch keyType {
        case .playPause:  buttonName = "playPause"
        case .next:       buttonName = "nextTrack"
        case .previous:   buttonName = "prevTrack"
        case .volumeUp:   buttonName = "volumeUp"
        case .volumeDown: buttonName = "volumeDown"
        case .mute:       buttonName = "mute"
        }

        // If the HID path just handled this exact button, the session tap is echoing our
        // remote press — consume it so apps don't also see it. Anything else (keyboard F7/F8,
        // F10/F11/F12, or another BT input) is not ours: pass through so rcd and apps get it.
        if RemoteInputHandler.lastProcessedButton == buttonName {
            let timeSinceLastProcess = Self.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime)
            if timeSinceLastProcess < 0.2 {
                return true
            }
        }
        return false
    }
    
    // MARK: - Permissions
    
    private func checkAccessibilityPermissions() {
        // macOS will show its own prompt when needed
        // No need for redundant custom alert
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Suppresses `com.apple.OSDUIHelper` (the system bezel renderer) for the session by
/// disabling its LaunchAgent and killing the current instance. Under SIP, `bootout` is
/// blocked but `disable` is allowed — `disable` prevents Mach-service spawn, so once we
/// kill the running helper, volume/brightness IPCs from coreaudiod no longer respawn it.
/// On clean exit we re-enable it. A crash leaves it disabled until next login or manual
/// `launchctl enable gui/$UID/com.apple.OSDUIHelper`.
///
/// Trade-off: while HyperVibe runs, keyboard volume/brightness/caps-lock bezels are also
/// suppressed system-wide. Accepted to stop the remote's BT-AVRCP volume change from
/// rendering a bezel before our listener can revert the level.
enum OSDHelperControl {
    private static var disabled = false

    static func suspend() {
        let service = "gui/\(getuid())/com.apple.OSDUIHelper"
        let (disableStatus, disableErr) = launchctl(["disable", service])
        guard disableStatus == 0 else {
            print("⚠️ Could not disable OSDUIHelper (launchctl exit=\(disableStatus)): \(disableErr)")
            return
        }
        disabled = true
        // Kill the current instance so the disable actually takes effect — disable only
        // prevents future spawns.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["-9", "OSDUIHelper"]
        kill.standardOutput = Pipe()
        kill.standardError = Pipe()
        try? kill.run()
        kill.waitUntilExit()
        print("🔇 OSDUIHelper disabled + killed (no system bezels until quit)")
    }

    static func restore() {
        guard disabled else { return }
        let (status, err) = launchctl(["enable", "gui/\(getuid())/com.apple.OSDUIHelper"])
        if status == 0 {
            print("🔊 OSDUIHelper re-enabled")
        } else {
            print("⚠️ Could not re-enable OSDUIHelper (launchctl exit=\(status)): \(err) — run `launchctl enable gui/$(id -u)/com.apple.OSDUIHelper` to restore manually")
        }
        disabled = false
    }

    private static func launchctl(_ args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (proc.terminationStatus, s)
        } catch {
            return (-1, "\(error)")
        }
    }
}


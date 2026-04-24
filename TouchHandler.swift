//
//  TouchHandler.swift
//  HyperVibe
//
//  Handles Siri Remote trackpad input using Apple's private MultitouchSupport.framework
//

import Foundation
import CoreGraphics
import AppKit
import Darwin

// #region agent log
private let debugLogPath = "/Users/laurent/Documents/Remotastic/.cursor/debug.log"
private func debugLog(_ message: String, data: [String: Any] = [:], hypothesisId: String = "") {
    let payload: [String: Any] = [
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        "location": "TouchHandler",
        "message": message,
        "data": data,
        "sessionId": "debug-session",
        "hypothesisId": hypothesisId
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: json, encoding: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: debugLogPath) {
        FileManager.default.createFile(atPath: debugLogPath, contents: nil)
    }
    guard let h = FileHandle(forUpdatingAtPath: debugLogPath) else { return }
    h.seekToEndOfFile()
    h.write(line.data(using: .utf8)!)
    h.write("\n".data(using: .utf8)!)
    h.closeFile()
}
// #endregion

private func touchCallback(device: MTDevice?,
                           touches: UnsafeMutablePointer<MTTouch>?,
                           numTouches: Int,
                           timestamp: Double,
                           frame: Int,
                           refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let handler = Unmanaged<TouchHandler>.fromOpaque(refcon).takeUnretainedValue()
    handler.handleTouches(touches: touches, count: numTouches, timestamp: timestamp)
}

class TouchHandler {
    
    /// mach_absolute_time() is in machine-dependent units; convert to seconds via timebase.
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        if mach_timebase_info(&info) == 0 {
            return (info.numer, info.denom)
        }
        return (1, 1)
    }()
    
    private static func machDeltaToSeconds(from startMach: UInt64) -> Double {
        guard startMach > 0 else { return 0 }
        let now = mach_absolute_time()
        let delta = now >= startMach ? (now - startMach) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private let cursorController: CursorController
    private var device: MTDevice?
    private var reconnectTimer: Timer?
    private var fastReconnectTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    
    var scrollScale: CGFloat = 150.0
    
    private var lastTouchPosition: CGPoint?
    private var lastTouchCount = 0
    private var lastTouchTime: UInt64 = 0
    private var touchStartTime: UInt64 = 0
    private var touchStartPosition: CGPoint = .zero
    
    private let cursorScale: CGFloat = 500.0
    private let tapMaxDuration: Double = 0.22
    private let tapMaxDistance: CGFloat = 0.07
    // Swipe detection: velocity-gated single-finger flick. Distance > 35% of trackpad in < 350ms,
    // with the dominant axis at least 2× the orthogonal axis (rejects diagonal wobble).
    private let swipeMinDistance: CGFloat = 0.35
    private let swipeMaxDuration: Double = 0.35
    private let swipeAxisRatio: CGFloat = 2.0
    private var hadMultipleFingersInSession = false

    /// Fired on touch-up when a single-finger flick is detected. Dispatched on main.
    var onSwipe: ((SwipeDirection) -> Void)?
    private let reconnectInterval: TimeInterval = 2.0
    private let idleTimeout: TimeInterval = 90.0
    private let touchStarvationThreshold: TimeInterval = 15.0
    private var handleTouchesCallCount: Int = 0

    init(cursorController: CursorController) {
        self.cursorController = cursorController
    }
    
    deinit {
        stop()
    }
    
    func start() {
        findAndStartDevice()
        startReconnectTimer()
        // Restart MT device after sleep (trackpad stops delivering until restarted).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartTrackpadAfterWake()
        }
    }
    
    func stop() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        fastReconnectTimer?.invalidate()
        fastReconnectTimer = nil
        stopDevice()
    }
    
    /// Call when HID button activity is detected (e.g. after remote wake). Re-scans MT devices
    /// only when we don't have a device, so we can reattach if it reappeared. If we already
    /// have a working device, do nothing — restarting on every button press would break the trackpad.
    func tryReconnectTrackpad() {
        guard device == nil else { return }
        let doScan = { [weak self] in
            guard self?.device == nil else { return }
            self?.findAndStartDevice()
        }
        if Thread.isMainThread {
            doScan()
        } else {
            DispatchQueue.main.async { doScan() }
        }
        // Device may re-enumerate shortly after HID activity; retry once after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { doScan() }
        // Poll more often for a limited time so we attach as soon as the trackpad reappears.
        fastReconnectTimer?.invalidate()
        let startDate = Date()
        fastReconnectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.device != nil {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            if Date().timeIntervalSince(startDate) > 20 {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            self.findAndStartDevice()
        }
        if let timer = fastReconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func restartTrackpadAfterWake() {
        stopDevice()
        findAndStartDevice()
    }
    
    private func findAndStartDevice() {
        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else {
            // #region agent log
            debugLog("findAndStartDevice: list nil", data: [:], hypothesisId: "B")
            // #endregion
            return
        }
        let deviceList = cfArray as [MTDevice]
        let deviceCount = deviceList.count
        var foundNonBuiltin = false
        // Find non-built-in device (Siri Remote)
        for dev in deviceList {
            if !MTDeviceIsBuiltIn(dev) {
                foundNonBuiltin = true
                // #region agent log
                debugLog("findAndStartDevice: starting non-built-in", data: ["deviceCount": deviceCount], hypothesisId: "B")
                // #endregion
                startDevice(dev)
                return
            }
        }
        // Fallback: use second device if available
        if deviceList.count > 1 {
            // #region agent log
            debugLog("findAndStartDevice: starting second device", data: ["deviceCount": deviceCount], hypothesisId: "B")
            // #endregion
            startDevice(deviceList[1])
        } else {
            // #region agent log
            debugLog("findAndStartDevice: no device to start", data: ["deviceCount": deviceCount, "foundNonBuiltin": foundNonBuiltin], hypothesisId: "B")
            // #endregion
            // Clear stale ref so next checkAndReconnect will retry when the remote reappears in the list.
            if device != nil {
                // #region agent log
                debugLog("findAndStartDevice: clearing stale device", data: ["deviceCount": deviceCount], hypothesisId: "B")
                // #endregion
                stopDevice()
            }
        }
    }
    
    private func startDevice(_ dev: MTDevice) {
        stopDevice()
        device = dev
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        MTRegisterContactFrameCallbackWithRefcon(dev, touchCallback, refcon)
        MTDeviceStart(dev, 0)
        // Reset so we don't immediately re-enter starvation and restart every 2s when no touches yet.
        lastTouchTime = mach_absolute_time()
        // #region agent log
        debugLog("startDevice: started", data: [:], hypothesisId: "C")
        // #endregion
        print("📱 Trackpad device connected and started")
    }
    
    private func stopDevice() {
        guard let dev = device else { return }
        MTUnregisterContactFrameCallback(dev, touchCallback)
        MTDeviceStop(dev)
        device = nil
        
        print("📱 Trackpad device disconnected")
        lastTouchPosition = nil
        lastTouchCount = 0
        hadMultipleFingersInSession = false
    }
    
    private func startReconnectTimer() {
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: true) { [weak self] _ in
            self?.checkAndReconnect()
        }
        // Fire when app is in background (menu bar only); otherwise timer may not run.
        if let timer = reconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func checkAndReconnect() {
        let timeSinceLastTouch = lastTouchTime == 0 ? 0 : Self.machDeltaToSeconds(from: lastTouchTime)

        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else {
            // #region agent log
            debugLog("checkAndReconnect: MTDeviceCreateList nil", data: [:], hypothesisId: "A")
            // #endregion
            return
        }
        let deviceCount = CFArrayGetCount(cfArray)
        let hasDevice = device != nil
        let isRunning = device.map { MTDeviceIsRunning($0) } ?? false

        // Restart if we have a device ref but the driver stopped (e.g. after remote sleep).
        if let dev = device, !MTDeviceIsRunning(dev) {
            // #region agent log
            debugLog("checkAndReconnect: restart (not running)", data: ["timeSinceLastTouch": timeSinceLastTouch, "deviceCount": deviceCount], hypothesisId: "A")
            // #endregion
            findAndStartDevice()
            return
        }
        // Restart if we have a device but no touch events for a while (remote slept; no "remote wake" API).
        if device != nil && timeSinceLastTouch > touchStarvationThreshold {
            // #region agent log
            debugLog("checkAndReconnect: restart (starvation)", data: ["timeSinceLastTouch": timeSinceLastTouch, "deviceCount": deviceCount, "threshold": touchStarvationThreshold], hypothesisId: "A")
            // #endregion
            findAndStartDevice()
            return
        }
        // #region agent log
        if device != nil && timeSinceLastTouch > 5 && timeSinceLastTouch <= touchStarvationThreshold {
            debugLog("checkAndReconnect: waiting for starvation", data: ["timeSinceLastTouch": timeSinceLastTouch, "threshold": touchStarvationThreshold], hypothesisId: "A")
        }
        // #endregion
        let shouldReconnect = device == nil || (timeSinceLastTouch > idleTimeout && deviceCount > 1)
        let willTryReconnect = shouldReconnect && (device == nil || deviceCount > 1)
        if willTryReconnect {
            // #region agent log
            debugLog("checkAndReconnect: restart (willReconnect)", data: ["timeSinceLastTouch": timeSinceLastTouch, "deviceCount": deviceCount, "deviceNil": device == nil], hypothesisId: "A")
            // #endregion
            findAndStartDevice()
        } else {
            // #region agent log
            if hasDevice && timeSinceLastTouch > 10 {
                debugLog("checkAndReconnect: no restart", data: ["timeSinceLastTouch": timeSinceLastTouch, "deviceCount": deviceCount, "isRunning": isRunning], hypothesisId: "A")
            }
            // #endregion
        }
    }
    
    func handleTouches(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        lastTouchTime = mach_absolute_time()
        // #region agent log
        handleTouchesCallCount += 1
        if handleTouchesCallCount % 100 == 1 || handleTouchesCallCount <= 3 {
            debugLog("handleTouches: callback", data: ["count": count, "callCount": handleTouchesCallCount], hypothesisId: "C")
        }
        // #endregion

        guard count > 0, let touchPtr = touches else {
            // Touch ended
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        // Calculate average position of all active touches
        var avgX: Float = 0
        var avgY: Float = 0
        var activeTouchCount = 0
        
        for i in 0..<count {
            let touch = touchPtr[i]
            
            // Only process active touches
            if touch.state == MTTouchStateTouching || touch.state == MTTouchStateMakeTouch {
                avgX += touch.normalizedVector.position.x
                avgY += touch.normalizedVector.position.y
                activeTouchCount += 1
            }
        }
        
        guard activeTouchCount > 0 else {
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        if activeTouchCount >= 2 {
            hadMultipleFingersInSession = true
        }
        
        avgX /= Float(activeTouchCount)
        avgY /= Float(activeTouchCount)
        
        let currentPos = CGPoint(x: CGFloat(avgX), y: CGFloat(avgY))
        
        // Handle touch start
        if lastTouchPosition == nil {
            hadMultipleFingersInSession = false
            touchStartTime = mach_absolute_time()
            touchStartPosition = currentPos
            lastTouchPosition = currentPos
            lastTouchCount = activeTouchCount
            return
        }
        
        // Calculate delta
        let deltaX = currentPos.x - (lastTouchPosition?.x ?? currentPos.x)
        let deltaY = currentPos.y - (lastTouchPosition?.y ?? currentPos.y)
        
        // Process based on finger count: 1 finger = cursor, 2 fingers = scroll
        if activeTouchCount == 1 && lastTouchCount == 1 {
            let clamped = moveCursor(deltaX: deltaX, deltaY: deltaY)
            // Only advance touch tracking if cursor wasn't clamped in that direction
            if let lastPos = lastTouchPosition {
                let adjustedDeltaX = clamped.clampedX ? 0 : deltaX
                let adjustedDeltaY = clamped.clampedY ? 0 : deltaY
                lastTouchPosition = CGPoint(
                    x: lastPos.x + adjustedDeltaX,
                    y: lastPos.y + adjustedDeltaY
                )
            } else {
                lastTouchPosition = currentPos
            }
        } else if activeTouchCount == 2 && lastTouchCount == 2 {
            // Two fingers: always scroll regardless of mode
            performScroll(deltaX: deltaX, deltaY: deltaY)
            lastTouchPosition = currentPos
        } else {
            lastTouchPosition = currentPos
        }
        
        lastTouchCount = activeTouchCount
    }
    
    private func handleTouchEnd() {
        guard lastTouchPosition != nil else { return }
        
        // Don't trigger tap if physical click button is active
        if cursorController.isClickActive {
            return
        }
        // Don't trigger tap after a multi-finger gesture (e.g. two-finger scroll)
        if hadMultipleFingersInSession {
            return
        }
        
        let duration = Self.machDeltaToSeconds(from: touchStartTime)
        let dx = (lastTouchPosition?.x ?? 0) - touchStartPosition.x
        let dy = (lastTouchPosition?.y ?? 0) - touchStartPosition.y
        let movement = hypot(dx, dy)

        // Swipe detection (flick). Fires before tap check; distance threshold is well above
        // tapMaxDistance, so a swipe can never also register as a tap.
        if duration < swipeMaxDuration && movement > swipeMinDistance {
            let absDx = abs(dx), absDy = abs(dy)
            let direction: SwipeDirection?
            if absDx > absDy * swipeAxisRatio {
                direction = dx > 0 ? .right : .left
            } else if absDy > absDx * swipeAxisRatio {
                // MultitouchSupport reports y increasing toward the top of the trackpad.
                direction = dy > 0 ? .up : .down
            } else {
                direction = nil
            }
            if let direction = direction {
                DispatchQueue.main.async { [weak self] in
                    self?.onSwipe?(direction)
                }
                return
            }
        }

        if duration < tapMaxDuration && movement < tapMaxDistance {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cursorController.performClick()
            }
        }
    }
    
    private func moveCursor(deltaX: CGFloat, deltaY: CGFloat) -> (clampedX: Bool, clampedY: Bool) {
        let scaledX = deltaX * cursorScale
        let scaledY = -deltaY * cursorScale

        var clamped = (clampedX: false, clampedY: false)

        if Thread.isMainThread {
            clamped = cursorController.moveCursor(deltaX: scaledX, deltaY: scaledY)
        } else {
            DispatchQueue.main.sync {
                clamped = cursorController.moveCursor(deltaX: scaledX, deltaY: scaledY)
            }
        }

        return clamped
    }
    
    private func performScroll(deltaX: CGFloat, deltaY: CGFloat) {
        let scrollX = Int32(-deltaX * scrollScale)
        let scrollY = Int32(deltaY * scrollScale)
        
        DispatchQueue.main.async { [weak self] in
            self?.cursorController.scroll(deltaX: scrollX, deltaY: scrollY)
        }
    }
}

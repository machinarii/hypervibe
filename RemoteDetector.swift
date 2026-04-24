//
//  RemoteDetector.swift
//  HyperVibe
//
//  Detects Siri Remote via IOKit HID
//

import Foundation
import IOKit
import IOKit.hid

/// Append diagnostic line to /tmp/hypervibe.log (unified-log redacts NSLog under hardened runtime).
func rmDebug(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/hypervibe.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

class RemoteDetector {
    private var manager: IOHIDManager?
    private var deviceCallback: ((IOHIDDevice?) -> Void)?
    private var currentDevice: IOHIDDevice?
    private var connectedDeviceCount = 0
    // Track devices by vendorID:productID combination
    // A single physical Siri Remote may expose multiple HID interfaces, but we only want to process one
    private var processedDeviceKeys: Set<String> = []
    private let processingQueue = DispatchQueue(label: "com.hypervibe.deviceProcessing")
    
    private let appleVendorID: Int = 0x004C
    
    // Known Siri Remote / Apple TV Remote product IDs
    private let knownProductIDs: [Int] = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x0269,
        0x0C4E, 0x0C4F, 0x030D, 0x030E
    ]
    
    init(deviceCallback: @escaping (IOHIDDevice?) -> Void) {
        self.deviceCallback = deviceCallback
    }
    
    func startDetection() {
        rmDebug(String(format: "🛰 starting HID detection (vendor=0x%X)", appleVendorID))
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else {
            rmDebug("⚠️ IOHIDManagerCreate returned nil")
            return
        }

        // SiriMote uses IOHIDManagerSetDeviceMatchingMultiple with per-interface dicts.
        // The Siri Remote A1513 exposes 3 HID interfaces (consumer, game controls, vendor),
        // and the singular variant with vendor-only matching does not enumerate them on
        // recent macOS BLE HID stacks.
        let matchingDicts: [[String: Any]] = [
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0C],   // Consumer Page
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0D],   // Digitizer / Game Controls
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0xFF00], // Apple vendor-defined
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x01],   // Generic Desktop (kept for keyboards/trackpads)
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts as CFArray)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAddedCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, Unmanaged.passUnretained(self).toOpaque())

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            rmDebug(String(format: "⚠️ IOHIDManagerOpen failed (IOReturn=0x%X)", openResult))
            return
        }
        rmDebug("🛰 IOHIDManagerOpen success")

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.enumerateAllDevices()
        }
    }
    
    func stopDetection() {
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        currentDevice = nil
        processedDeviceKeys.removeAll()
        connectedDeviceCount = 0
        deviceCallback?(nil)
    }
    
    private func enumerateAllDevices() {
        guard let manager = manager,
              let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            rmDebug("🛰 IOHIDManagerCopyDevices returned nil/empty (TCC block or matching mismatch)")
            return
        }
        rmDebug("🛰 enumeration found \(deviceSet.count) HID device(s) matching filter")
        for device in deviceSet {
            let v = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let p = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? -1
            let n = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let pup = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let pu  = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            rmDebug(String(format: "🛰 candidate vendor=0x%X product=0x%X usagePage=0x%X usage=0x%X name=%@",
                           v, p, pup, pu, n))
            if isSiriRemote(device) {
                handleDeviceAdded(device)
            }
        }
    }
    
    private func isSiriRemote(_ device: IOHIDDevice) -> Bool {
        guard let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
              vendorID == appleVendorID else { return false }
        
        if let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
           knownProductIDs.contains(productID) {
            return true
        }
        
        if let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
            let name = productName.lowercased()
            return name.contains("remote") || name.contains("siri") || name.contains("apple tv")
        }
        
        return false
    }
    
    func handleDeviceAdded(_ device: IOHIDDevice) {
        guard isSiriRemote(device) else { return }
        
        // Get device properties (safe to read from any thread)
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        
        // Create a key based on vendor+product to group all HID interfaces from the same physical device
        // A single Siri Remote may expose multiple HID interfaces (buttons, touch, etc.)
        // but they all share the same vendor and product ID
        let deviceKey = "\(vendorID):\(productID)"
        
        // Use a serialized queue to prevent race conditions when processing devices
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let shouldLog: Bool
            if !self.processedDeviceKeys.contains(deviceKey) {
                // First time seeing this vendor+product combination - log it
                self.processedDeviceKeys.insert(deviceKey)
                self.connectedDeviceCount += 1
                shouldLog = true
            } else {
                // Already seen this vendor+product - skip logging but still process the device
                shouldLog = false
            }
            
            // Always set currentDevice to the latest device (for tracking)
            self.currentDevice = device
            
            // Only log once per physical device (vendor+product combination)
            if shouldLog {
                let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
                print("✅ Siri Remote connected: \(productName) (Vendor: 0x\(String(vendorID, radix: 16, uppercase: true)), Product: 0x\(String(productID, radix: 16, uppercase: true)))")
            }
            
            // Always pass the device to the callback - RemoteInputHandler needs all HID interfaces
            DispatchQueue.main.async {
                self.deviceCallback?(device)
            }
        }
    }
    
    func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard isSiriRemote(device) else { return }
        
        // Get device properties (safe to read from any thread)
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        
        // Create the same key based on vendor+product
        let deviceKey = "\(vendorID):\(productID)"
        
        // Use a serialized queue to prevent race conditions
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Only process removal if we've seen this device before
            guard self.processedDeviceKeys.contains(deviceKey) else { return }
            
            self.processedDeviceKeys.remove(deviceKey)
            self.connectedDeviceCount = max(0, self.connectedDeviceCount - 1)
            
            if self.connectedDeviceCount == 0 {
                let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
                print("❌ Siri Remote disconnected: \(productName)")
                self.currentDevice = nil
                DispatchQueue.main.async {
                    self.deviceCallback?(nil)
                }
            }
        }
    }
}

// C callbacks
private func deviceAddedCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceAdded(device)
}

private func deviceRemovedCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceRemoved(device)
}

//
//  RemoteDetector.swift
//  Remotastic
//
//  Detects Siri Remote via IOKit HID
//

import IOKit
import IOKit.hid

class RemoteDetector {
    private var manager: IOHIDManager?
    private var deviceCallback: ((IOHIDDevice?) -> Void)?
    private var currentDevice: IOHIDDevice?
    private var connectedDeviceCount = 0
    // Track devices by vendorID:productID combination
    // A single physical Siri Remote may expose multiple HID interfaces, but we only want to process one
    private var processedDeviceKeys: Set<String> = []
    private let processingQueue = DispatchQueue(label: "com.remotastic.deviceProcessing")
    
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
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else { return }
        
        let matchingDict: [String: Any] = [kIOHIDVendorIDKey: appleVendorID]
        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)
        
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAddedCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, Unmanaged.passUnretained(self).toOpaque())
        
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        
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
              let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        
        // Use the same isSiriRemote check for consistency
        for device in deviceSet {
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

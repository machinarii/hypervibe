//
//  CursorController.swift
//  Remotastic
//
//  Controls cursor movement and clicking using CGEvent
//

import CoreGraphics
import CoreFoundation
import Foundation
import AppKit

class CursorController {
    private let sensitivity: CGFloat = 2.0
    private let acceleration: CGFloat = 1.2
    
    var isDragging: Bool = false
    var isClickActive: Bool = false
    
    /// System alert sound for key press and tap-to-click (one path for CLI and app).
    static func playKeyPressFeedback() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { playKeyPressFeedback() }
            return
        }
        // NSSound.beep() plays user's system alert sound (documented Cocoa API).
        NSSound.beep()
    }
    
    // MARK: - Helper Functions
    
    /// Finds the screen containing the given point
    /// Uses explicit bounds checking to handle coordinate system correctly
    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        return NSScreen.screens.first { screen in
            let frame = screen.frame
            // Explicit bounds check (CGRect.contains can have edge cases)
            return point.x >= frame.minX && 
                   point.x < frame.maxX && 
                   point.y >= frame.minY && 
                   point.y < frame.maxY
        }
    }
    
    // MARK: - Cursor Movement
    
    // Returns true if cursor is at an edge of the current screen and would be clamped
    @discardableResult
    func moveCursor(deltaX: CGFloat, deltaY: CGFloat) -> (clampedX: Bool, clampedY: Bool) {
        let scaledDeltaX = deltaX * sensitivity * (abs(deltaX) > 5 ? acceleration : 1.0)
        let scaledDeltaY = deltaY * sensitivity * (abs(deltaY) > 5 ? acceleration : 1.0)

            // Get current cursor position - use CGEvent which gives us global Quartz coordinates
        // This works correctly across all displays
        let beforePosition: CGPoint
        if let event = CGEvent(source: nil), event.location != .zero {
            beforePosition = event.location
        } else {
            // Fallback: use NSEvent and convert to Quartz coordinates
            let nsLocation = NSEvent.mouseLocation
            if let mainScreen = NSScreen.main {
                let mainFrame = mainScreen.frame
                let mainHeight = mainFrame.height
                // NSEvent.mouseLocation is relative to main screen's bottom-left
                // Convert to global Quartz coordinates
                beforePosition = CGPoint(
                    x: mainFrame.minX + nsLocation.x,
                    y: mainFrame.minY + (mainHeight - nsLocation.y)
                )
            } else {
                beforePosition = CGPoint(x: nsLocation.x, y: nsLocation.y)
            }
        }
        
        // Find current screen containing cursor for edge detection
        let currentScreen = screenContaining(beforePosition)
        let screenFrame = currentScreen?.frame
        
        // Calculate target position - don't clamp, let macOS handle multi-monitor movement
        let targetX = beforePosition.x + scaledDeltaX
        let targetY = beforePosition.y + scaledDeltaY
        let targetPosition = CGPoint(x: targetX, y: targetY)
        
        // Edge detection for CURRENT screen only (if we found one)
        var clampedX = false
        var clampedY = false
        
        if let frame = screenFrame {
            // Only report clamped if we're at the edge of current screen AND trying to move further
            let atLeftEdge = beforePosition.x <= frame.minX + 1 && scaledDeltaX < 0
            let atRightEdge = beforePosition.x >= frame.maxX - 1 && scaledDeltaX > 0
            let atTopEdge = beforePosition.y <= frame.minY + 1 && scaledDeltaY < 0
            let atBottomEdge = beforePosition.y >= frame.maxY - 1 && scaledDeltaY > 0
            
            clampedX = atLeftEdge || atRightEdge
            clampedY = atTopEdge || atBottomEdge
        }
        
        // Post the event - macOS handles all coordinate system conversions and multi-monitor movement
        let eventType: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: targetPosition, mouseButton: .left) else {
            return (clampedX, clampedY)
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)

        return (clampedX, clampedY)
    }
    
    func performClick() {
        let currentPosition = CGEvent(source: nil)?.location ?? .zero
        
        // Mouse down
        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        downEvent.post(tap: CGEventTapLocation.cghidEventTap)
        
        // Small delay
        usleep(10000) // 10ms
        
        // Mouse up
        guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        upEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func performRightClick() {
        let currentPosition = CGEvent(source: nil)?.location ?? .zero
        
        // Right mouse down
        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: currentPosition, mouseButton: .right) else {
            return
        }
        downEvent.post(tap: CGEventTapLocation.cghidEventTap)
        
        // Small delay
        usleep(10000) // 10ms
        
        // Right mouse up
        guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: currentPosition, mouseButton: .right) else {
            return
        }
        upEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func mouseDown() {
        let currentPosition = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func mouseUp() {
        let currentPosition = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func scroll(deltaX: Int32, deltaY: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func sendKeyPress(keyCode: CGKeyCode) {
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        
        keyDownEvent.post(tap: .cghidEventTap)
        usleep(50000) // 50ms
        keyUpEvent.post(tap: .cghidEventTap)
    }
}

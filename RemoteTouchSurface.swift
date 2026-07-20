//
//  RemoteTouchSurface.swift
//  HyperVibe
//
//  Device-identity discrimination for the touch/gesture path.
//
//  RemoteDetector.isSiriRemote() identifies the remote's HID button interfaces by
//  vendor/product ID. The private MultitouchSupport framework used for the trackpad surface
//  (TouchHandler) exposes no vendor/product ID at all — only sensor-surface geometry and a
//  builtIn flag. This file is the touch-path equivalent of that identity check: it is kept
//  framework-free (no IOKit / MultitouchSupport / AppKit imports) purely so the discrimination
//  logic can be unit-tested without linking the private framework.

import Foundation

enum RemoteTouchSurface {
    /// Upper bound on sensor-surface area (raw MT units: width * height) admitted as
    /// "the Siri Remote's touch surface". The remote's pad is tiny (~3460x3640 ≈ 12.6M);
    /// the smallest external Apple Magic Trackpad is over an order of magnitude larger
    /// (~15600x11040 ≈ 172M — figures already used as the disambiguating reference in
    /// TouchHandler's device-selection heuristic). 30M gives generous headroom above every
    /// known Siri Remote generation while staying far below any Magic Trackpad model.
    static let maxSurfaceArea: Int64 = 30_000_000

    /// True only when (width, height, builtIn) are consistent with the Siri Remote's touch
    /// surface. Fails closed: a zero/negative reading, a built-in trackpad, or anything at or
    /// above `maxSurfaceArea` (a Magic Trackpad, or any other multitouch device) returns
    /// false. Callers must treat false as "not the remote" — do not open the device, do not
    /// consume its events.
    static func isEligibleRemoteSurface(width: Int32, height: Int32, builtIn: Bool) -> Bool {
        guard !builtIn, width > 0, height > 0 else { return false }
        let area = Int64(width) * Int64(height)
        return area <= maxSurfaceArea
    }
}

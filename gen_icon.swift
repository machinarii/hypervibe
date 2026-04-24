import Foundation
import AppKit
import CoreGraphics

/// Render one frame of the HyperVibe icon at the given pixel size.
/// Design: squircle with purple→pink gradient + white "H" whose crossbar is a sine wave.
func renderIcon(size: CGFloat) -> Data? {
    let w = Int(size), h = Int(size)
    let space = CGColorSpaceCreateDeviceRGB()
    let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: space, bitmapInfo: bitmap.rawValue
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225  // macOS Big Sur+ squircle ratio

    // Clip to rounded-rect, then fill with vertical gradient
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    ctx.clip()

    // Three-stop gradient in shades of #F07654 (warm coral): darker on top,
    // base in the middle, lighter peach at the bottom.
    let colors = [
        CGColor(red: 194/255, green:  68/255, blue:  32/255, alpha: 1),   // #C24420 (darker)
        CGColor(red: 240/255, green: 118/255, blue:  84/255, alpha: 1),   // #F07654 (base)
        CGColor(red: 249/255, green: 187/255, blue: 166/255, alpha: 1),   // #F9BBA6 (lighter)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: size),
                           end:   CGPoint(x: 0, y: 0),
                           options: [])

    // White walkie-talkie silhouette (same shape family as the menu-bar glyph).
    // Body + display/speaker cutouts rendered as one even-odd path so the holes stay transparent
    // and the purple→pink gradient shows through them (screen looks "on", speaker looks "open").
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    let bodyRect    = CGRect(x: 0.300 * size, y: 0.150 * size, width: 0.400 * size, height: 0.590 * size)
    let displayRect = CGRect(x: 0.355 * size, y: 0.610 * size, width: 0.290 * size, height: 0.070 * size)
    let speakerRect = CGRect(x: 0.385 * size, y: 0.220 * size, width: 0.230 * size, height: 0.230 * size)
    let bodyRadius:    CGFloat = 0.042 * size
    let displayRadius: CGFloat = 0.014 * size

    let walkie = CGMutablePath()
    walkie.addPath(CGPath(roundedRect: bodyRect,    cornerWidth: bodyRadius,    cornerHeight: bodyRadius,    transform: nil))
    walkie.addPath(CGPath(roundedRect: displayRect, cornerWidth: displayRadius, cornerHeight: displayRadius, transform: nil))
    walkie.addEllipse(in: speakerRect)

    ctx.setFillColor(white)
    ctx.addPath(walkie)
    ctx.fillPath(using: .evenOdd)

    // Single antenna rising from left-of-center above the body.
    ctx.setStrokeColor(white)
    ctx.setLineWidth(0.028 * size)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 0.425 * size, y: 0.740 * size))
    ctx.addLine(to: CGPoint(x: 0.425 * size, y: 0.905 * size))
    ctx.strokePath()

    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

// Standard macOS iconset sizes
let frames: [(name: String, px: Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png",1024),
]

let outDir = URL(fileURLWithPath: "HyperVibe.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for frame in frames {
    guard let data = renderIcon(size: CGFloat(frame.px)) else {
        print("Failed to render \(frame.name)")
        continue
    }
    try data.write(to: outDir.appendingPathComponent(frame.name))
}
print("Wrote \(frames.count) frames to HyperVibe.iconset/")

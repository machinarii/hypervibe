import Foundation
import AppKit
import CoreGraphics

/// Render a GitHub social-preview banner (1280×640) — icon on the left, wordmark + tagline on the right.
func renderBanner(width: CGFloat = 1280, height: CGFloat = 640) -> Data? {
    let w = Int(width), h = Int(height)
    let space = CGColorSpaceCreateDeviceRGB()
    let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: space, bitmapInfo: bitmap.rawValue
    ) else { return nil }

    // Background: same coral gradient as the app icon (top-to-bottom).
    let colors = [
        CGColor(red: 194/255, green:  68/255, blue:  32/255, alpha: 1),
        CGColor(red: 240/255, green: 118/255, blue:  84/255, alpha: 1),
        CGColor(red: 249/255, green: 187/255, blue: 166/255, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: height),
                           end:   CGPoint(x: 0, y: 0),
                           options: [])

    // Walkie-talkie silhouette on the left (proportions match gen_icon.swift).
    let iconSize: CGFloat = 380
    let iconX: CGFloat = 100
    let iconY: CGFloat = (height - iconSize) / 2

    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let bodyRect    = CGRect(x: iconX + 0.300 * iconSize, y: iconY + 0.150 * iconSize, width: 0.400 * iconSize, height: 0.590 * iconSize)
    let displayRect = CGRect(x: iconX + 0.355 * iconSize, y: iconY + 0.610 * iconSize, width: 0.290 * iconSize, height: 0.070 * iconSize)
    let speakerRect = CGRect(x: iconX + 0.385 * iconSize, y: iconY + 0.220 * iconSize, width: 0.230 * iconSize, height: 0.230 * iconSize)
    let bodyRadius:    CGFloat = 0.042 * iconSize
    let displayRadius: CGFloat = 0.014 * iconSize

    let walkie = CGMutablePath()
    walkie.addPath(CGPath(roundedRect: bodyRect,    cornerWidth: bodyRadius,    cornerHeight: bodyRadius,    transform: nil))
    walkie.addPath(CGPath(roundedRect: displayRect, cornerWidth: displayRadius, cornerHeight: displayRadius, transform: nil))
    walkie.addEllipse(in: speakerRect)

    ctx.setFillColor(white)
    ctx.addPath(walkie)
    ctx.fillPath(using: .evenOdd)

    ctx.setStrokeColor(white)
    ctx.setLineWidth(0.028 * iconSize)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: iconX + 0.425 * iconSize, y: iconY + 0.740 * iconSize))
    ctx.addLine(to: CGPoint(x: iconX + 0.425 * iconSize, y: iconY + 0.905 * iconSize))
    ctx.strokePath()

    // Wordmark + tagline on the right, via NSAttributedString over the same CGContext.
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let textX: CGFloat = 520
    let title = NSAttributedString(string: "HyperVibe", attributes: [
        .font: NSFont.systemFont(ofSize: 120, weight: .heavy),
        .foregroundColor: NSColor.white,
    ])
    let tagline = NSAttributedString(string: "A walkie-talkie for Claude Code", attributes: [
        .font: NSFont.systemFont(ofSize: 36, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ])

    let titleSize = title.size()
    let taglineSize = tagline.size()
    let spacing: CGFloat = 18
    let blockHeight = titleSize.height + taglineSize.height + spacing
    let blockStartY = (height - blockHeight) / 2

    // Non-flipped context: y increases upward, so tagline sits below the title.
    let taglineY = blockStartY
    let titleY = blockStartY + taglineSize.height + spacing

    title.draw(at: NSPoint(x: textX, y: titleY))
    tagline.draw(at: NSPoint(x: textX, y: taglineY))

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

guard let data = renderBanner() else {
    print("Failed to render banner")
    exit(1)
}
try data.write(to: URL(fileURLWithPath: "banner.png"))
print("Wrote banner.png (1280×640)")

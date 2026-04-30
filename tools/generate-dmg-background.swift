// Generates the DMG installer-window background PNG for MailMate.
// Usage: swift tools/generate-dmg-background.swift <output.png>
//
// Window layout (matches build-dmg.sh AppleScript):
//   540x380 content; app icon centered at (135,170), Applications at (405,170)
//   measured from top-left of window content (Finder icon-view coords).
//   This file draws the background image; build-dmg.sh positions the icons.

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift generate-dmg-background.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outURL = URL(fileURLWithPath: args[1])

let size = NSSize(width: 540, height: 380)
let rect = CGRect(origin: .zero, size: size)

let image = NSImage(size: size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no context")
}

// --- Background: dark vertical gradient (--bg-soft -> --bg)
let bgColors: [CGColor] = [
    NSColor(red: 0.078, green: 0.102, blue: 0.180, alpha: 1).cgColor, // top
    NSColor(red: 0.047, green: 0.059, blue: 0.110, alpha: 1).cgColor, // bottom
]
let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: bgColors as CFArray,
                            locations: [0.0, 1.0])!
ctx.drawLinearGradient(bgGradient,
                       start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.minY),
                       options: [])

// --- Soft radial highlight behind the icon row
let glowColors: [CGColor] = [
    NSColor(red: 0.36, green: 0.43, blue: 0.95, alpha: 0.18).cgColor,
    NSColor(red: 0.36, green: 0.43, blue: 0.95, alpha: 0.0).cgColor,
]
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: glowColors as CFArray,
                      locations: [0.0, 1.0])!
// Convert (135, 170 from top) -> (135, 380-170=210) in CG bottom-left coords.
let iconY: CGFloat = 380 - 170
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: rect.midX, y: iconY),
                       startRadius: 0,
                       endCenter: CGPoint(x: rect.midX, y: iconY),
                       endRadius: 280,
                       options: [])

// --- Arrow between the two icon positions: left icon at x=135, right at x=405.
// Stop arrow short of each icon (~64px wide rendered) to leave breathing room.
let arrowStart = CGPoint(x: 200, y: iconY)
let arrowEnd = CGPoint(x: 340, y: iconY)
let arrowHeadLen: CGFloat = 18
let arrowHeadHalfW: CGFloat = 12
let arrowLineW: CGFloat = 4

ctx.saveGState()
let arrowColors: [CGColor] = [
    NSColor(red: 0.36, green: 0.43, blue: 0.95, alpha: 0.85).cgColor, // indigo
    NSColor(red: 0.55, green: 0.32, blue: 0.90, alpha: 0.85).cgColor, // violet
]
let arrowGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: arrowColors as CFArray,
                               locations: [0.0, 1.0])!

// Shaft
ctx.saveGState()
let shaft = CGRect(x: arrowStart.x,
                   y: arrowStart.y - arrowLineW / 2,
                   width: arrowEnd.x - arrowStart.x - arrowHeadLen + 2,
                   height: arrowLineW)
let shaftPath = CGPath(roundedRect: shaft, cornerWidth: arrowLineW / 2, cornerHeight: arrowLineW / 2, transform: nil)
ctx.addPath(shaftPath)
ctx.clip()
ctx.drawLinearGradient(arrowGradient,
                       start: CGPoint(x: arrowStart.x, y: 0),
                       end: CGPoint(x: arrowEnd.x, y: 0),
                       options: [])
ctx.restoreGState()

// Head
ctx.saveGState()
let head = CGMutablePath()
head.move(to: CGPoint(x: arrowEnd.x, y: arrowEnd.y))
head.addLine(to: CGPoint(x: arrowEnd.x - arrowHeadLen, y: arrowEnd.y + arrowHeadHalfW))
head.addLine(to: CGPoint(x: arrowEnd.x - arrowHeadLen, y: arrowEnd.y - arrowHeadHalfW))
head.closeSubpath()
ctx.addPath(head)
ctx.clip()
ctx.drawLinearGradient(arrowGradient,
                       start: CGPoint(x: arrowEnd.x - arrowHeadLen, y: 0),
                       end: CGPoint(x: arrowEnd.x, y: 0),
                       options: [])
ctx.restoreGState()
ctx.restoreGState()

// --- Caption above the arrow
let caption = "Drag MailMate to your Applications folder"
let captionAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(white: 1, alpha: 0.55),
    .kern: 0.2,
]
let captionStr = NSAttributedString(string: caption, attributes: captionAttrs)
let captionSize = captionStr.size()
captionStr.draw(at: CGPoint(x: (size.width - captionSize.width) / 2,
                            y: iconY + 50))

// --- Subcaption below: brand-line tint
let sub = "MailMate · v1.0"
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor(white: 1, alpha: 0.28),
    .kern: 0.4,
]
let subStr = NSAttributedString(string: sub, attributes: subAttrs)
let subSize = subStr.size()
subStr.draw(at: CGPoint(x: (size.width - subSize.width) / 2, y: 22))

image.unlockFocus()

// Write PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: outURL)
print("Wrote \(outURL.path)")

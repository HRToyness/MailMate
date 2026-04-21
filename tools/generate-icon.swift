// Generates a 1024x1024 PNG app icon for MailMate.
// Usage: swift tools/generate-icon.swift <output.png>

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift generate-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outURL = URL(fileURLWithPath: args[1])

let size: CGFloat = 1024
let rect = CGRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no context")
}

// --- Background: rounded-square with vertical gradient (indigo -> violet)
let cornerRadius = size * 0.2237 // macOS squircle approximation
let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

let bgColors: [CGColor] = [
    NSColor(red: 0.36, green: 0.43, blue: 0.95, alpha: 1).cgColor, // top: indigo
    NSColor(red: 0.55, green: 0.32, blue: 0.90, alpha: 1).cgColor, // bottom: violet
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: bgColors as CFArray,
                          locations: [0.0, 1.0])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: size / 2, y: size),
                       end: CGPoint(x: size / 2, y: 0),
                       options: [])

// Subtle top highlight for depth
let highlight: [CGColor] = [
    NSColor(white: 1, alpha: 0.18).cgColor,
    NSColor(white: 1, alpha: 0.0).cgColor,
]
let hiGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: highlight as CFArray,
                            locations: [0.0, 1.0])!
ctx.drawLinearGradient(hiGradient,
                       start: CGPoint(x: size / 2, y: size),
                       end: CGPoint(x: size / 2, y: size * 0.55),
                       options: [])
ctx.restoreGState()

// --- Envelope glyph (white, centered, slightly lower third)
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Envelope bounds — wider than tall, sits centered
let envWidth = size * 0.64
let envHeight = envWidth * 0.66
let envX = (size - envWidth) / 2
let envY = (size - envHeight) / 2 - size * 0.02
let env = CGRect(x: envX, y: envY, width: envWidth, height: envHeight)

let envCorner = envHeight * 0.10
let envPath = CGPath(roundedRect: env, cornerWidth: envCorner, cornerHeight: envCorner, transform: nil)

// Envelope body — white fill with soft drop shadow
ctx.setShadow(offset: CGSize(width: 0, height: -10),
              blur: 30,
              color: NSColor(white: 0, alpha: 0.25).cgColor)
ctx.addPath(envPath)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Envelope flap — triangle "V" drawn in the envelope's primary color
ctx.addPath(envPath)
ctx.clip()

let flapColor = NSColor(red: 0.36, green: 0.43, blue: 0.95, alpha: 1).cgColor
ctx.setStrokeColor(flapColor)
ctx.setLineWidth(size * 0.035)
ctx.move(to: CGPoint(x: env.minX + envWidth * 0.06, y: env.maxY - envHeight * 0.08))
ctx.addLine(to: CGPoint(x: env.midX,              y: env.midY + envHeight * 0.04))
ctx.addLine(to: CGPoint(x: env.maxX - envWidth * 0.06, y: env.maxY - envHeight * 0.08))
ctx.strokePath()
ctx.restoreGState()

// --- AI sparkle (small, top-right of envelope)
ctx.saveGState()
let sparkCenter = CGPoint(x: env.maxX - envWidth * 0.04, y: env.maxY + envHeight * 0.04)
let sparkR: CGFloat = size * 0.055
func sparkle(at c: CGPoint, radius r: CGFloat) {
    // 4-pointed star: long vertical + long horizontal + short diagonals
    let tip: CGFloat = r
    let thick: CGFloat = r * 0.22
    let path = CGMutablePath()
    // vertical diamond
    path.move(to: CGPoint(x: c.x, y: c.y + tip))
    path.addLine(to: CGPoint(x: c.x + thick, y: c.y))
    path.addLine(to: CGPoint(x: c.x, y: c.y - tip))
    path.addLine(to: CGPoint(x: c.x - thick, y: c.y))
    path.closeSubpath()
    // horizontal diamond
    path.move(to: CGPoint(x: c.x - tip, y: c.y))
    path.addLine(to: CGPoint(x: c.x, y: c.y + thick))
    path.addLine(to: CGPoint(x: c.x + tip, y: c.y))
    path.addLine(to: CGPoint(x: c.x, y: c.y - thick))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.fillPath()
}
// White fill, slight yellow glow
ctx.setShadow(offset: .zero, blur: 30, color: NSColor(red: 1, green: 0.9, blue: 0.4, alpha: 0.8).cgColor)
ctx.setFillColor(NSColor.white.cgColor)
sparkle(at: sparkCenter, radius: sparkR)
// Smaller sparkle
ctx.setShadow(offset: .zero, blur: 15, color: NSColor(red: 1, green: 0.9, blue: 0.4, alpha: 0.6).cgColor)
sparkle(at: CGPoint(x: sparkCenter.x - sparkR * 1.6, y: sparkCenter.y - sparkR * 1.2),
        radius: sparkR * 0.55)
ctx.restoreGState()

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

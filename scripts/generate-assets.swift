#!/usr/bin/env swift

import Foundation
import AppKit

// Generate all required assets for KiteGlance macOS
let projectDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let backdropsDir = projectDir.appendingPathComponent("Sources/KiteGlance/Assets/Backdrops", isDirectory: true)
let iconsDir = projectDir.appendingPathComponent("Sources/KiteGlance/Assets/Icons", isDirectory: true)

try? FileManager.default.createDirectory(at: backdropsDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)

let size = NSSize(width: 800, height: 600)

// 8 time-based mesh-gradient backdrops
let backdrops: [(String, NSColor, NSColor)] = [
    ("backdrop-dawn",      NSColor(red: 0.95, green: 0.65, blue: 0.35, alpha: 1), NSColor(red: 0.85, green: 0.45, blue: 0.25, alpha: 1)),
    ("backdrop-sunrise",   NSColor(red: 1.00, green: 0.55, blue: 0.25, alpha: 1), NSColor(red: 0.95, green: 0.35, blue: 0.15, alpha: 1)),
    ("backdrop-day",       NSColor(red: 0.35, green: 0.65, blue: 0.95, alpha: 1), NSColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1)),
    ("backdrop-noon",      NSColor(red: 0.25, green: 0.55, blue: 0.90, alpha: 1), NSColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 1)),
    ("backdrop-dusk",      NSColor(red: 0.95, green: 0.45, blue: 0.35, alpha: 1), NSColor(red: 0.80, green: 0.25, blue: 0.20, alpha: 1)),
    ("backdrop-evening",   NSColor(red: 0.35, green: 0.25, blue: 0.55, alpha: 1), NSColor(red: 0.20, green: 0.15, blue: 0.40, alpha: 1)),
    ("backdrop-night",     NSColor(red: 0.15, green: 0.12, blue: 0.25, alpha: 1), NSColor(red: 0.08, green: 0.06, blue: 0.15, alpha: 1)),
    ("backdrop-midnight",  NSColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1), NSColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1)),
]

for (name, startColor, endColor) in backdrops {
    let image = NSImage(size: size)
    image.lockFocus()
    let gradient = NSGradient(colors: [startColor, endColor])!
    gradient.draw(in: NSRect(origin: .zero, size: size), angle: 135)
    // Add subtle vignette
    let vignette = NSGradient(colors: [
        NSColor(white: 0, alpha: 0),
        NSColor(white: 0, alpha: 0.3)
    ])!
    vignette.draw(in: NSRect(origin: .zero, size: size), angle: 90)
    image.unlockFocus()

    if let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: backdropsDir.appendingPathComponent("\(name).png"))
        print("Generated \(name).png")
    }
}

// Grain/noise overlay (128x128 tile)
let grainSize = NSSize(width: 128, height: 128)
let grainImage = NSImage(size: grainSize)
grainImage.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
for x in 0..<128 {
    for y in 0..<128 {
        let noise = Double.random(in: 0...1)
        ctx.setFillColor(CGColor(gray: CGFloat(noise), alpha: 0.028))
        ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
    }
}
grainImage.unlockFocus()

if let tiff = grainImage.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiff),
   let png = bitmap.representation(using: .png, properties: [:]) {
    try? png.write(to: backdropsDir.appendingPathComponent("grain.png"))
    print("Generated grain.png")
}

// App icon (1024x1024) - KiteGlance chart symbol
let iconSize = NSSize(width: 1024, height: 1024)
let iconImage = NSImage(size: iconSize)
iconImage.lockFocus()

// Background
let bgColor = NSColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1)
let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: iconSize), xRadius: 220, yRadius: 220)
bgColor.setFill()
bgPath.fill()

// Subtle gradient overlay
let iconGradient = NSGradient(colors: [
    NSColor(white: 1, alpha: 0.05),
    NSColor(white: 0, alpha: 0.1)
])!
iconGradient.draw(in: NSRect(origin: .zero, size: iconSize), angle: 90)

// Chart line (green upward trend)
let symbolColor = NSColor(red: 0x32/255, green: 0xD7/255, blue: 0x4B/255, alpha: 1)
let path = NSBezierPath()
path.move(to: NSPoint(x: 180, y: 580))
path.curve(to: NSPoint(x: 350, y: 420), controlPoint1: NSPoint(x: 230, y: 580), controlPoint2: NSPoint(x: 300, y: 480))
path.curve(to: NSPoint(x: 520, y: 520), controlPoint1: NSPoint(x: 400, y: 360), controlPoint2: NSPoint(x: 470, y: 480))
path.curve(to: NSPoint(x: 680, y: 400), controlPoint1: NSPoint(x: 570, y: 560), controlPoint2: NSPoint(x: 630, y: 460))
path.curve(to: NSPoint(x: 844, y: 480), controlPoint1: NSPoint(x: 730, y: 340), controlPoint2: NSPoint(x: 794, y: 420))
path.lineWidth = 72
path.lineCapStyle = .round
path.lineJoinStyle = .round
symbolColor.setStroke()
path.stroke()

// Glow effect
let glowPath = path.copy() as! NSBezierPath
glowPath.lineWidth = 120
NSColor(red: 0x32/255, green: 0xD7/255, blue: 0x4B/255, alpha: 0.15).setStroke()
glowPath.stroke()

iconImage.unlockFocus()

if let tiff = iconImage.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiff),
   let png = bitmap.representation(using: .png, properties: [:]) {
    try? png.write(to: iconsDir.appendingPathComponent("app-icon.png"))
    print("Generated app-icon.png")
}

print("\nAll assets generated successfully!")
print("Backdrops: \(backdropsDir.path)")
print("Icons: \(iconsDir.path)")
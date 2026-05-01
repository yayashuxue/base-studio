#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Generate AppIcon.iconset/* PNGs at all macOS sizes, then call iconutil.
// Run via:  ./scripts/make-icon.swift
// Output:   Resources/AppIcon.icns

let sizes: [(filename: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func draw(size px: Int) -> NSImage {
    let dim = CGFloat(px)
    let img = NSImage(size: NSSize(width: dim, height: dim))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

    // Rounded rect background with gradient.
    let radius = dim * 0.225
    let rect = CGRect(x: 0, y: 0, width: dim, height: dim)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path); ctx.clip()

    let cs = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(srgbRed: 0.34, green: 0.27, blue: 0.92, alpha: 1.0),
        CGColor(srgbRed: 0.18, green: 0.12, blue: 0.55, alpha: 1.0),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: dim),
                           end: CGPoint(x: 0, y: 0), options: [])

    // Inner soft glow.
    let glow = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: dim * 0.3, y: dim * 0.75), startRadius: 0,
        endCenter: CGPoint(x: dim * 0.3, y: dim * 0.75), endRadius: dim * 0.6,
        options: []
    )

    // Recording dot — solid red circle in lower right.
    let dotR = dim * 0.16
    let dotCenter = CGPoint(x: dim * 0.68, y: dim * 0.32)
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.18, blue: 0.22, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(
        x: dotCenter.x - dotR, y: dotCenter.y - dotR,
        width: dotR * 2, height: dotR * 2
    ))

    // White play triangle inside the dot.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1.0))
    let tri = CGMutablePath()
    let tw = dotR * 0.95
    let th = dotR * 1.15
    let cx = dotCenter.x + dotR * 0.08
    let cy = dotCenter.y
    tri.move(to: CGPoint(x: cx - tw * 0.4, y: cy + th * 0.5))
    tri.addLine(to: CGPoint(x: cx - tw * 0.4, y: cy - th * 0.5))
    tri.addLine(to: CGPoint(x: cx + tw * 0.55, y: cy))
    tri.closeSubpath()
    ctx.addPath(tri); ctx.fillPath()

    // Subtle screen-frame outline (top half).
    let screenW = dim * 0.78
    let screenH = dim * 0.46
    let screenRect = CGRect(
        x: (dim - screenW) / 2, y: dim * 0.42,
        width: screenW, height: screenH
    )
    let screenPath = CGPath(
        roundedRect: screenRect,
        cornerWidth: dim * 0.08, cornerHeight: dim * 0.08,
        transform: nil
    )
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
    ctx.setLineWidth(max(2, dim * 0.018))
    ctx.addPath(screenPath); ctx.strokePath()

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let cwd = FileManager.default.currentDirectoryPath
let iconset = URL(fileURLWithPath: cwd).appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for entry in sizes {
    let img = draw(size: entry.px)
    let url = iconset.appendingPathComponent(entry.filename)
    writePNG(img, to: url)
}
print("✓ Wrote \(sizes.count) PNGs to \(iconset.path)")

// Run iconutil to assemble .icns.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = [
    "-c", "icns", iconset.path,
    "-o", URL(fileURLWithPath: cwd).appendingPathComponent("Resources/AppIcon.icns").path
]
do {
    try task.run()
    task.waitUntilExit()
    if task.terminationStatus == 0 {
        print("✓ Built Resources/AppIcon.icns")
    } else {
        print("✗ iconutil failed with status \(task.terminationStatus)")
    }
} catch {
    print("✗ iconutil error: \(error)")
}

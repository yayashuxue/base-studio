#!/usr/bin/env swift
// Generates 3 alternative logo concepts as 512x512 PNGs + a side-by-side
// comparison sheet for design review. Does NOT touch the live AppIcon.icns.
//
//   ./scripts/logo-concepts.swift
//   → Resources/logo-concepts/{A,B,C}_512.png + Resources/logo-concepts/sheet.png

import AppKit
import CoreGraphics

let DIM: CGFloat = 512

// ── Palette ────────────────────────────────────────────────────────────────
let bgPurple1 = CGColor(srgbRed: 0.34, green: 0.27, blue: 0.92, alpha: 1.0)
let bgPurple2 = CGColor(srgbRed: 0.18, green: 0.12, blue: 0.55, alpha: 1.0)
let bgDark1   = CGColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1.0)
let bgDark2   = CGColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
let bgWarm1   = CGColor(srgbRed: 1.00, green: 0.62, blue: 0.20, alpha: 1.0)
let bgWarm2   = CGColor(srgbRed: 0.95, green: 0.34, blue: 0.18, alpha: 1.0)

let fg = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let cs = CGColorSpaceCreateDeviceRGB()

// ── Helpers ────────────────────────────────────────────────────────────────
func roundedClip(_ ctx: CGContext, dim: CGFloat, radius: CGFloat) {
    let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: dim, height: dim),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path); ctx.clip()
}

func linearGradient(_ ctx: CGContext, dim: CGFloat, top: CGColor, bottom: CGColor) {
    let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: dim),
                           end: CGPoint(x: 0, y: 0), options: [])
}

func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
                alpha: CGFloat = 0.18) {
    let g = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

// ── Concept A: "Frame-snap" ────────────────────────────────────────────────
// Engineered precision: outer frame + inner frame perfectly aligned via
// four L-bracket corner marks. Reads "by-construction-correct framing".
// Maps to README's "those failure modes are impossible by construction".
func drawA(_ ctx: CGContext, dim: CGFloat) {
    roundedClip(ctx, dim: dim, radius: dim * 0.225)
    linearGradient(ctx, dim: dim, top: bgPurple1, bottom: bgPurple2)
    radialGlow(ctx, center: CGPoint(x: dim * 0.3, y: dim * 0.78), radius: dim * 0.7)

    let cx = dim / 2, cy = dim / 2
    let outerHalf = dim * 0.30
    let innerHalf = dim * 0.18
    let bracketLen = dim * 0.075
    let lw = max(3, dim * 0.024)

    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)

    // Inner solid frame (the "what you record")
    ctx.stroke(CGRect(x: cx - innerHalf, y: cy - innerHalf,
                      width: innerHalf * 2, height: innerHalf * 2))

    // Four corner brackets at outer-frame positions (the "container")
    let corners: [(CGFloat, CGFloat)] = [
        (-outerHalf, -outerHalf), ( outerHalf, -outerHalf),
        (-outerHalf,  outerHalf), ( outerHalf,  outerHalf),
    ]
    ctx.setLineWidth(lw * 1.4)
    for (dx, dy) in corners {
        let px = cx + dx, py = cy + dy
        let sx: CGFloat = dx < 0 ? 1 : -1
        let sy: CGFloat = dy < 0 ? 1 : -1
        ctx.move(to: CGPoint(x: px, y: py))
        ctx.addLine(to: CGPoint(x: px + sx * bracketLen, y: py))
        ctx.move(to: CGPoint(x: px, y: py))
        ctx.addLine(to: CGPoint(x: px, y: py + sy * bracketLen))
        ctx.strokePath()
    }

    // Tiny accent: amber dot center (recording is live)
    let dotR = dim * 0.025
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.74, blue: 0.20, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR,
                               width: dotR * 2, height: dotR * 2))
}

// ── Concept B: "BS monogram" ───────────────────────────────────────────────
// Bold typographic mark. Slab-serif B with a small dot replacing the bowl
// pinch — works as both a brand mark AND an app icon. Scales legibly to 16px.
func drawB(_ ctx: CGContext, dim: CGFloat) {
    roundedClip(ctx, dim: dim, radius: dim * 0.225)
    linearGradient(ctx, dim: dim, top: bgDark1, bottom: bgDark2)
    radialGlow(ctx, center: CGPoint(x: dim * 0.7, y: dim * 0.75),
               radius: dim * 0.55, alpha: 0.10)

    // Geometric "B" built from two stacked rounded rects + spine
    let spineW = dim * 0.10
    let bowlR = dim * 0.21
    let h = dim * 0.62
    let originX = dim * 0.30
    let originY = (dim - h) / 2
    let bowlOffsetX = originX + spineW * 0.5

    // Spine (left vertical)
    ctx.setFillColor(fg)
    ctx.fill(CGRect(x: originX, y: originY, width: spineW, height: h))

    // Two bowls (top + bottom)
    let bowls: [CGFloat] = [
        originY + h - bowlR * 2 + dim * 0.015,  // top bowl
        originY + dim * 0.01,                    // bottom bowl
    ]
    for by in bowls {
        let rect = CGRect(x: bowlOffsetX, y: by,
                          width: bowlR * 2, height: bowlR * 2)
        let bowl = CGPath(ellipseIn: rect, transform: nil)
        ctx.addPath(bowl); ctx.fillPath()
    }

    // Punch out negative space in each bowl (creates the B's interior)
    ctx.setBlendMode(.destinationOut)
    let innerR = bowlR * 0.50
    for by in bowls {
        let cy = by + bowlR
        let cx = bowlOffsetX + bowlR
        let rect = CGRect(x: cx - innerR, y: cy - innerR,
                          width: innerR * 2, height: innerR * 2)
        ctx.addPath(CGPath(ellipseIn: rect, transform: nil))
        ctx.fillPath()
    }
    ctx.setBlendMode(.normal)

    // Accent: amber dot in upper bowl's negative space (live indicator)
    let upperCy = bowls[0] + bowlR
    let upperCx = bowlOffsetX + bowlR
    let dotR = bowlR * 0.30
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.66, blue: 0.16, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: upperCx - dotR, y: upperCy - dotR,
                               width: dotR * 2, height: dotR * 2))
}

// ── Concept C: "Aperture frame" ────────────────────────────────────────────
// Camera iris reinterpreted as a 6-blade polygon that frames the canvas.
// Warm gradient = creative tool (vs cold purple = enterprise SaaS).
// Stronger personality than the current logo, less skeuomorphic than a
// literal play-triangle.
func drawC(_ ctx: CGContext, dim: CGFloat) {
    roundedClip(ctx, dim: dim, radius: dim * 0.225)
    linearGradient(ctx, dim: dim, top: bgWarm1, bottom: bgWarm2)
    radialGlow(ctx, center: CGPoint(x: dim * 0.3, y: dim * 0.75),
               radius: dim * 0.7, alpha: 0.22)

    let cx = dim / 2, cy = dim / 2
    let R = dim * 0.34
    let blades = 6

    // 6-blade iris: filled triangles rotated around center, with a
    // hexagonal "open" hole at the middle.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))

    let bladeAngle = 2 * CGFloat.pi / CGFloat(blades)
    let bladeSpread: CGFloat = 0.55  // < 1 = gaps between blades
    for i in 0..<blades {
        let theta = CGFloat(i) * bladeAngle - .pi / 2
        let p1 = CGPoint(x: cx + cos(theta) * R, y: cy + sin(theta) * R)
        let p2 = CGPoint(x: cx + cos(theta + bladeAngle * bladeSpread) * R,
                         y: cy + sin(theta + bladeAngle * bladeSpread) * R)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: cy))
        path.addLine(to: p1)
        path.addLine(to: p2)
        path.closeSubpath()
        ctx.addPath(path); ctx.fillPath()
    }

    // Punch hexagonal opening
    let openR = dim * 0.10
    let hex = CGMutablePath()
    for i in 0..<6 {
        let theta = CGFloat(i) * (.pi / 3) - .pi / 2
        let p = CGPoint(x: cx + cos(theta) * openR, y: cy + sin(theta) * openR)
        if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
    }
    hex.closeSubpath()
    ctx.setBlendMode(.destinationOut)
    ctx.addPath(hex); ctx.fillPath()
    ctx.setBlendMode(.normal)
}

// ── Render + write ─────────────────────────────────────────────────────────
func render(_ name: String, _ drawer: (CGContext, CGFloat) -> Void) -> NSImage {
    let img = NSImage(size: NSSize(width: DIM, height: DIM))
    img.lockFocus()
    if let ctx = NSGraphicsContext.current?.cgContext {
        drawer(ctx, DIM)
    }
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
let outDir = URL(fileURLWithPath: cwd).appendingPathComponent("Resources/logo-concepts")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let concepts: [(String, (CGContext, CGFloat) -> Void)] = [
    ("A_frame-snap", drawA),
    ("B_monogram",   drawB),
    ("C_aperture",   drawC),
]

var rendered: [NSImage] = []
for (name, drawer) in concepts {
    let img = render(name, drawer)
    rendered.append(img)
    writePNG(img, to: outDir.appendingPathComponent("\(name)_512.png"))
    print("✓ \(name)_512.png")
}

// Side-by-side comparison sheet: 3 concepts at 360px + 32px gutters + labels
let cellPx: CGFloat = 360
let labelH: CGFloat = 56
let gutter: CGFloat = 32
let sheetW = gutter + (cellPx + gutter) * CGFloat(concepts.count)
let sheetH = gutter + cellPx + labelH + gutter

let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
sheet.lockFocus()
if let ctx = NSGraphicsContext.current?.cgContext {
    // Dark backdrop for fair eval on both light/dark icons
    ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
}

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 18, weight: .medium),
    .foregroundColor: NSColor.white,
]
let labels = ["A — Frame-snap", "B — BS Monogram", "C — Aperture"]

for (i, img) in rendered.enumerated() {
    let x = gutter + (cellPx + gutter) * CGFloat(i)
    let y = gutter + labelH
    img.draw(in: NSRect(x: x, y: y, width: cellPx, height: cellPx),
             from: .zero, operation: .copy, fraction: 1.0)
    let label = NSAttributedString(string: labels[i], attributes: attrs)
    let size = label.size()
    label.draw(at: NSPoint(x: x + (cellPx - size.width) / 2,
                           y: gutter + (labelH - size.height) / 2))
}
sheet.unlockFocus()
writePNG(sheet, to: outDir.appendingPathComponent("sheet.png"))
print("✓ sheet.png (\(Int(sheetW))×\(Int(sheetH)))")

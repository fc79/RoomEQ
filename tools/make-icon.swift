// Generates the RoomEQ app icon (Resources/AppIcon.icns + AppIcon-1024.png).
//
// Regenerate with:  swift tools/make-icon.swift
//
// Every size is drawn directly as vector paths (no bitmap resizing).
// Design: 100x100 box (origin top-left) scaled into an 824x824 body centred
// on a 1024x1024 transparent canvas (standard macOS icon grid).

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Drawing

/// Draws the icon into a transparent square bitmap of `pixels` x `pixels`.
func renderIcon(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Map the 100x100 design box (origin top-left) onto the 824/1024 body.
    let canvas = CGFloat(pixels)
    let scale = canvas * (824.0 / 1024.0) / 100.0
    let margin = canvas * (100.0 / 1024.0)
    ctx.translateBy(x: margin, y: canvas - margin)
    ctx.scaleBy(x: scale, y: -scale)

    // Colours are created explicitly in sRGB (CGColor(red:...) would use a generic space).
    func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a])!
    }
    let white = srgb(1, 1, 1)

    // Background
    ctx.setFillColor(srgb(0x3B / 255.0, 0x5B / 255.0, 0xDB / 255.0))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                       cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.fillPath()

    // Room outline
    ctx.setStrokeColor(white)
    ctx.setLineWidth(4)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 20, y: 24, width: 60, height: 52),
                       cornerWidth: 3, cornerHeight: 3, transform: nil))
    ctx.strokePath()

    // S-shaped curve between x=22 and x=78, from y0 to y1.
    func curve(_ y0: CGFloat, _ y1: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 22, y: y0))
        p.addCurve(to: CGPoint(x: 78, y: y1),
                   control1: CGPoint(x: 40, y: y0), control2: CGPoint(x: 60, y: y1))
        return p
    }

    func stroke(_ path: CGPath, alpha: CGFloat, width: CGFloat, dash: [CGFloat] = []) {
        ctx.saveGState()
        ctx.setStrokeColor(white.copy(alpha: alpha)!)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: dash)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // "Before" waves: dashed, faint
    stroke(curve(34, 66), alpha: 0.35, width: 2.5, dash: [4, 4])
    stroke(curve(66, 34), alpha: 0.35, width: 2.5, dash: [4, 4])
    // "After" waves: solid
    stroke(curve(44, 56), alpha: 1.0, width: 4)
    stroke(curve(56, 44), alpha: 0.6, width: 4)

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"]) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
}

// MARK: - Main

let fm = FileManager.default
// Project root = parent of the tools/ folder that contains this script.
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")

let iconset = fm.temporaryDirectory
    .appendingPathComponent("RoomEQ-\(UUID().uuidString)")
    .appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset.deletingLastPathComponent()) }

// (file name, pixel size) as required by `iconutil`.
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

do {
    for (name, px) in entries {
        try writePNG(renderIcon(pixels: px), to: iconset.appendingPathComponent(name))
    }
    // Preview image
    try writePNG(renderIcon(pixels: 1024), to: resources.appendingPathComponent("AppIcon-1024.png"))

    let icns = resources.appendingPathComponent("AppIcon.icns")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil failed (\(task.terminationStatus))"])
    }
    print("Wrote \(icns.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

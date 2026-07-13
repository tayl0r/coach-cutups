#!/usr/bin/env swift
// Generates the Coach Cuts app icon set into
// apple/App/Assets.xcassets/AppIcon.appiconset/. Run from anywhere — paths
// are resolved relative to this script.
//
// Design: soccer ball over a horizontal film strip, on a dark teal squircle.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry helpers

let canvas: CGFloat = 1024
let safeMargin: CGFloat = 80           // Big-Sur-ish breathing room inside the 1024 canvas
let safeRect = CGRect(x: safeMargin,
                      y: safeMargin,
                      width: canvas - 2 * safeMargin,
                      height: canvas - 2 * safeMargin)
let cornerRadius = safeRect.width * 0.225

func regularPolygon(center: CGPoint, radius: CGFloat, sides: Int, rotation: CGFloat = 0) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<sides {
        let a = rotation + CGFloat(i) * (2 * .pi / CGFloat(sides)) - .pi / 2
        let p = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func drawIcon(into ctx: CGContext) {
    // Background squircle with a vertical gradient.
    let bgPath = CGPath(roundedRect: safeRect,
                        cornerWidth: cornerRadius,
                        cornerHeight: cornerRadius,
                        transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [
                                CGColor(red: 0.05, green: 0.18, blue: 0.18, alpha: 1),
                                CGColor(red: 0.02, green: 0.08, blue: 0.10, alpha: 1)
                              ] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: canvas),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
    ctx.restoreGState()

    // Subtle inner highlight on the squircle top edge.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let highlight = CGGradient(colorsSpace: colorSpace,
                               colors: [
                                CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
                                CGColor(red: 1, green: 1, blue: 1, alpha: 0)
                               ] as CFArray,
                               locations: [0, 1])!
    ctx.drawLinearGradient(highlight,
                           start: CGPoint(x: 0, y: canvas - safeMargin),
                           end: CGPoint(x: 0, y: canvas * 0.55),
                           options: [])
    ctx.restoreGState()

    // ---- Film strip ----
    // Horizontal band across the lower-middle, slight upward tilt for dynamism.
    // Clipped to the squircle so the strip doesn't bleed past the icon shape.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let stripCenterY: CGFloat = canvas * 0.42
    let stripHeight: CGFloat = 290
    let stripRect = CGRect(x: safeRect.minX - 40,
                           y: stripCenterY - stripHeight / 2,
                           width: safeRect.width + 80,
                           height: stripHeight)

    // Rotate around the center of the canvas for tilt.
    ctx.translateBy(x: canvas / 2, y: stripCenterY)
    ctx.rotate(by: -6 * .pi / 180)
    ctx.translateBy(x: -canvas / 2, y: -stripCenterY)

    // Strip body.
    ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
    ctx.fill(stripRect)

    // Edge bands (the lighter rails where sprocket holes punch through).
    let railHeight: CGFloat = 56
    ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: stripRect.minX, y: stripRect.maxY - railHeight,
                    width: stripRect.width, height: railHeight))
    ctx.fill(CGRect(x: stripRect.minX, y: stripRect.minY,
                    width: stripRect.width, height: railHeight))

    // Sprocket holes (top + bottom rows).
    let holeCount = 9
    let holeW: CGFloat = 56
    let holeH: CGFloat = 30
    let holeSpacing = stripRect.width / CGFloat(holeCount)
    ctx.setFillColor(CGColor(red: 0.03, green: 0.06, blue: 0.07, alpha: 1))
    for i in 0..<holeCount {
        let x = stripRect.minX + holeSpacing * (CGFloat(i) + 0.5) - holeW / 2
        let topY = stripRect.maxY - railHeight / 2 - holeH / 2
        let botY = stripRect.minY + railHeight / 2 - holeH / 2
        let topRect = CGRect(x: x, y: topY, width: holeW, height: holeH)
        let botRect = CGRect(x: x, y: botY, width: holeW, height: holeH)
        ctx.addPath(CGPath(roundedRect: topRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.addPath(CGPath(roundedRect: botRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
    }

    // Inner-frame separators between sprocket holes (thin vertical lines on the
    // dark middle area of the strip) — sells the "frames" idea.
    let frameInsetY = railHeight + 14
    ctx.setStrokeColor(CGColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1))
    ctx.setLineWidth(4)
    for i in 1..<holeCount {
        let x = stripRect.minX + holeSpacing * CGFloat(i)
        ctx.move(to: CGPoint(x: x, y: stripRect.minY + frameInsetY))
        ctx.addLine(to: CGPoint(x: x, y: stripRect.maxY - frameInsetY))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // ---- Soccer ball ----
    let ballCenter = CGPoint(x: canvas / 2, y: canvas * 0.56)
    let ballRadius: CGFloat = 290

    // Soft drop shadow under the ball.
    ctx.saveGState()
    let shadowEllipse = CGRect(x: ballCenter.x - ballRadius * 0.95,
                               y: ballCenter.y - ballRadius - 30,
                               width: ballRadius * 1.9,
                               height: 50)
    let shadowGrad = CGGradient(colorsSpace: colorSpace,
                                colors: [
                                    CGColor(red: 0, green: 0, blue: 0, alpha: 0.55),
                                    CGColor(red: 0, green: 0, blue: 0, alpha: 0)
                                ] as CFArray,
                                locations: [0, 1])!
    ctx.addEllipse(in: shadowEllipse)
    ctx.clip()
    ctx.drawRadialGradient(shadowGrad,
                           startCenter: CGPoint(x: shadowEllipse.midX, y: shadowEllipse.midY),
                           startRadius: 0,
                           endCenter: CGPoint(x: shadowEllipse.midX, y: shadowEllipse.midY),
                           endRadius: shadowEllipse.width / 2,
                           options: [])
    ctx.restoreGState()

    // White ball body.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: ballCenter.x - ballRadius,
                              y: ballCenter.y - ballRadius,
                              width: ballRadius * 2,
                              height: ballRadius * 2))
    ctx.clip()

    // Cream/white base gradient for subtle depth.
    let ballGrad = CGGradient(colorsSpace: colorSpace,
                              colors: [
                                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                                CGColor(red: 0.82, green: 0.85, blue: 0.86, alpha: 1)
                              ] as CFArray,
                              locations: [0, 1])!
    ctx.drawRadialGradient(ballGrad,
                           startCenter: CGPoint(x: ballCenter.x - ballRadius * 0.3,
                                                y: ballCenter.y + ballRadius * 0.3),
                           startRadius: 0,
                           endCenter: ballCenter,
                           endRadius: ballRadius * 1.1,
                           options: [])

    // Black pentagons in the classic Telstar pattern.
    // Central pentagon + 5 surrounding pentagons.
    ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1))

    // Center pentagon
    let centerPenta = regularPolygon(center: ballCenter,
                                     radius: ballRadius * 0.28,
                                     sides: 5,
                                     rotation: 0)
    ctx.addPath(centerPenta)
    ctx.fillPath()

    // 5 surrounding pentagons. Each one sits along an edge of the center
    // pentagon, oriented so its "point" faces away from the center.
    let outerDist = ballRadius * 0.72
    for i in 0..<5 {
        let angle = CGFloat(i) * (2 * .pi / 5) + .pi / 2     // top, then around
        let cx = ballCenter.x + outerDist * cos(angle)
        let cy = ballCenter.y + outerDist * sin(angle)
        // Rotate so a vertex points outward (away from ball center).
        let rotation = angle + .pi / 2
        let penta = regularPolygon(center: CGPoint(x: cx, y: cy),
                                   radius: ballRadius * 0.27,
                                   sides: 5,
                                   rotation: rotation)
        ctx.addPath(penta)
        ctx.fillPath()
    }

    ctx.restoreGState()

    // Crisp ball outline.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1))
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: CGRect(x: ballCenter.x - ballRadius,
                                 y: ballCenter.y - ballRadius,
                                 width: ballRadius * 2,
                                 height: ballRadius * 2))
    ctx.restoreGState()

    // Final highlight gloss on upper-left of ball.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: ballCenter.x - ballRadius,
                              y: ballCenter.y - ballRadius,
                              width: ballRadius * 2,
                              height: ballRadius * 2))
    ctx.clip()
    let gloss = CGGradient(colorsSpace: colorSpace,
                           colors: [
                            CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
                            CGColor(red: 1, green: 1, blue: 1, alpha: 0)
                           ] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(gloss,
                           startCenter: CGPoint(x: ballCenter.x - ballRadius * 0.35,
                                                y: ballCenter.y + ballRadius * 0.45),
                           startRadius: 0,
                           endCenter: CGPoint(x: ballCenter.x - ballRadius * 0.35,
                                              y: ballCenter.y + ballRadius * 0.45),
                           endRadius: ballRadius * 0.7,
                           options: [])
    ctx.restoreGState()
}

// MARK: - Bitmap rendering

func renderPNG(size: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    let scale = CGFloat(size) / canvas
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(into: ctx)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try png.write(to: url)
}

// MARK: - Entry point

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let appleDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconset = appleDir.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct IconEntry {
    let size: Int          // points
    let scale: Int         // 1 or 2
    var pixels: Int { size * scale }
    var filename: String { "icon_\(size)x\(size)@\(scale)x.png" }
}

let entries: [IconEntry] = [
    .init(size: 16,  scale: 1),
    .init(size: 16,  scale: 2),
    .init(size: 32,  scale: 1),
    .init(size: 32,  scale: 2),
    .init(size: 128, scale: 1),
    .init(size: 128, scale: 2),
    .init(size: 256, scale: 1),
    .init(size: 256, scale: 2),
    .init(size: 512, scale: 1),
    .init(size: 512, scale: 2),
]

// Render unique pixel sizes once, write copies for each entry (some pixel
// sizes are referenced by two entries — e.g. 32px is "16@2x" and "32@1x").
var rendered: [Int: URL] = [:]
for entry in entries {
    if rendered[entry.pixels] == nil {
        let tmp = iconset.appendingPathComponent("_\(entry.pixels).png")
        try renderPNG(size: entry.pixels, to: tmp)
        rendered[entry.pixels] = tmp
    }
    let dst = iconset.appendingPathComponent(entry.filename)
    try? FileManager.default.removeItem(at: dst)
    try FileManager.default.copyItem(at: rendered[entry.pixels]!, to: dst)
}
for (_, tmpURL) in rendered {
    try? FileManager.default.removeItem(at: tmpURL)
}

// Contents.json for AppIcon.appiconset
struct ImageEntry: Codable {
    let size: String
    let idiom: String
    let filename: String
    let scale: String
}
struct Contents: Codable {
    let images: [ImageEntry]
    let info: [String: String]
}
let images = entries.map {
    ImageEntry(size: "\($0.size)x\($0.size)",
               idiom: "mac",
               filename: $0.filename,
               scale: "\($0.scale)x")
}
let contents = Contents(images: images, info: ["version": "1", "author": "xcode"])
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let json = try encoder.encode(contents)
try json.write(to: iconset.appendingPathComponent("Contents.json"))

// Contents.json for the Assets.xcassets root.
let assetsRoot = appleDir.appendingPathComponent("App/Assets.xcassets/Contents.json")
let rootJSON = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try rootJSON.write(to: assetsRoot, atomically: true, encoding: .utf8)

print("Wrote \(entries.count) icon files to \(iconset.path)")

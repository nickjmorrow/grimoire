#!/usr/bin/env swift
// Draws the Grimoire app icon: a sunshine-yellow crescent moon on flat midnight navy.
// Usage: swift tools/make-icon.swift <out.png> [mac|ios]
//   mac: a 824pt squircle centred on the 1024 canvas (macOS draws no mask of its own)
//   ios: a full-bleed square (iOS applies its own mask)
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let size = 1024
let mac = !(CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "ios")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let tile = mac ? NSRect(x: 100, y: 100, width: 824, height: 824) : NSRect(x: 0, y: 0, width: 1024, height: 1024)
if mac {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    color(0x0b1120).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186).fill()
    ctx.restoreGState()
} else {
    color(0x0b1120).setFill(); tile.fill()
}

// the moon: a disc with an offset circle cut out
let centre = NSPoint(x: tile.midX - 6, y: tile.midY)
let r: CGFloat = tile.width * 0.30
let disc = NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
ctx.saveGState()
let cut = CGMutablePath()
cut.addRect(CGRect(x: 0, y: 0, width: size, height: size))
let cr = r * 0.86
cut.addEllipse(in: CGRect(x: centre.x - cr + r * 0.52, y: centre.y - cr + r * 0.30, width: 2 * cr, height: 2 * cr))
ctx.addPath(cut); ctx.clip(using: .evenOdd)
NSGradient(colors: [color(0xffe08a), color(0xffcc33)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: disc, angle: -45)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")

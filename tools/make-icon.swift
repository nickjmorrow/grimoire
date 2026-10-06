#!/usr/bin/env swift
// Draws the Grimoire app icons: a six-fold magic diagram in sunshine yellow on midnight navy, with a different
// sigil at its centre for each time of day (dawn, day, dusk, night).
//
// Usage:
//   swift tools/make-icon.swift <out.png> [mac|ios] [dawn|day|dusk|night] [pixels]
//   swift tools/make-icon.swift --all      regenerate every asset catalog under App/
//
//   mac: an 824pt squircle centred on the 1024 canvas with a drop shadow (macOS draws no mask of its own)
//   ios: a full-bleed square (iOS applies its own mask)
//
// The artwork is drawn in the same 1024 units as tools/icon-explorations/index.html, which is the place to preview changes.
import AppKit

enum Variant: String, CaseIterable { case dawn, day, dusk, night }

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let navy = color(0x0b1120), goldLight = color(0xffd957), gold = color(0xffcc33)

/// SVG-style polar point: 0 degrees is up, clockwise, y grows downward.
func pt(_ r: CGFloat, _ deg: CGFloat, _ c: CGPoint) -> CGPoint {
    let a = deg * .pi / 180
    return CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
}

func render(variant: Variant, mac: Bool, pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true); ctx.interpolationQuality = .high

    // work in a 1024-unit canvas with y pointing down, as the SVG previews do
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)

    let tile = mac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let tilePath = mac ? CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil) : CGPath(rect: tile, transform: nil)
    if mac {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(navy.cgColor); ctx.addPath(tilePath); ctx.fillPath()
        ctx.restoreGState()
    } else {
        ctx.setFillColor(navy.cgColor); ctx.fill(tile)
    }

    // from here on, draw in the 1024-unit artwork space, which fills the tile
    let space = mac ? 824.0 / 1024.0 : 1.0
    ctx.translateBy(x: tile.minX, y: tile.minY); ctx.scaleBy(x: space, y: space)

    let space2 = CGColorSpace(name: CGColorSpace.sRGB)!
    let goldGradient = CGGradient(colorsSpace: space2, colors: [goldLight.cgColor, gold.cgColor] as CFArray, locations: [0, 1])!
    // a faint gold glow on the ground; gold at low opacity keeps the palette to navy and gold
    let glow = CGGradient(colorsSpace: space2, colors: [gold.withAlphaComponent(0.045).cgColor, gold.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil)); ctx.clip()
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 400), startRadius: 0, endCenter: CGPoint(x: 512, y: 400), endRadius: 640, options: [])
    ctx.restoreGState()

    // fills a path with the diagonal gold gradient (userSpaceOnUse, so thin straight strokes never lose their gradient)
    func fillGold(_ path: CGPath) {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(goldGradient, start: CGPoint(x: 200, y: 200), end: CGPoint(x: 824, y: 824), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    func stroked(_ path: CGPath, _ w: CGFloat) -> CGPath { path.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10) }
    func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
    func ring(_ c: CGPoint, _ r: CGFloat, _ w: CGFloat) { fillGold(stroked(circle(c, r), w)) }
    func line(_ p: CGPoint, _ q: CGPoint, _ w: CGFloat) {
        let path = CGMutablePath(); path.move(to: p); path.addLine(to: q); fillGold(stroked(path, w))
    }
    func dot(_ c: CGPoint, _ r: CGFloat) { fillGold(circle(c, r)) }
    func holeDot(_ c: CGPoint, _ r: CGFloat) { ctx.setFillColor(navy.cgColor); ctx.addPath(circle(c, r)); ctx.fillPath() }
    /// four-point sparkle with concave sides
    func sparkle(_ c: CGPoint, _ R: CGFloat) {
        let p = 0.2 * R, path = CGMutablePath()
        path.move(to: CGPoint(x: c.x, y: c.y - R))
        path.addQuadCurve(to: CGPoint(x: c.x + R, y: c.y), control: CGPoint(x: c.x + p, y: c.y - p))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + R), control: CGPoint(x: c.x + p, y: c.y + p))
        path.addQuadCurve(to: CGPoint(x: c.x - R, y: c.y), control: CGPoint(x: c.x - p, y: c.y + p))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - R), control: CGPoint(x: c.x - p, y: c.y - p))
        path.closeSubpath(); fillGold(path)
    }
    /// a hollow node: a navy halo, a gold disc and a navy hole, so it sits cleanly on a ring
    func hollow(_ c: CGPoint, _ k: CGFloat, _ r: CGFloat = 44) { holeDot(c, (r + 18) * k); dot(c, r * k); holeDot(c, (r - 26) * k) }
    /// a disc with an offset disc cut out, the horns opening toward `dir` degrees
    func crescent(_ c: CGPoint, _ r: CGFloat, dir: CGFloat) {
        let o = pt(r * 0.58, dir, .zero), cut = circle(CGPoint(x: c.x + o.x, y: c.y + o.y), r * 0.86)
        ctx.saveGState()
        let clip = CGMutablePath(); clip.addRect(CGRect(x: -50, y: -50, width: 1124, height: 1124)); clip.addPath(cut)
        ctx.addPath(clip); ctx.clip(using: .evenOdd)
        fillGold(circle(c, r))
        ctx.restoreGState()
    }

    // the diagram: a double outer ring, six hollow nodes, three spokes to an inner ring, three small nodes between them
    let k: CGFloat = 1.02, c = CGPoint(x: 512, y: 512)
    let R = 340 * k, r2 = 176 * k
    ring(c, R, 22 * k); ring(c, R - 46 * k, 12 * k); ring(c, r2, 18 * k)
    for a: CGFloat in [0, 120, 240] { line(pt(r2, a, c), pt(R, a, c), 18 * k) }
    for a: CGFloat in [60, 180, 300] { dot(pt(r2, a, c), 24 * k) }
    for a: CGFloat in [0, 60, 120, 180, 240, 300] { hollow(pt(R, a, c), k) }

    switch variant {
    case .day:
        dot(c, 58 * k)
        for i in 0..<12 { line(pt(86 * k, CGFloat(i) * 30, c), pt((i % 2 == 1 ? 108 : 124) * k, CGFloat(i) * 30, c), 16 * k) }
    case .dawn, .dusk:
        let dawn = variant == .dawn
        let hy = c.y + (dawn ? 40 : 46) * k, r = 62 * k, dip = dawn ? 0 : 30 * k
        let sun = CGPoint(x: c.x, y: hy + dip), t0 = asin(dip / r)
        // visible part of the sun disc above the horizon
        let half = CGMutablePath()
        let steps = 64
        for i in 0...steps {
            let t = (.pi - t0) + (t0 - (.pi - t0)) * CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: sun.x + r * cos(t), y: sun.y - r * sin(t))
            if i == 0 { half.move(to: p) } else { half.addLine(to: p) }
        }
        half.closeSubpath(); fillGold(half)
        let angles: [CGFloat] = dawn ? [-75, -50, -25, 0, 25, 50, 75] : [-60, -30, 0, 30, 60]
        for (i, a) in angles.enumerated() {
            let e: CGFloat = dawn ? (i % 2 == 1 ? 108 : 124) : (i % 2 == 1 ? 100 : 118)
            line(pt(86 * k, a, sun), pt(e * k, a, sun), 16 * k)
        }
        line(CGPoint(x: c.x - 124 * k, y: hy), CGPoint(x: c.x + 124 * k, y: hy), 16 * k)
        if dawn {
            line(CGPoint(x: c.x - 66 * k, y: hy + 36 * k), CGPoint(x: c.x + 66 * k, y: hy + 36 * k), 14 * k)
        } else {
            line(CGPoint(x: c.x - 92 * k, y: hy + 34 * k), CGPoint(x: c.x + 92 * k, y: hy + 34 * k), 14 * k)
            line(CGPoint(x: c.x - 48 * k, y: hy + 64 * k), CGPoint(x: c.x + 48 * k, y: hy + 64 * k), 14 * k)
            sparkle(CGPoint(x: c.x - 80 * k, y: c.y - 76 * k), 26 * k)
        }
    case .night:
        crescent(c, 104 * k, dir: 45)
        sparkle(CGPoint(x: c.x + 58 * k, y: c.y - 58 * k), 28 * k)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func imageSetContents(filename: String, platform: String?) -> String {
    let platformKey = platform.map { ", \"platform\": \"\($0)\"" } ?? ""
    return "{ \"images\": [ { \"filename\": \"\(filename)\", \"idiom\": \"universal\"\(platformKey), \"size\": \"1024x1024\" } ], \"info\": { \"author\": \"xcode\", \"version\": 1 } }\n"
}

/// Regenerates every asset catalog entry the apps use. Night is the primary icon (what Finder, Launchpad and a fresh install show);
/// the other three are iOS alternate icons and Mac images the running app swaps in.
func regenerateAll() {
    let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    let ios = root.appendingPathComponent("App/iOS/Assets.xcassets"), macCat = root.appendingPathComponent("App/Mac/Assets.xcassets")
    let iosNames: [Variant: String] = [.night: "AppIcon", .dawn: "AppIconDawn", .day: "AppIconDay", .dusk: "AppIconDusk"]
    let macNames: [Variant: String] = [.night: "IconNight", .dawn: "IconDawn", .day: "IconDay", .dusk: "IconDusk"]
    for v in Variant.allCases {
        let dir = ios.appendingPathComponent("\(iosNames[v]!).appiconset")
        write(render(variant: v, mac: false, pixels: 1024), to: dir.appendingPathComponent("icon-1024.png"))
        try! imageSetContents(filename: "icon-1024.png", platform: "ios").write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

        let image = macCat.appendingPathComponent("\(macNames[v]!).imageset")
        write(render(variant: v, mac: true, pixels: 1024), to: image.appendingPathComponent("icon-1024.png"))
        try! imageSetContents(filename: "icon-1024.png", platform: nil).write(to: image.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    }
    // the Mac app icon proper (night): 16 to 512 at 1x and 2x, each drawn at its own pixel size so small ones stay crisp
    let appIcon = macCat.appendingPathComponent("AppIcon.appiconset")
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] { write(render(variant: .night, mac: true, pixels: base * scale), to: appIcon.appendingPathComponent("icon-\(base)@\(scale)x.png")) }
    }
    print("regenerated icons under \(root.appendingPathComponent("App").path)")
}

let args = CommandLine.arguments
if args.count > 1 && args[1] == "--all" {
    regenerateAll()
} else {
    let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "icon.png")
    let mac = !(args.count > 2 && args[2] == "ios")
    let variant = args.count > 3 ? (Variant(rawValue: args[3]) ?? .night) : .night
    let pixels = args.count > 4 ? (Int(args[4]) ?? 1024) : 1024
    write(render(variant: variant, mac: mac, pixels: pixels), to: out)
    print("wrote \(out.path)")
}

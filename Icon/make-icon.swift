// Generates both app icons from one shared geometry:
//   • Icon/AppIcon.icon               – Liquid Glass icon (Icon Composer format) for macOS 26+
//   • Icon/Assets.xcassets/AppIcon…   – classic icon for macOS 14/15 (Sonoma, Sequoia)
//   • Icon/Previews/classic-1024.png  – preview of the classic icon
// Run: swift Icon/make-icon.swift
//
// Design: a black vinyl record with a white label, embraced by a two-arrow sync ring,
// on an indigo tile. One metaphor, two colours, no decoration.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon")
let fm = FileManager.default
let rad = CGFloat.pi / 180

// MARK: Shared geometry (1024 × 1024 canvas, y-up) --------------------------------

let center = CGPoint(x: 512, y: 512)
let recordR: CGFloat = 232
let labelR: CGFloat = 84
let holeR: CGFloat = 11
let ringR: CGFloat = 318
let ringWidth: CGFloat = 40

/// One sync arrow: a ring segment from a0 to a1 (degrees, counter-clockwise) with a head at a1.
func arrowPath(from a0: CGFloat, to a1: CGFloat) -> CGPath {
    let arc = CGMutablePath()
    arc.addArc(center: center, radius: ringR, startAngle: a0 * rad, endAngle: a1 * rad, clockwise: false)
    let body = arc.copy(strokingWithWidth: ringWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let th = a1 * rad
    let p = CGPoint(x: center.x + cos(th) * ringR, y: center.y + sin(th) * ringR)
    let t = CGPoint(x: -sin(th), y: cos(th)), n = CGPoint(x: cos(th), y: sin(th))
    let head = CGMutablePath()
    head.move(to: CGPoint(x: p.x + t.x * 58, y: p.y + t.y * 58))
    head.addLine(to: CGPoint(x: p.x + n.x * 50 - t.x * 4, y: p.y + n.y * 50 - t.y * 4))
    head.addLine(to: CGPoint(x: p.x - n.x * 50 - t.x * 4, y: p.y - n.y * 50 - t.y * 4))
    head.closeSubpath()
    return body.union(head)
}
let arrows: CGPath = {
    let p = CGMutablePath()
    p.addPath(arrowPath(from: 118, to: 232))
    p.addPath(arrowPath(from: 298, to: 412))
    return p
}()

func circle(_ r: CGFloat) -> CGRect { CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r) }

// MARK: Classic icon (macOS 14/15) --------------------------------------------------

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ c: [CGColor], _ l: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: c as CFArray, locations: l)!
}

func renderClassic() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext

    // Tile on Apple's macOS grid: 824 pt rounded square, centred, with the standard drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.30))
    cg.addPath(tilePath); cg.setFillColor(color(0x4A3FE0)); cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(tilePath); cg.clip()
    cg.drawLinearGradient(gradient([color(0x7468FF), color(0x3B2FC9)], [0, 1]),
                          start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // top light
    cg.drawRadialGradient(gradient([color(0xFFFFFF, 0.20), color(0xFFFFFF, 0)], [0, 1]),
                          startCenter: CGPoint(x: 512, y: 960), startRadius: 0,
                          endCenter: CGPoint(x: 512, y: 960), endRadius: 620, options: [])
    cg.restoreGState()

    // Record
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x0C0640, 0.55))
    cg.addEllipse(in: circle(recordR)); cg.setFillColor(color(0x101014)); cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addEllipse(in: circle(recordR)); cg.clip()
    cg.drawRadialGradient(gradient([color(0x26262C), color(0x0B0B0E)], [0, 1]),
                          startCenter: center, startRadius: labelR, endCenter: center, endRadius: recordR, options: [])
    cg.setLineWidth(1.5)
    var r = labelR + 14
    while r < recordR - 8 {
        cg.setStrokeColor(color(0xFFFFFF, 0.055))
        cg.strokeEllipse(in: circle(r))
        r += 7
    }
    // track gaps
    cg.setLineWidth(3)
    for g in [CGFloat(150), 196] {
        cg.setStrokeColor(color(0x000000, 0.55)); cg.strokeEllipse(in: circle(g))
    }
    // two soft reflections
    for a in [CGFloat(48), 228] {
        cg.saveGState()
        let w = CGMutablePath()
        w.move(to: center)
        w.addArc(center: center, radius: recordR, startAngle: (a - 16) * rad, endAngle: (a + 16) * rad, clockwise: false)
        w.closeSubpath()
        cg.addPath(w); cg.clip()
        cg.drawRadialGradient(gradient([color(0xFFFFFF, 0), color(0xFFFFFF, 0.13), color(0xFFFFFF, 0.02)], [0, 0.7, 1]),
                              startCenter: center, startRadius: labelR, endCenter: center, endRadius: recordR, options: [])
        cg.restoreGState()
    }
    cg.restoreGState()
    cg.setLineWidth(2); cg.setStrokeColor(color(0xFFFFFF, 0.16))
    cg.strokeEllipse(in: circle(recordR - 1))

    // Label
    cg.saveGState()
    cg.addEllipse(in: circle(labelR)); cg.clip()
    cg.drawLinearGradient(gradient([color(0xFFFFFF), color(0xE4E2F5)], [0, 1]),
                          start: CGPoint(x: 512, y: center.y + labelR), end: CGPoint(x: 512, y: center.y - labelR), options: [])
    cg.setLineWidth(2); cg.setStrokeColor(color(0x3B2FC9, 0.18)); cg.strokeEllipse(in: circle(labelR - 18))
    cg.restoreGState()
    cg.addEllipse(in: circle(holeR)); cg.setFillColor(color(0x1B1640)); cg.fillPath()

    // Sync arrows
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x0C0640, 0.40))
    cg.addPath(arrows); cg.setFillColor(color(0xFFFFFF)); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(arrows); cg.clip()
    cg.drawLinearGradient(gradient([color(0xFFFFFF), color(0xE9E7FB)], [0, 1]),
                          start: CGPoint(x: 512, y: 860), end: CGPoint(x: 512, y: 160), options: [])
    cg.restoreGState()

    // Fine edge light on the tile
    cg.saveGState()
    cg.addPath(tilePath); cg.clip()
    cg.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
    cg.setLineWidth(2); cg.setStrokeColor(color(0xFFFFFF, 0.22)); cg.strokePath()
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func run(_ args: String...) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
    p.standardOutput = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    precondition(p.terminationStatus == 0, "\(args) failed")
}

let previews = root.appendingPathComponent("Previews")
try! fm.createDirectory(at: previews, withIntermediateDirectories: true)
let classicPNG = previews.appendingPathComponent("classic-1024.png")
try! renderClassic().representation(using: .png, properties: [:])!.write(to: classicPNG)

// Asset catalog with the classic app icon (used by macOS 14/15)
let xcassets = root.appendingPathComponent("Assets.xcassets")
let appiconset = xcassets.appendingPathComponent("AppIcon.appiconset")
try? fm.removeItem(at: xcassets)
try! fm.createDirectory(at: appiconset, withIntermediateDirectories: true)
try! #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(to: xcassets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        run("/usr/bin/sips", "-z", "\(base * scale)", "\(base * scale)", classicPNG.path, "--out", appiconset.appendingPathComponent(name).path)
        images.append(#"{ "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(base)x\#(base)" }"#)
    }
}
try! """
{
  "images" : [
    \(images.joined(separator: ",\n    "))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: appiconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// MARK: Liquid Glass icon (macOS 26+) ---------------------------------------------
// Flat, single-colour layers; the system adds glass, depth, specular light and the
// dark / clear / tinted variants itself.

func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func p(_ pt: CGPoint) -> String { String(format: "%.2f %.2f", pt.x, 1024 - pt.y) }
    path.applyWithBlock { e in
        let pts = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(p(pts[0])) "
        case .addLineToPoint: d += "L\(p(pts[0])) "
        case .addQuadCurveToPoint: d += "Q\(p(pts[0])) \(p(pts[1])) "
        case .addCurveToPoint: d += "C\(p(pts[0])) \(p(pts[1])) \(p(pts[2])) "
        case .closeSubpath: d += "Z "
        @unknown default: break
        }
    }
    return d
}
func svg(_ body: String) -> String {
    #"<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">"# + body + "</svg>\n"
}
func ringPath(_ r: CGFloat, width w: CGFloat) -> CGPath {
    let p = CGMutablePath(); p.addEllipse(in: circle(r))
    return p.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
}

let iconDir = root.appendingPathComponent("AppIcon.icon")
let assets = iconDir.appendingPathComponent("Assets")
try? fm.removeItem(at: iconDir)
try! fm.createDirectory(at: assets, withIntermediateDirectories: true)

// record: dark disc with a few subtle grooves
var record = ##"<circle cx="512" cy="512" r="\##(recordR)" fill="#16161A"/>"##
for g in [CGFloat(122), 150, 178, 206] {
    record += ##"<path fill="#2C2C33" fill-rule="evenodd" d="\##(svgPathData(ringPath(g, width: 4)))"/>"##
}
try! svg(record).write(to: assets.appendingPathComponent("record.svg"), atomically: true, encoding: .utf8)

// label: white disc with the spindle hole
let label = CGMutablePath()
label.addEllipse(in: circle(labelR)); label.addEllipse(in: circle(holeR))
try! svg(##"<path fill="#FFFFFF" fill-rule="evenodd" d="\##(svgPathData(label))"/>"##)
    .write(to: assets.appendingPathComponent("label.svg"), atomically: true, encoding: .utf8)

// arrows
try! svg(##"<path fill="#FFFFFF" d="\##(svgPathData(arrows))"/>"##)
    .write(to: assets.appendingPathComponent("arrows.svg"), atomically: true, encoding: .utf8)

try! """
{
  "fill" : {
    "automatic-gradient" : "extended-srgb:0.38431,0.33333,0.96078,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        { "glass" : true, "image-name" : "arrows.svg", "name" : "arrows" }
      ],
      "name" : "Sync",
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.4 }
    },
    {
      "layers" : [
        { "glass" : true, "image-name" : "label.svg", "name" : "label" },
        { "glass" : false, "image-name" : "record.svg", "name" : "record" }
      ],
      "name" : "Record",
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}
""".write(to: iconDir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)

print("Wrote \(iconDir.path), \(appiconset.path) and \(classicPNG.path)")

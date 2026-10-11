// Renders Ultstat's app icon ("Pulse Cell") with Core Graphics.
//   swift tools/make-icon.swift <output-dir>
// Writes icon_1024.png (full-bleed; macOS applies the squircle mask) plus every AppIcon size.
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    let space = CGColorSpace(name: CGColorSpace.displayP3)!

    // Field: graphite with a faint cool top-light.
    let bg = CGGradient(colorsSpace: space, colors: [color(0x1B2130), color(0x0B0E15)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0x2EF2C2, 0.22), color(0x2EF2C2, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 470), endRadius: 470, options: [])

    // Cell geometry.
    let body = CGRect(x: 322, y: 178, width: 380, height: 600)
    let radius: CGFloat = 92
    let cap = CGRect(x: 446, y: body.maxY + 22, width: 132, height: 58)
    let stroke: CGFloat = 30
    let inner = body.insetBy(dx: stroke + 16, dy: stroke + 16)
    let innerRadius = radius - stroke - 12

    // The charge surface is a sparkline: a live data contour peaking just under the 80 % limit.
    let limitY = inner.minY + inner.height * 0.80
    // Hovering just under the limit, the way a held battery (and a busy CPU graph) looks.
    let samples: [CGFloat] = [0.66, 0.73, 0.62, 0.70, 0.64, 0.77, 0.68, 0.74, 0.70, 0.76]
    let surface: [CGPoint] = samples.enumerated().map { i, v in
        CGPoint(x: inner.minX + inner.width * CGFloat(i) / CGFloat(samples.count - 1), y: inner.minY + inner.height * v)
    }
    let fillPath = CGMutablePath()
    fillPath.move(to: CGPoint(x: inner.minX, y: inner.minY))
    for p in surface { fillPath.addLine(to: p) }   // addLines(between:) would start a new subpath
    fillPath.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
    fillPath.closeSubpath()

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
    ctx.clip()
    ctx.addPath(fillPath)
    ctx.clip()
    let fill = CGGradient(colorsSpace: space, colors: [color(0x0FB5E6), color(0x2EF2C2), color(0xB8FF7A)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: inner.minY), end: CGPoint(x: 0, y: limitY), options: [.drawsAfterEndLocation])
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.30), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: inner.minX, y: 0), end: CGPoint(x: inner.minX + inner.width * 0.5, y: 0), options: [])
    ctx.restoreGState()

    // Bright edge along the data surface, clipped to the cell interior.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
    ctx.clip()
    let edge = CGMutablePath()
    edge.addLines(between: surface)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.setShadow(offset: .zero, blur: 28, color: color(0xB8FF7A, 0.9))
    ctx.setStrokeColor(color(0xF4FFF0))
    ctx.setLineWidth(12)
    ctx.addPath(edge)
    ctx.strokePath()
    ctx.restoreGState()

    // Newest sample: a glowing dot at the right end of the contour.
    let last = surface.last!
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36, color: color(0xB8FF7A, 1))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: last.x - 22, y: last.y - 22, width: 44, height: 44))
    ctx.restoreGState()

    // Charge limit: dashed line across the interior, ticks outside the cell.
    ctx.saveGState()
    ctx.setStrokeColor(color(0xFFFFFF, 0.55))
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [2, 22])
    ctx.move(to: CGPoint(x: inner.minX + 10, y: limitY))
    ctx.addLine(to: CGPoint(x: inner.maxX - 10, y: limitY))
    ctx.strokePath()
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFFFFF, 0.92))
    ctx.setLineWidth(12)
    ctx.setLineCap(.round)
    for (a, b) in [(body.minX - 44, body.minX - 8), (body.maxX + 8, body.maxX + 44)] {
        ctx.move(to: CGPoint(x: a, y: limitY))
        ctx.addLine(to: CGPoint(x: b, y: limitY))
    }
    ctx.strokePath()

    // Cell outline and cap.
    ctx.setStrokeColor(color(0xE9EEF7))
    ctx.setLineWidth(stroke)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()
    ctx.setFillColor(color(0xE9EEF7))
    ctx.addPath(CGPath(roundedRect: cap, cornerWidth: 24, cornerHeight: 24, transform: nil))
    ctx.fillPath()
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

write(render(size: 1024), "icon_1024.png")

// Asset catalog sizes (points @ scale).
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        write(render(size: px), name)
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count + 1) images to \(out.path)")

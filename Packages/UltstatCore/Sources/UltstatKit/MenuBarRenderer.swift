import AppKit
import UltstatCore

/// Formats readings into compact menu-bar strings. Pure functions, unit-testable.
public enum MetricFormat {
    public static func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

    /// Bytes/s → "0K", "12K", "1.2M", "34M", "1.1G". At most four characters so widths stay stable.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        switch v {
        case ..<1_000: return "0K"
        case ..<999_500: return "\(Int((v / 1_000).rounded()))K"
        case ..<9_950_000: return String(format: "%.1fM", v / 1_000_000)
        case ..<999_500_000: return "\(Int((v / 1_000_000).rounded()))M"
        default: return String(format: "%.1fG", v / 1_000_000_000)
        }
    }

    public static func watts(_ w: Double) -> String { w < 9.95 ? String(format: "%.1fW", w) : "\(Int(w.rounded()))W" }
}

/// One drawable segment of the status item.
public struct Segment: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case text(String)
        case stacked(top: String, bottom: String)
        case bar(Float)
        /// Recent history, 0...1, oldest first.
        case sparkline([Float])
        /// Small caption over a bold value ("CPU" over "7%").
        case labeled(caption: String, value: String)
        /// Battery glyph with the percentage knocked out of the fill, then time remaining.
        case battery(percent: Int, charging: Bool, time: String, pluggedIn: Bool = false)
    }

    public var symbol: String?
    /// Plain-text name drawn before the value ("CPU 8%"), instead of a symbol.
    public var name: String?
    public var content: Content
    /// Widest string this segment can show; fixes its width so the item never resizes.
    public var slot: String = ""

    public init(symbol: String?, name: String? = nil, content: Content, slot: String = "") {
        self.symbol = symbol
        self.name = name
        self.content = content
        self.slot = slot
    }
}

/// Renders segments into a template image sized for the menu bar.
///
/// Cost control (measured: the first version spent ~6 ms/s here):
/// - symbol images and text attributes are cached, never looked up per render;
/// - the result is rasterised once into a 2× bitmap, so AppKit never re-runs layout to get pixels;
/// - every segment occupies a fixed-width slot sized for its widest possible value, so the status
///   item's width never changes and the menu bar never has to relayout.
@MainActor
public enum MenuBarRenderer {
    public static let height: CGFloat = 22
    private static let spacing: CGFloat = 8
    private static let iconGap: CGFloat = 3

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    private static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    private static let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    private static let smallAttrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.black]
    private static let captionAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .foregroundColor: NSColor.black, .kern: 0.2,
    ]
    private static let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black,
    ]
    private static let batteryNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
    private static let batteryBody = NSSize(width: 27, height: 13)
    private static var symbols: [String: NSImage] = [:]
    private static var slotWidths: [String: CGFloat] = [:]

    /// Points kept for a menu-bar sparkline (one per tick).
    public static let sparklinePoints = 24
    private static let sparklineWidth: CGFloat = 28

    public static func segments(for items: [MenuBarItem], readings r: Readings, settings: AppSettings.Stored,
                                histories: [MenuBarItem: [Float]] = [:]) -> [Segment] {
        items.compactMap { item -> Segment? in
            guard var seg = segment(item, readings: r, settings: settings, histories: histories) else { return nil }
            switch seg.content {
            case .labeled, .battery: break   // already captioned / self-explanatory
            default: if settings.itemLabel == .name { seg.name = item.shortName }
            }
            return seg
        }
    }

    private static func segment(_ item: MenuBarItem, readings r: Readings, settings: AppSettings.Stored,
                                histories: [MenuBarItem: [Float]]) -> Segment? {
        do {
            let icon = settings.itemLabel == .icon ? item.symbol : nil
            let style = settings.styles[item] ?? .text
            switch item {
            case .cpu:
                guard let c = r.cpu else { return Segment(symbol: icon, content: .text("–"), slot: style == .bar ? "" : "88%") }
                if style == .sparkline { return Segment(symbol: icon, content: .sparkline(histories[.cpu] ?? [c.total])) }
                if style == .labeled { return Segment(symbol: nil, content: .labeled(caption: "CPU", value: MetricFormat.percent(c.total)), slot: "88%") }
                return Segment(symbol: icon, content: style == .bar ? .bar(c.total) : .text(MetricFormat.percent(c.total)), slot: "88%")
            case .gpu:
                guard let g = r.gpu else { return nil }
                if style == .sparkline { return Segment(symbol: icon, content: .sparkline(histories[.gpu] ?? [g.utilization])) }
                if style == .labeled { return Segment(symbol: nil, content: .labeled(caption: "GPU", value: MetricFormat.percent(g.utilization)), slot: "88%") }
                return Segment(symbol: icon, content: style == .bar ? .bar(g.utilization) : .text(MetricFormat.percent(g.utilization)), slot: "88%")
            case .memory:
                guard let m = r.memory else { return Segment(symbol: icon, content: .text("–"), slot: style == .bar ? "" : "88%") }
                if style == .sparkline { return Segment(symbol: icon, content: .sparkline(histories[.memory] ?? [m.usedFraction])) }
                if style == .labeled { return Segment(symbol: nil,
                               content: .labeled(caption: "RAM", value: MetricFormat.percent(m.usedFraction)), slot: "88%") }
                return Segment(symbol: icon, content: style == .bar ? .bar(m.usedFraction) : .text(MetricFormat.percent(m.usedFraction)), slot: "88%")
            case .network:
                guard let n = r.network else { return Segment(symbol: nil, content: .stacked(top: "↑ –", bottom: "↓ –"), slot: "↑ 888K") }
                let content = Segment.Content.stacked(top: "↑ " + MetricFormat.rate(n.upload), bottom: "↓ " + MetricFormat.rate(n.download))
                return Segment(symbol: nil, content: content, slot: "↑ 888K")
            case .disk:
                guard let d = r.disk else { return nil }
                let content = Segment.Content.stacked(top: "R " + MetricFormat.rate(d.read), bottom: "W " + MetricFormat.rate(d.write))
                return Segment(symbol: nil, content: content, slot: "W 888K")
            case .temperature:
                let t = r.sensors[.cpuPerformance]?.max ?? r.sensors[.cpuEfficiency]?.max
                if style == .labeled {
                    return Segment(symbol: nil, content: .labeled(caption: "TEMP", value: t.map { settings.temperatureUnit.format($0) } ?? "–"),
                                   slot: "88°")
                }
                return Segment(symbol: icon, content: .text(t.map { settings.temperatureUnit.format($0) } ?? "–"), slot: "88°")
            case .power:
                guard let w = r.systemPower else { return nil }
                if style == .labeled { return Segment(symbol: nil, content: .labeled(caption: "POWER", value: MetricFormat.watts(w)), slot: "8.8W") }
                return Segment(symbol: icon, content: .text(MetricFormat.watts(w)), slot: "88.8W")
            case .battery:
                guard let b = r.battery else { return nil }
                return Segment(symbol: nil, content: .battery(percent: b.percent, charging: b.isCharging, time: BatteryTime.compact(b),
                                                              pluggedIn: b.externalConnected),
                               slot: "8:88")
            }
        }
    }

    public static func batterySymbol(_ b: BatterySnapshot) -> String {
        if b.isCharging { return "battery.100percent.bolt" }
        if b.externalConnected { return "powerplug" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    public static func image(for segments: [Segment], scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) -> NSImage {
        let widths = segments.map(width(of:))
        let total = max(1, widths.reduce(0, +) + spacing * CGFloat(max(0, segments.count - 1)))
        let size = NSSize(width: ceil(total), height: height)
        let image = NSImage(size: size)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            var x: CGFloat = 0
            for (seg, w) in zip(segments, widths) {
                draw(seg, at: x, width: w)
                x += w + spacing
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = segments.map(accessibilityText).joined(separator: ", ")
        return image
    }

    /// Renders the segments as a bitmap already tinted with `tint`, ready to use as layer contents.
    public static func cgImage(for segments: [Segment], scale: CGFloat, tint: CGColor) -> (image: CGImage, size: CGSize)? {
        let mask = image(for: segments, scale: scale)
        guard let rep = mask.representations.first as? NSBitmapImageRep, let cg = rep.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(cg, in: rect)
        ctx.setBlendMode(.sourceAtop)
        ctx.setFillColor(tint)
        ctx.fill(rect)
        guard let out = ctx.makeImage() else { return nil }
        return (out, mask.size)
    }

    // MARK: Drawing

    private static func symbolImage(_ name: String) -> NSImage? {
        if let cached = symbols[name] { return cached }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)
        symbols[name] = img
        return img
    }

    private static func textWidth(_ s: String, small: Bool) -> CGFloat {
        let key = small ? "s:" + s : s
        if let w = slotWidths[key] { return w }
        let w = ceil((s as NSString).size(withAttributes: small ? smallAttrs : textAttrs).width)
        if slotWidths.count < 256 { slotWidths[key] = w }
        return w
    }

    private static func contentWidth(_ seg: Segment) -> CGFloat {
        switch seg.content {
        // Sized to the value itself, so the number sits right next to its icon (a fixed slot left a
        // wide gap after short values like "8%").
        case .text(let t): (t as NSString).size(withAttributes: textAttrs).width
        case .stacked(let a, let b):
            max(textWidth(seg.slot, small: true), (a as NSString).size(withAttributes: smallAttrs).width,
                (b as NSString).size(withAttributes: smallAttrs).width)
        case .bar: 6
        case .sparkline: sparklineWidth
        case .labeled(let caption, let value):
            max(textWidth(caption, attrs: captionAttrs), textWidth(value, attrs: valueAttrs))
        case .battery(_, _, let time, _):
            batteryBody.width + 2.5 + 5 + max(textWidth(seg.slot, attrs: textAttrs), textWidth(time, attrs: textAttrs))
        }
    }

    private static func textWidth(_ s: String, attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((s as NSString).size(withAttributes: attrs).width)
    }

    private static let nameGap: CGFloat = 4

    private static func width(of seg: Segment) -> CGFloat {
        var w = ceil(contentWidth(seg))
        if let n = seg.name { w += textWidth(n, attrs: textAttrs) + nameGap }
        if let s = seg.symbol, let img = symbolImage(s) { w += img.size.width + iconGap }
        return w
    }

    private static func draw(_ seg: Segment, at x0: CGFloat, width: CGFloat) {
        var x = x0
        if let s = seg.symbol, let img = symbolImage(s) {
            let y = (height - img.size.height) / 2
            img.draw(in: NSRect(x: x, y: y, width: img.size.width, height: img.size.height))
            x += img.size.width + iconGap
        }
        if let n = seg.name {
            let size = (n as NSString).size(withAttributes: textAttrs)
            (n as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: textAttrs)
            x += ceil(size.width) + nameGap
        }
        switch seg.content {
        case .text(let t):
            let size = (t as NSString).size(withAttributes: textAttrs)
            (t as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: textAttrs)
        case .stacked(let top, let bottom):
            (top as NSString).draw(at: NSPoint(x: x, y: height / 2 - 0.5), withAttributes: smallAttrs)
            (bottom as NSString).draw(at: NSPoint(x: x, y: 1), withAttributes: smallAttrs)
        case .bar(let v):
            let track = NSRect(x: x, y: 3, width: 6, height: height - 6)
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let fillH = track.height * CGFloat(min(max(v, 0), 1))
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width, height: fillH), xRadius: 2, yRadius: 2).fill()
        case .sparkline(let values):
            drawSparkline(values, in: NSRect(x: x, y: 3, width: sparklineWidth, height: height - 6))
        case .labeled(let caption, let value):
            let vs = (value as NSString).size(withAttributes: valueAttrs)
            let cs = (caption as NSString).size(withAttributes: captionAttrs)
            (caption as NSString).draw(at: NSPoint(x: x, y: height - cs.height + 1), withAttributes: captionAttrs)
            (value as NSString).draw(at: NSPoint(x: x, y: -1.5 + (vs.height < 16 ? 0 : 0)), withAttributes: valueAttrs)
        case .battery(let percent, let charging, let time, _):
            drawBattery(percent: percent, charging: charging, at: NSPoint(x: x, y: (height - batteryBody.height) / 2))
            let tx = x + batteryBody.width + 2.5 + 5
            let ts = (time as NSString).size(withAttributes: textAttrs)
            (time as NSString).draw(at: NSPoint(x: tx, y: (height - ts.height) / 2), withAttributes: textAttrs)
        }
    }

    /// iOS-style battery for the menu bar, in colour: a pill whose fill shows the level (white,
    /// yellow in Low Power Mode, green while charging, red when low), the number inside in dark
    /// text, a translucent remainder and cap, then time remaining in the menu-bar text colour.
    public static func coloredBattery(percent: Int, charging: Bool, lowPower: Bool, time: String, textColor: CGColor,
                                      scale: CGFloat, pluggedIn: Bool = false) -> (image: CGImage, size: CGSize)? {
        // Sized like the system battery icon.
        let bodySize = NSSize(width: 26.5, height: 13)
        // No estimate (on the adapter but not charging, or still measuring): show no time at all.
        let time = ["--", "–", "—", "-"].contains(time.trimmingCharacters(in: .whitespaces)) ? "" : time
        let gap: CGFloat = time.isEmpty ? 0 : 4
        let tAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: textColor) ?? .labelColor]
        let tSize = (time as NSString).size(withAttributes: tAttrs)
        let slot = time.isEmpty ? 0 : max(ceil(tSize.width), ceil(("8:88" as NSString).size(withAttributes: tAttrs).width))
        let plugImage = pluggedIn && !charging
            ? NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            : nil
        let plugW: CGFloat = plugImage.map { ceil($0.size.width) + 3 } ?? 0
        let size = NSSize(width: ceil(bodySize.width + 3 + plugW + gap + slot), height: height)
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let body = NSRect(x: 0, y: (height - bodySize.height) / 2, width: bodySize.width, height: bodySize.height)
        let radius: CGFloat = 3.8
        let text = NSColor(cgColor: textColor) ?? .labelColor
        text.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 1.1, y: body.midY - 2.4, width: 1.8, height: 4.8), xRadius: 0.9, yRadius: 0.9).fill()
        let fillColor: NSColor = charging ? NSColor(srgbRed: 0.20, green: 0.80, blue: 0.35, alpha: 1)
            : lowPower ? NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)
            : percent <= 20 ? NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
            : text
        let level = CGFloat(min(max(percent, 0), 100)) / 100
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).addClip()
        fillColor.setFill()
        NSRect(x: body.minX, y: body.minY, width: max(4, body.width * level), height: body.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Dark number on a light fill, light on a dark fill (normal state in a light menu bar).
        let numberColor: NSColor = fillColor.brightnessComponentSafe > 0.55 ? NSColor(white: 0.08, alpha: 1) : .white
        let n = (charging ? "⚡︎" : "") + "\(percent)"
        let nAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.8, weight: .bold), .foregroundColor: numberColor]
        let nSize = (n as NSString).size(withAttributes: nAttrs)
        (n as NSString).draw(at: NSPoint(x: body.midX - nSize.width / 2, y: body.midY - nSize.height / 2), withAttributes: nAttrs)
        if let plug = plugImage {
            // On the adapter but not charging (held at a limit, or full): a small plug, like AlDente.
            let tinted = NSImage(size: plug.size, flipped: false) { r in
                plug.draw(in: r)
                text.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: body.maxX + 4, y: (height - plug.size.height) / 2, width: plug.size.width, height: plug.size.height))
        }
        (time as NSString).draw(at: NSPoint(x: body.maxX + 3 + plugW + gap, y: (height - tSize.height) / 2), withAttributes: tAttrs)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return (img, size)
    }

    /// Battery outline with a proportional fill; the percentage is XOR-drawn so it reads as a
    /// cut-out over the fill and as ink over the empty part (works as a single-colour template).
    private static func drawBattery(percent: Int, charging: Bool, at o: NSPoint) {
        let body = NSRect(origin: o, size: batteryBody)
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.6, dy: 0.6), xRadius: 3.2, yRadius: 3.2)
        outline.lineWidth = 1.2
        NSColor.black.withAlphaComponent(0.45).setStroke()
        outline.stroke()
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.8, y: body.midY - 2.5, width: 1.7, height: 5), xRadius: 0.8, yRadius: 0.8).fill()
        let inner = body.insetBy(dx: 2, dy: 2)
        let level = CGFloat(min(max(percent, 0), 100)) / 100
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: max(2, inner.width * level), height: inner.height),
                     xRadius: 1.6, yRadius: 1.6).fill()
        let label = (charging ? "⚡︎" : "") + "\(percent)"
        let attrs: [NSAttributedString.Key: Any] = [.font: batteryNumberFont, .foregroundColor: NSColor.black]
        let size = (label as NSString).size(withAttributes: attrs)
        NSGraphicsContext.current?.compositingOperation = .xor
        (label as NSString).draw(at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2), withAttributes: attrs)
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    private static func drawSparkline(_ values: [Float], in r: NSRect) {
        // Faint track so the widget is visible even when the values hug the baseline.
        NSColor.black.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
        let r = r.insetBy(dx: 1.5, dy: 1.5)
        var pts = Array(values.suffix(sparklinePoints))
        guard let last = pts.last else { return }
        if pts.count == 1 { pts = [last, last] }   // right after launch: a flat line at the current level
        let step = r.width / CGFloat(sparklinePoints - 1)
        let x0 = r.maxX - step * CGFloat(pts.count - 1)   // newest sample on the right edge
        let points = pts.enumerated().map { i, v in
            NSPoint(x: x0 + CGFloat(i) * step, y: r.minY + r.height * CGFloat(min(max(v, 0), 1)))
        }
        let line = NSBezierPath()
        let area = NSBezierPath()
        for (i, p) in points.enumerated() {
            if i == 0 { line.move(to: p); area.move(to: p) } else { line.line(to: p); area.line(to: p) }
        }
        area.line(to: NSPoint(x: r.maxX, y: r.minY))
        area.line(to: NSPoint(x: x0, y: r.minY))
        area.close()
        NSColor.black.withAlphaComponent(0.3).setFill()
        area.fill()
        NSColor.black.setStroke()
        line.lineWidth = 1.2
        line.lineJoinStyle = .round
        line.stroke()
    }

    public static func accessibilityText(_ seg: Segment) -> String {
        switch seg.content {
        case .text(let t): t
        case .stacked(let a, let b): "\(a) \(b)"
        case .bar(let v): MetricFormat.percent(v)
        case .sparkline(let v): v.last.map(MetricFormat.percent) ?? ""
        case .labeled(let c, let v): "\(c) \(v)"
        case .battery(let p, let charging, let t, _): "Battery \(p)%\(charging ? ", charging" : "")\(t == "--" ? "" : ", \(t) remaining")"
        }
    }
}

extension NSColor {
    /// Brightness that works for any colour space (catalog colours throw on direct access).
    var brightnessComponentSafe: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 1 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}

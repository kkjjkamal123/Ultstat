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
    }

    public var symbol: String?
    public var content: Content
    /// Widest string this segment can show; fixes its width so the item never resizes.
    public var slot: String = ""

    public init(symbol: String?, content: Content, slot: String = "") {
        self.symbol = symbol
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
    private static var symbols: [String: NSImage] = [:]
    private static var slotWidths: [String: CGFloat] = [:]

    public static func segments(for items: [MenuBarItem], readings r: Readings, settings: AppSettings.Stored) -> [Segment] {
        items.compactMap { item -> Segment? in
            let icon = settings.showIcons ? item.symbol : nil
            let style = settings.styles[item] ?? .text
            switch item {
            case .cpu:
                guard let c = r.cpu else { return Segment(symbol: icon, content: .text("–"), slot: style == .bar ? "" : "88%") }
                return Segment(symbol: icon, content: style == .bar ? .bar(c.total) : .text(MetricFormat.percent(c.total)), slot: "88%")
            case .gpu:
                guard let g = r.gpu else { return nil }
                return Segment(symbol: icon, content: style == .bar ? .bar(g.utilization) : .text(MetricFormat.percent(g.utilization)), slot: "88%")
            case .memory:
                guard let m = r.memory else { return Segment(symbol: icon, content: .text("–"), slot: style == .bar ? "" : "88%") }
                return Segment(symbol: icon, content: style == .bar ? .bar(m.usedFraction) : .text(MetricFormat.percent(m.usedFraction)), slot: "88%")
            case .network:
                guard let n = r.network else { return Segment(symbol: nil, content: .stacked(top: "↑ –", bottom: "↓ –"), slot: "↑ 888K") }
                return Segment(symbol: nil, content: .stacked(top: "↑ " + MetricFormat.rate(n.upload), bottom: "↓ " + MetricFormat.rate(n.download)), slot: "↑ 888K")
            case .disk:
                guard let d = r.disk else { return nil }
                return Segment(symbol: nil, content: .stacked(top: "R " + MetricFormat.rate(d.read), bottom: "W " + MetricFormat.rate(d.write)), slot: "W 888K")
            case .temperature:
                let t = r.sensors[.cpuPerformance]?.max ?? r.sensors[.cpuEfficiency]?.max
                return Segment(symbol: icon, content: .text(t.map { settings.temperatureUnit.format($0) } ?? "–"), slot: "88°")
            case .power:
                guard let w = r.systemPower else { return nil }
                return Segment(symbol: icon, content: .text(MetricFormat.watts(w)), slot: "88.8W")
            case .battery:
                guard let b = r.battery else { return nil }
                return Segment(symbol: batterySymbol(b), content: .text("\(b.percent)%"), slot: "88%")
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
        case .text(let t): max(textWidth(seg.slot, small: false), (t as NSString).size(withAttributes: textAttrs).width)
        case .stacked(let a, let b):
            max(textWidth(seg.slot, small: true), (a as NSString).size(withAttributes: smallAttrs).width,
                (b as NSString).size(withAttributes: smallAttrs).width)
        case .bar: 6
        }
    }

    private static func width(of seg: Segment) -> CGFloat {
        var w = ceil(contentWidth(seg))
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
        let slot = x0 + width - x
        switch seg.content {
        case .text(let t):
            let size = (t as NSString).size(withAttributes: textAttrs)
            // Right-align inside the fixed slot so digits stay put as values change.
            (t as NSString).draw(at: NSPoint(x: x + slot - size.width, y: (height - size.height) / 2), withAttributes: textAttrs)
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
        }
    }

    public static func accessibilityText(_ seg: Segment) -> String {
        switch seg.content {
        case .text(let t): t
        case .stacked(let a, let b): "\(a) \(b)"
        case .bar(let v): MetricFormat.percent(v)
        }
    }
}

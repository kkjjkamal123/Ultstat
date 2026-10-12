import SwiftUI
import UltstatCore
import UltstatKit

// Building blocks for the Liquid Glass panels (macOS 26). The panel itself is an NSGlassEffectView
// (see DashboardPanel); these are the surfaces, charts and gauges drawn on top of it.
//
// Cost rules (measured earlier): no blanket animations, no numericText transitions (their glyph
// rasters were never freed), one Canvas per chart. Animations are scoped to the value they animate.

// MARK: - Motion

/// Animation policy. Only render-side changes animate (trim, scale, shape paths), never layout:
/// layout-driven animations at every reading kept the panel relaying out at 120 Hz (160-240 ms/s).
enum Motion {
    /// Off only with Reduce Motion. (Low Power Mode keeps them: they are short, GPU-composited and
    /// run only while a panel is open.)
    static var enabled: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !UserDefaults.standard.bool(forKey: "UltstatNoMotion")
    }

    /// Rings, gauges, bars and meters.
    static var animation: Animation? { enabled ? .smooth(duration: 0.5) : nil }

}

// MARK: - Surfaces

/// A softly lifted rounded surface on the glass.
struct Card<Content: View>: View {
    var spacing: CGFloat = 8
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Icon, title and an optional trailing value at the top of a card.
struct CardTitle: View {
    var symbol: String
    var title: String
    var tint: Color = Theme.series1
    var trailing: String?
    var help: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            if let help { HelpBadge(help) }
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
    }
}

/// Caption over a large rounded number ("Battery Level" / "80 %"), as in AlDente's cards.
struct BigNumber: View {
    var caption: String
    var value: String
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
                Text(value).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

/// Coloured rounded-square icon used in panel headers (like System Settings).
struct IconTile: View {
    var symbol: String
    var tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))
            .shadow(color: tint.opacity(0.35), radius: 4, y: 1)
    }
}

// MARK: - Charts

/// Smooth area chart: gradient fill under the first series, glowing line, a dot on the newest value,
/// faint grid, optional dashed reference line (a charge limit, a threshold).
///
/// The curves are Core Animation shape layers (ChartLayerView). Each reading updates them once,
/// atomically, and the render server glides the new point in (scroll left, ease any rescale), so
/// the motion costs the app no per-frame work. Drawing them in SwiftUI meant re-rasterising every
/// frame on the CPU (measured ~300 ms/s with a panel open).
struct SmoothChart: View {
    var series: [([Float], Color)]
    var maxValue: Float?
    var minValue: Float = 0
    var reference: Float?
    var referenceColor: Color = Theme.series2
    var height: CGFloat = 78
    /// Tile sparkline: no background, grid or marker.
    var compact = false

    var body: some View {
        let all = series.flatMap(\.0)
        let top = maxValue ?? max((all.max() ?? 1) * 1.15, minValue + 0.0001)
        ZStack {
            if !compact {
                Canvas { ctx, size in
                    let plot = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: ChartLayerView.inset)
                    for i in 1...3 {
                        let y = plot.minY + plot.height * CGFloat(i) / 4
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
                    }
                    if let reference {
                        let f = CGFloat(min(max((reference - minValue) / max(top - minValue, 0.0001), 0), 1))
                        let y = plot.maxY - plot.height * f
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(referenceColor.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    }
                }
            }
            LayerChart(series: series, top: top, minValue: minValue, compact: compact)
        }
        .frame(height: height)
        .padding(.horizontal, compact ? 0 : 6)
        .background(compact ? Color.clear : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 3 : 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("History chart")
    }

    /// Catmull-Rom spline through the points, as cubic Béziers, with control points clamped to the
    /// plot so the curve never overshoots past 0 % or 100 %.
    static func smoothPath(_ p: [CGPoint], minY: CGFloat, maxY: CGFloat) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = p.first else { return path }
        path.move(to: first)
        guard p.count > 2 else {
            if p.count == 2 { path.addLine(to: p[1]) }
            return path
        }
        func clamp(_ c: CGPoint) -> CGPoint { CGPoint(x: c.x, y: min(max(c.y, minY), maxY)) }
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: clamp(c1), control2: clamp(c2))
        }
        return path
    }
}

private struct LayerChart: NSViewRepresentable {
    var series: [([Float], Color)]
    var top: Float
    var minValue: Float
    var compact: Bool

    func makeNSView(context: Context) -> ChartLayerView { ChartLayerView() }

    func updateNSView(_ view: ChartLayerView, context: Context) {
        view.apply(series.map { ChartLayerView.Series(values: $0.0, color: NSColor($0.1)) }, top: top, minValue: minValue, compact: compact)
    }
}

/// Chart curves as CAShapeLayers inside one container layer. A new reading replaces the paths in one
/// transaction (so nothing ever draws twice or steps back), then a single transform animation in the
/// render server slides the container one sample to the left and eases the vertical scale.
final class ChartLayerView: NSView {
    struct Series: Equatable {
        var values: [Float]
        var color: NSColor
    }

    static let inset: CGFloat = 5

    private let container = CALayer()
    private var layers: [(gradient: CAGradientLayer, area: CAShapeLayer, glow: CAShapeLayer, line: CAShapeLayer,
                          halo: CAShapeLayer, dot: CAShapeLayer)] = []
    private var series: [Series] = []
    private var top: Float = 1
    private var minValue: Float = 0
    private var compact = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        container.anchorPoint = .zero
        layer?.addSublayer(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ new: [Series], top newTop: Float, minValue: Float, compact: Bool) {
        guard new != series || newTop != top || compact != self.compact else { return }
        let old = series
        let oldTop = top
        // A normal tick: same series, each one sample longer (growing) or the same length (full buffer, advanced).
        let advanced = !old.isEmpty && old.count == new.count && zip(old, new).allSatisfy {
            $1.values.count >= $0.values.count && $1.values.count > 1 && $0.values != $1.values
        }
        series = new
        top = newTop
        self.minValue = minValue
        self.compact = compact
        redraw()
        guard advanced, Motion.enabled, window?.occlusionState.contains(.visible) == true, let n = new.first?.values.count, n > 1 else { return }
        let step = bounds.width / CGFloat(n - 1)
        let span = CGFloat(oldTop - minValue)
        let scaleY = span > 0 ? CGFloat(newTop - minValue) / span : 1
        let from = CATransform3DConcat(CATransform3DMakeScale(1, scaleY, 1), CATransform3DMakeTranslation(step, 0, 0))
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: from)
        slide.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        slide.duration = 0.55
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        container.add(slide, forKey: "slide")
    }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        container.frame = bounds
        container.removeAnimation(forKey: "slide")
        while layers.count < series.count { addSeriesLayers() }
        while layers.count > series.count { removeSeriesLayers() }
        let plot = bounds.insetBy(dx: 0, dy: compact ? 1 : Self.inset)
        for (index, s) in series.enumerated() {
            let l = layers[index]
            var color = s.color.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { color = s.color.cgColor }
            let pts = points(s.values, in: plot)
            let line = pts.count > 1 ? SmoothChart.smoothPath(pts, minY: plot.minY, maxY: plot.maxY) : CGMutablePath()
            l.line.path = line
            l.line.strokeColor = color
            l.line.lineWidth = compact ? 1.5 : 2
            l.glow.path = compact ? nil : line
            l.glow.strokeColor = color.copy(alpha: 0.3)
            let area = line.mutableCopy() ?? CGMutablePath()
            if let last = pts.last, let first = pts.first {
                area.addLine(to: CGPoint(x: last.x, y: bounds.minY))
                area.addLine(to: CGPoint(x: first.x, y: bounds.minY))
                area.closeSubpath()
            }
            l.area.path = index == 0 ? area : nil
            l.gradient.frame = bounds
            l.gradient.colors = [color.copy(alpha: compact ? 0.3 : 0.42) as Any, color.copy(alpha: 0.03) as Any]
            l.gradient.isHidden = index != 0
            if let last = pts.last, !compact {
                l.dot.path = CGPath(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8), transform: nil)
                l.dot.fillColor = color
                l.halo.path = CGPath(ellipseIn: CGRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12), transform: nil)
                l.halo.fillColor = NSColor.labelColor.cgColor.copy(alpha: 0.25)
            } else {
                l.dot.path = nil
                l.halo.path = nil
            }
        }
    }

    /// Points in layer coordinates (origin bottom-left), one extra off the left edge so the slide
    /// never reveals a gap.
    private func points(_ values: [Float], in plot: CGRect) -> [CGPoint] {
        let n = values.count
        guard n > 1 else { return [] }
        let step = bounds.width / CGFloat(n - 1)
        let span = max(top - minValue, 0.0001)
        func y(_ v: Float) -> CGFloat { plot.minY + plot.height * CGFloat(min(max((v - minValue) / span, 0), 1)) }
        return [CGPoint(x: -step, y: y(values[0]))] + values.enumerated().map { CGPoint(x: CGFloat($0) * step, y: y($1)) }
    }

    private func addSeriesLayers() {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        let area = CAShapeLayer()
        gradient.mask = area
        func stroke(_ width: CGFloat) -> CAShapeLayer {
            let s = CAShapeLayer()
            s.fillColor = nil
            s.lineWidth = width
            s.lineCap = .round
            s.lineJoin = .round
            return s
        }
        let glow = stroke(5), line = stroke(2), halo = CAShapeLayer(), dot = CAShapeLayer()
        for l in [gradient, glow, line, halo, dot] as [CALayer] {
            l.actions = ["path": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            container.addSublayer(l)
        }
        layers.append((gradient, area, glow, line, halo, dot))
    }

    private func removeSeriesLayers() {
        guard let l = layers.popLast() else { return }
        for layer in [l.gradient, l.glow, l.line, l.halo, l.dot] as [CALayer] { layer.removeFromSuperlayer() }
    }
}

// MARK: - Rings and gauges

/// Donut of parts (fractions of 1) with a centre value; arcs animate smoothly between readings.
struct AnimatedRing: View {
    var parts: [(Float, Color)]
    var center: String
    var caption: String?
    var lineWidth: CGFloat = 11

    var body: some View {
        ZStack {
            ArcLayer(parts: parts, lineWidth: lineWidth, roundCaps: parts.count == 1)
            VStack(spacing: 0) {
                Text(center).font(.system(size: 21, weight: .bold, design: .rounded)).monospacedDigit()
                if let caption { Text(caption).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption ?? "") \(center)")
    }
}

/// 270° arc gauge in one hue (magnitude), switching to a reserved status colour plus a warning
/// icon only when the value crosses a threshold. The value arc animates.
struct ArcGauge: View {
    /// 0...1
    var value: Double
    var label: String
    var caption: String
    var tint: Color = Theme.orange
    var status: Color?
    var lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            ArcLayer(parts: [(Float(min(max(value, 0.01), 1)), status ?? tint)], lineWidth: lineWidth, sweep: 0.75, startAngle: 135,
                     roundCaps: true)
            VStack(spacing: 0) {
                Text(label).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                HStack(spacing: 2) {
                    if let status { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(status) }
                    Text(caption).foregroundStyle(.secondary)
                }
                .font(.system(size: 9.5, weight: .medium))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(label)")
    }
}

/// Horizontal capsule meter with a gradient fill that animates to the new value.
struct GlassMeter: View {
    var value: Float
    var tint: Color = Theme.series1
    var height: CGFloat = 7

    var body: some View {
        MeterLayer(value: value, tint: tint).frame(height: height)
    }
}

// MARK: - Power flow

/// Adapter → Mac → battery, AlDente style: each node with its wattage, animated chevrons where power flows.
struct PowerFlowStrip: View {
    var adapterWatts: Double
    var systemWatts: Double
    /// Positive while charging, negative while the battery supplies the Mac.
    var batteryWatts: Double
    var batteryPercent: Int

    var body: some View {
        let fromAdapter = adapterWatts > 0.3
        let charging = batteryWatts > 0.3
        let discharging = batteryWatts < -0.3
        HStack(spacing: 4) {
            node("powerplug.fill", "Adapter", adapterWatts, active: fromAdapter, tint: .yellow)
            arrow(active: fromAdapter, reversed: false)
            node("laptopcomputer", "Mac", systemWatts, active: true, tint: Theme.series1)
            arrow(active: charging || discharging, reversed: discharging)
            node(batterySymbol, "Battery", abs(batteryWatts), active: charging || discharging, tint: .green,
                 prefix: discharging ? "−" : charging ? "+" : "")
        }
    }

    private var batterySymbol: String {
        switch batteryPercent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func node(_ symbol: String, _ title: String, _ watts: Double, active: Bool, tint: Color, prefix: String = "") -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                .frame(height: 20)
            Text(prefix + formatWatts(watts)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(active ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func arrow(active: Bool, reversed: Bool) -> some View {
        Image(systemName: reversed ? "chevron.left.2" : "chevron.right.2")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(active ? AnyShapeStyle(Theme.series1) : AnyShapeStyle(.quaternary))
            // Static: a repeating symbol effect redraws the panel continuously while it is open.
            .frame(width: 16)
    }
}

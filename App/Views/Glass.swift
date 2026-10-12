import SwiftUI
import UltstatCore
import UltstatKit

// Building blocks for the Liquid Glass panels (macOS 26). The panel itself is an NSGlassEffectView
// (see DashboardPanel); these are the surfaces, charts and gauges drawn on top of it.
//
// Cost rules (measured earlier): no blanket animations, no numericText transitions (their glyph
// rasters were never freed), one Canvas per chart. Animations are scoped to the value they animate.

// MARK: - Motion

/// Animation policy. Readings arrive every 0.6 s; an animation on every one of them keeps the
/// window redrawing at the display's full rate (120 Hz on ProMotion), measured at 160-240 ms/s of
/// CPU with a panel open. So: short animations, only for changes big enough to see (values are
/// bucketed before they key an animation), only render-side transforms (trim, scale) that don't
/// relayout, and none at all in Low Power Mode or with Reduce Motion.
enum Motion {
    static var enabled: Bool {
        !ProcessInfo.processInfo.isLowPowerModeEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var animation: Animation? { enabled ? .smooth(duration: 0.3) : nil }

    /// Animation key that only changes when `value` (0...1) moves by about 2 %.
    static func bucket(_ value: Double) -> Int { Int((value * 50).rounded()) }
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

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title).font(.system(size: 12.5, weight: .semibold))
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
/// faint grid, optional dashed reference line (a charge limit, a threshold). One Canvas draw.
struct SmoothChart: View {
    var series: [([Float], Color)]
    var maxValue: Float?
    var minValue: Float = 0
    var reference: Float?
    var referenceColor: Color = Theme.series2
    var height: CGFloat = 78

    var body: some View {
        let all = series.flatMap(\.0)
        let top = maxValue ?? max((all.max() ?? 1) * 1.15, minValue + 0.0001)
        Canvas { ctx, size in
            let plot = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 5)
            for i in 1...3 {
                let y = plot.minY + plot.height * CGFloat(i) / 4
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
            }
            func point(_ v: Float, _ i: Int, _ n: Int) -> CGPoint {
                let f = CGFloat(min(max((v - minValue) / max(top - minValue, 0.0001), 0), 1))
                return CGPoint(x: n > 1 ? size.width * CGFloat(i) / CGFloat(n - 1) : size.width, y: plot.maxY - plot.height * f)
            }
            if let reference {
                let y = point(reference, 0, 1).y
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(referenceColor.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
            for (index, (values, tint)) in series.enumerated() where values.count > 1 {
                let pts = values.enumerated().map { point($1, $0, values.count) }
                let line = Self.smoothPath(pts, minY: plot.minY, maxY: plot.maxY)
                if index == 0 {
                    var area = line
                    area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
                    area.addLine(to: CGPoint(x: pts[0].x, y: size.height))
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.42), tint.opacity(0.03)]),
                                                         startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: size.height)))
                }
                ctx.stroke(line, with: .color(tint.opacity(0.3)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // Newest value: an 8 pt marker with a 2 pt surface ring so it separates from the line.
                let last = pts[pts.count - 1]
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12)), with: .color(.primary.opacity(0.25)))
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)), with: .color(tint))
            }
        }
        .frame(height: height)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("History chart")
    }

    /// Catmull-Rom spline through the points, as cubic Béziers, with control points clamped to the
    /// plot so the curve never overshoots past 0 % or 100 %.
    static func smoothPath(_ p: [CGPoint], minY: CGFloat, maxY: CGFloat) -> Path {
        var path = Path()
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

// MARK: - Rings and gauges

/// Donut of parts (fractions of 1) with a centre value; arcs animate smoothly between readings.
struct AnimatedRing: View {
    var parts: [(Float, Color)]
    var center: String
    var caption: String?
    var lineWidth: CGFloat = 11

    var body: some View {
        let segments = Self.segments(parts)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.09), lineWidth: lineWidth)
            ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                Circle()
                    .trim(from: s.start, to: s.end)
                    .stroke(s.color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: segments.count == 1 ? .round : .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(center).font(.system(size: 21, weight: .bold, design: .rounded)).monospacedDigit()
                if let caption { Text(caption).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary) }
            }
        }
        .padding(lineWidth / 2)
        .animation(Motion.animation, value: segments.map { Motion.bucket(Double($0.end)) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption ?? "") \(center)")
    }

    private static func segments(_ parts: [(Float, Color)]) -> [(start: CGFloat, end: CGFloat, color: Color)] {
        var start: CGFloat = 0
        let gap: CGFloat = parts.filter { $0.0 > 0.005 }.count > 1 ? 0.006 : 0
        return parts.map { fraction, color in
            let sweep = CGFloat(min(max(fraction, 0), 1))
            defer { start += sweep }
            return (start, max(start, min(1, start + sweep - gap)), color)
        }
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
        let v = CGFloat(min(max(value, 0), 1))
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.primary.opacity(0.09), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * max(v, 0.01))
                .stroke((status ?? tint).gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            VStack(spacing: 0) {
                Text(label).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                HStack(spacing: 2) {
                    if let status { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(status) }
                    Text(caption).foregroundStyle(.secondary)
                }
                .font(.system(size: 9.5, weight: .medium))
            }
        }
        .padding(lineWidth / 2)
        .animation(Motion.animation, value: Motion.bucket(Double(v)))
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
        let v = CGFloat(min(max(value, 0), 1))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.09))
            // Scaled rather than resized: animating a frame relayouts the panel every frame.
            Capsule().fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                .scaleEffect(x: max(v, 0.02), y: 1, anchor: .leading)
                .animation(Motion.animation, value: Motion.bucket(Double(v)))
        }
        .frame(height: height)
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

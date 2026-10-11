import SwiftUI

/// Minimal line chart. One `Canvas` draw per update; no per-point views or layout.
struct Sparkline: View {
    var values: [Float]
    var maxValue: Float? = nil
    var tint: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? values.max() ?? 1, 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(v / top, 1))))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Horizontal capsule meter.
struct Meter: View {
    var value: Float
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient)
                    .frame(width: max(3, geo.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: 5)
        .animation(.smooth(duration: 0.35), value: value)
        .accessibilityValue(Text("\(Int(value * 100)) percent"))
    }
}

/// Stacked segments (e.g. memory app / wired / compressed).
struct StackedMeter: View {
    var parts: [(Float, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1.gradient)
                        .frame(width: max(0, geo.size.width * CGFloat(min(max(part.0, 0), 1)) - 1))
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

/// A card with an icon, title, headline value and arbitrary content.
struct MetricCard<Content: View>: View {
    var title: String
    var symbol: String
    var value: String
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(tint)
            }
            content
        }
        .padding(11)
        .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Small "label ........ value" row.
struct StatRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

enum ByteFormat {
    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// "0 B/s", "260 B/s", "12 KB/s", "1.2 MB/s", "34 MB/s", "1.1 GB/s".
    static func rate(_ bps: Double) -> String {
        let v = max(0, bps)
        switch v {
        case ..<1_000: return "\(Int(v.rounded())) B/s"
        case ..<10_000: return String(format: "%.1f KB/s", v / 1_000)
        case ..<1_000_000: return "\(Int((v / 1_000).rounded())) KB/s"
        case ..<10_000_000: return String(format: "%.1f MB/s", v / 1_000_000)
        case ..<1_000_000_000: return "\(Int((v / 1_000_000).rounded())) MB/s"
        default: return String(format: "%.1f GB/s", v / 1_000_000_000)
        }
    }
}

import AppKit
import SwiftUI

/// Chart colours, validated with the dataviz skill's checker against the popover surfaces
/// (light #efefef, dark #242424; all-pairs CVD ΔE ≥ 12.6, normal-vision ΔE ≥ 21.9, ≥ 3:1 contrast).
/// Slot order is fixed: a series keeps its colour wherever it appears.
enum Theme {
    static let series1 = adaptive(light: 0x009A86, dark: 0x10AD92)   // teal (brand)
    static let series2 = adaptive(light: 0xD9681C, dark: 0xDC6A22)   // amber
    static let series3 = adaptive(light: 0x6250D6, dark: 0x9085E9)   // violet
    /// Reserved status colours; always paired with an icon or label, never used for series.
    static let warning = adaptive(light: 0xB27600, dark: 0xE0A000)
    static let critical = adaptive(light: 0xD33A3A, dark: 0xE66767)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Minimal line chart. One `Canvas` draw per update; no per-point views or layout.
struct Sparkline: View {
    var values: [Float]
    var maxValue: Float? = nil
    var tint: Color = Theme.series1
    var filled = true

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
            if filled {
                ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.22), tint.opacity(0.0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Horizontal capsule meter.
struct Meter: View {
    var value: Float
    var tint: Color = Theme.series1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
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
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1)
                        .frame(width: max(0, geo.size.width * CGFloat(min(max(part.0, 0), 1)) - 2))
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
    /// Identity mark shown beside the title. Text never takes the series colour.
    var tint: Color? = nil
    var status: Color? = nil
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
                if let status {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(status)
                }
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(11)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Legend for charts with two or more series: colour dot + label, never colour alone.
struct Legend: View {
    var items: [(String, Color)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 3) {
                    Circle().fill(item.1).frame(width: 6, height: 6)
                    Text(item.0).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
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

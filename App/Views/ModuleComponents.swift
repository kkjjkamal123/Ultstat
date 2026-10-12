import SwiftUI
import UltstatKit

/// Donut chart of parts (fractions of 1) with a centre label. Drawn in one Canvas.
struct RingChart: View {
    var parts: [(Float, Color)]
    var center: String
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let r = min(size.width, size.height) / 2 - lineWidth / 2
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                var track = Path()
                track.addArc(center: c, radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                ctx.stroke(track, with: .color(.secondary.opacity(0.25)), lineWidth: lineWidth)
                var start = Angle.degrees(-90)
                let gap = Angle.degrees(parts.filter { $0.0 > 0.005 }.count > 1 ? 2 : 0)
                for (fraction, color) in parts where fraction > 0.005 {
                    let sweep = Angle.degrees(360 * Double(min(max(fraction, 0), 1)))
                    var arc = Path()
                    arc.addArc(center: c, radius: r, startAngle: start + gap / 2, endAngle: start + sweep - gap / 2, clockwise: false)
                    ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    start += sweep
                }
            }
            Text(center)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(center)
    }
}

/// Semicircular gauge with a needle; the arc goes green → yellow → red.
struct PressureGauge: View {
    /// 0...1 needle position.
    var value: Double
    var label: String

    var body: some View {
        VStack(spacing: 2) {
            Canvas { ctx, size in
                let w: CGFloat = 7
                let r = min(size.width / 2, size.height) - w
                let c = CGPoint(x: size.width / 2, y: size.height - 2)
                let segments: [(Double, Double, Color)] = [(180, 240, .green), (240, 300, .yellow), (300, 360, .red)]
                for (a, b, color) in segments {
                    var arc = Path()
                    arc.addArc(center: c, radius: r, startAngle: .degrees(a + 1), endAngle: .degrees(b - 1), clockwise: false)
                    ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round))
                }
                let angle = Angle.degrees(180 + 180 * min(max(value, 0), 1))
                var needle = Path()
                needle.move(to: c)
                needle.addLine(to: CGPoint(x: c.x + cos(angle.radians) * (r - 10), y: c.y + sin(angle.radians) * (r - 10)))
                ctx.stroke(needle, with: .color(.accentColor), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(.accentColor))
            }
            .frame(width: 110, height: 58)
            Text(label).font(.system(size: 12, weight: .semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pressure \(label)")
    }
}

/// Filled history chart with a faint background panel, like Stats' "Usage history".
struct HistoryChart: View {
    var series: [([Float], Color)]
    var maxValue: Float?
    var height: CGFloat = 92

    var body: some View {
        let top = maxValue ?? max(series.flatMap(\.0).max() ?? 1, 0.0001)
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.fill.quaternary)
            ForEach(Array(series.enumerated()), id: \.offset) { i, s in
                Sparkline(values: s.0, maxValue: top, tint: s.1, filled: i == 0)
                    .padding(.vertical, 4)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// "─── DETAILS ───" divider.
struct SectionHeader: View {
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            line
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(1).foregroundStyle(.tertiary)
                .fixedSize()
            line
        }
        .padding(.top, 6)
    }

    private var line: some View { Rectangle().fill(.separator).frame(height: 0.5) }
}

/// Colour dot, label, value.
struct LegendRow: View {
    var color: Color?
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            if let color { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11) }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12.5))
    }
}

struct ProcessRow {
    var pid: Int32
    var name: String
    var value: String
}

/// App icons for process rows, cached per pid (command-line tools get the executable icon).
@MainActor
enum ProcessIcons {
    private static var cache: [Int32: (NSImage, String?)] = [:]
    private static let generic: NSImage = NSWorkspace.shared.icon(for: .unixExecutable)

    private static func entry(_ pid: Int32) -> (NSImage, String?) {
        if let hit = cache[pid] { return hit }
        let app = NSRunningApplication(processIdentifier: pid)
        let e = (app?.icon ?? generic, app?.localizedName)
        if cache.count > 400 { cache.removeAll() }
        cache[pid] = e
        return e
    }

    static func icon(for pid: Int32) -> NSImage { entry(pid).0 }

    /// The app's display name ("Safari Web Content") when it has one, else the executable name.
    static func name(for pid: Int32, fallback: String) -> String { entry(pid).1 ?? fallback }
}

/// Top-processes table with app icons.
struct ProcessTable: View {
    var rows: [ProcessRow]
    var valueTitle: String

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Process").foregroundStyle(.tertiary)
                Spacer()
                Text(valueTitle).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            if rows.isEmpty {
                Text("Measuring…").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    Image(nsImage: ProcessIcons.icon(for: row.pid)).resizable().frame(width: 16, height: 16)
                    Text(ProcessIcons.name(for: row.pid, fallback: row.name)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.value).monospacedDigit()
                }
                .font(.system(size: 12))
            }
        }
    }
}

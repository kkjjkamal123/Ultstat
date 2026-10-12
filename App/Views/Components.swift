import UltstatKit
import AppKit
import SwiftUI

/// Chart colours, validated with the dataviz skill's checker against the popover surfaces
/// (light #efefef, dark #242424; all-pairs CVD ΔE ≥ 12.6, normal-vision ΔE ≥ 21.9, ≥ 3:1 contrast).
/// Slot order is fixed: a series keeps its colour wherever it appears.
enum Theme {
    // Chart colours: the dataviz reference palette, stepped per mode and validated with its script
    // against this app's card surfaces (#E9E9EB light, #2A2A2C dark). Slots 1-3 pass all-pairs CVD
    // and normal-vision checks, so they may share one chart; the others are single-series hues.
    static let blue = adaptive(light: 0x2A78D6, dark: 0x3987E5)     // slot 1
    static let orange = adaptive(light: 0xEB6834, dark: 0xD95926)   // slot 2
    static let aqua = adaptive(light: 0x1BAF7A, dark: 0x199E70)     // slot 3
    static let yellow = adaptive(light: 0xEDA100, dark: 0xC98500)   // slot 4 (single-series only)
    static let violet = adaptive(light: 0x6250D6, dark: 0x9085E9)   // slot 7 (single-series only)
    static let magenta = adaptive(light: 0xE87BA4, dark: 0xD55181)  // slot 5 (single-series only)
    static let series1 = blue
    static let series2 = orange
    static let series3 = aqua
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

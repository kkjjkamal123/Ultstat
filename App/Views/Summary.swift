import SwiftUI
import UltstatCore
import UltstatKit

/// Always-visible key numbers. Each tile opens its tab.
struct SummaryGrid: View {
    @Environment(AppModel.self) private var model
    var r: Readings
    var select: (DashboardTab) -> Void

    var body: some View {
        let unit = model.settings.stored.temperatureUnit
        let hottest = r.sensors[.cpuPerformance]?.max ?? r.sensors.values.map(\.max).max()
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile("CPU", r.cpu.map { MetricFormat.percent($0.total) }, sub: r.cpu?.performance.map { "P " + MetricFormat.percent($0) },
                     history: model.cpuHistory, tab: .cpu)
                tile("GPU", r.gpu.map { MetricFormat.percent($0.utilization) }, sub: r.componentPower?.gpu.map(watts),
                     history: model.gpuHistory, tab: .gpu)
                tile("Memory", r.memory.map { MetricFormat.percent($0.usedFraction) }, sub: r.memory.map { ByteFormat.size($0.used) },
                     history: model.memoryHistory, tab: .memory)
            }
            GridRow {
                tile("Power", r.systemPower.map { String(format: "%.1f W", $0) }, sub: "whole Mac", history: nil, tab: .battery)
                tile("Battery", r.battery.map { "\($0.percent)%" }, sub: r.battery.map(BatteryTime.short), history: nil, tab: .battery,
                     status: batteryStatus(r.battery))
                tile("Temp", hottest.map { unit.format($0) }, sub: "CPU", history: model.temperatureHistory(.cpuPerformance),
                     historyMax: 110, tab: .sensors, status: (hottest ?? 0) >= 95 ? Theme.critical : (hottest ?? 0) >= 85 ? Theme.warning : nil)
            }
        }
    }

    private func watts(_ w: Double) -> String { w < 1 ? String(format: "%.0f mW", w * 1000) : String(format: "%.1f W", w) }

    private func batteryStatus(_ b: BatterySnapshot?) -> Color? {
        guard let b, !b.externalConnected else { return nil }
        return b.percent <= 10 ? Theme.critical : b.percent <= 20 ? Theme.warning : nil
    }

    private func tile(_ title: String, _ value: String?, sub: String?, history: [Float]?, historyMax: Float = 1,
                      tab: DashboardTab, status: Color? = nil) -> some View {
        Button { select(tab) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    if let status { Circle().fill(status).frame(width: 6, height: 6) }
                }
                Text(value ?? "–")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(sub ?? " ").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if let history, history.count > 1 {
                    Sparkline(values: Array(history.suffix(40)), maxValue: historyMax).frame(height: 14)
                } else {
                    Color.clear.frame(height: 14)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(value ?? "unavailable"), \(sub ?? "")")
        .accessibilityHint("Shows \(tab.title) details")
    }
}

/// Icon tab bar with the selected title shown under it.
struct TabStrip: View {
    @Binding var selection: DashboardTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DashboardTab.allCases) { t in
                Button { selection = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 13, weight: selection == t ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(selection == t ? AnyShapeStyle(Theme.series1) : AnyShapeStyle(.secondary))
                        .background(selection == t ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.title)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(selection == t ? .isSelected : [])
                .accessibilityIdentifier("tab.\(t.rawValue)")
            }
        }
        .padding(3)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct EmptyNote: View {
    var text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
    }
}

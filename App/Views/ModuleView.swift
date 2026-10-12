import AppKit
import SwiftUI
import UltstatCore
import UltstatKit

enum ModulePanelSize {
    static let width: CGFloat = 352
}

extension MenuBarItem {
    /// Header tint for the module's panel.
    var tint: Color {
        switch self {
        case .cpu: .blue
        case .gpu: .purple
        case .memory: .orange
        case .network: .cyan
        case .disk: .indigo
        case .temperature: .red
        case .power: .yellow
        case .battery: .green
        }
    }
}

/// The panel for one menu-bar item: Liquid Glass cards with live charts, laid out like Stats
/// (system modules) and AlDente (battery). Only the clicked module is built.
struct ModuleView: View {
    @Environment(AppModel.self) private var model
    var item: MenuBarItem

    var body: some View {
        let r = model.panelReadings
        VStack(spacing: 10) {
            header
            ViewThatFits(in: .vertical) {
                body(r)
                ScrollView { body(r) }.scrollIndicators(.never)
            }
        }
        .padding(12)
        .frame(width: ModulePanelSize.width)
        .focusEffectDisabled()
    }

    private func body(_ r: Readings) -> some View {
        VStack(spacing: 8) { ModuleContent(item: item, r: r) }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
    }

    private var header: some View {
        HStack(spacing: 9) {
            IconTile(symbol: item.symbol, tint: item.tint)
            Text(title).font(.system(size: 15, weight: .bold))
            Spacer()
            Button("All metrics", systemImage: "square.grid.2x2") { model.openFullDashboard() }
                .help("All metrics")
                .accessibilityIdentifier("module.dashboard")
            Button("Settings", systemImage: "gearshape") { model.openSettings() }
                .help("Settings (⌘,)")
                .accessibilityIdentifier("module.settings")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
    }

    private var title: String {
        switch item {
        case .memory: "Memory"
        case .temperature: "Sensors"
        default: item.title
        }
    }

}

/// The cards for one metric; shared by its menu-bar panel and the All metrics dashboard tabs.
struct ModuleContent: View {
    var item: MenuBarItem
    var r: Readings

    var body: some View {
        switch item {
        case .cpu: CPUModule(r: r)
        case .gpu: GPUModule(r: r)
        case .memory: MemoryModule(r: r)
        case .disk: DiskModule(r: r)
        case .network: NetworkModule(r: r)
        case .temperature: SensorsModule(r: r)
        case .power: PowerModule(r: r)
        case .battery: BatteryModule(r: r)
        }
    }
}

// MARK: - Shared helpers

/// Whole watts ("3 W"); below 1 W in whole milliwatts ("120 mW"). No decimals anywhere.
func formatWatts(_ w: Double) -> String { w < 1 ? "\(Int((max(0, w) * 1000).rounded())) mW" : "\(Int(w.rounded())) W" }

func formatDuration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60, h = m / 60, d = h / 24
    if d > 0 { return "\(d)d \(h % 24)h \(m % 60)m" }
    return h > 0 ? "\(h)h \(m % 60)m" : "\(m)m"
}

func sensorLabel(_ g: SensorGroup) -> String {
    switch g {
    case .cpuPerformance: "CPU \(CPUTopology.performanceName)"
    case .cpuEfficiency: "CPU \(CPUTopology.efficiencyName)"
    default: g.displayName
    }
}

/// Reserved status colour for a temperature (warm ≥ 85 °C, hot ≥ 95 °C); nil when normal.
func temperatureStatus(_ c: Float?) -> Color? {
    guard let c else { return nil }
    return c >= 95 ? Theme.critical : c >= 85 ? Theme.warning : nil
}

/// Temperature as a 0...1 gauge position (30 °C … 100 °C).
func temperatureGauge(_ c: Float) -> Double { Double(min(max((c - 30) / 70, 0), 1)) }

/// Top-processes card.
private struct TopProcessesCard: View {
    var rows: [ProcessRow]
    var valueTitle: String
    var symbol = "list.bullet.rectangle"

    var body: some View {
        Card {
            CardTitle(symbol: symbol, title: "Top processes", tint: .secondary, help: Help.processes)
            ProcessTable(rows: rows, valueTitle: valueTitle)
        }
    }
}

// MARK: - CPU

private struct CPUModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        let c = r.cpu ?? .zero
        let unit = model.settings.stored.temperatureUnit
        let temp = r.sensors[.cpuPerformance]?.max
        Card {
            HStack(spacing: 14) {
                AnimatedRing(parts: [(c.system, Theme.series2), (c.user, Theme.series1)], center: MetricFormat.percent(c.total), caption: "Usage")
                    .frame(width: 112, height: 112)
                ArcGauge(value: temp.map(temperatureGauge) ?? 0, label: temp.map { unit.format($0) } ?? "–", caption: "Temperature",
                         status: temperatureStatus(temp))
                    .frame(width: 112, height: 112)
            }
            .frame(maxWidth: .infinity)
            Legend(items: [("System \(MetricFormat.percent(c.system))", Theme.series2), ("User \(MetricFormat.percent(c.user))", Theme.series1),
                           ("Idle \(MetricFormat.percent(max(0, 1 - c.total)))", .secondary.opacity(0.4))])
        }
        Card {
            CardTitle(symbol: "chart.xyaxis.line", title: "Usage history", tint: MenuBarItem.cpu.tint, trailing: MetricFormat.percent(c.total),
                      help: Help.cpuUsage)
            SmoothChart(series: [(model.cpuHistory, Theme.blue)], maxValue: 1)
        }
        if !c.perCore.isEmpty {
            Card {
                CardTitle(symbol: "square.grid.3x3.fill", title: "Cores", tint: MenuBarItem.cpu.tint,
                          trailing: [c.performance.map { "\(CPUTopology.performanceName.prefix(1)) \(MetricFormat.percent($0))" },
                                     c.efficiency.map { "E \(MetricFormat.percent($0))" }].compactMap { $0 }.joined(separator: " · "),
                          help: Help.cores)
                CoreBars(load: c, kinds: model.hub.cpu.topology.kinds)
            }
        }
        Card(spacing: 6) {
            CardTitle(symbol: "info.circle", title: "Details", tint: .secondary)
            if let l = SystemInfo.loadAverage() {
                LegendRow(color: nil, label: "Average load", help: Help.loadAverage, value: String(format: "%.2f  %.2f  %.2f", l.0, l.1, l.2))
            }
            LegendRow(color: nil, label: "Power", value: r.componentPower?.cpu.map(formatWatts) ?? (model.helperReady ? "–" : "needs helper"))
            LegendRow(color: nil, label: "Uptime", value: formatDuration(SystemInfo.uptime()))
        }
        TopProcessesCard(rows: model.hub.processes.topByCPU.map { ProcessRow(pid: $0.pid, name: $0.name, value: String(format: "%.1f%%", $0.cpu * 100)) },
                      valueTitle: "CPU")
    }
}

// MARK: - GPU

private struct GPUModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        let g = r.gpu
        let unit = model.settings.stored.temperatureUnit
        let temp = r.sensors[.gpu]?.max
        let tint = Theme.violet
        Card {
            HStack(spacing: 14) {
                AnimatedRing(parts: [(g?.utilization ?? 0, tint)], center: g.map { MetricFormat.percent($0.utilization) } ?? "–", caption: "Usage")
                    .frame(width: 112, height: 112)
                ArcGauge(value: temp.map(temperatureGauge) ?? 0, label: temp.map { unit.format($0) } ?? "–", caption: "Temperature",
                         status: temperatureStatus(temp))
                    .frame(width: 112, height: 112)
            }
            .frame(maxWidth: .infinity)
        }
        Card {
            CardTitle(symbol: "chart.xyaxis.line", title: "Usage history", tint: tint, trailing: g.map { MetricFormat.percent($0.utilization) },
                      help: Help.gpuUsage)
            SmoothChart(series: [(model.gpuHistory, tint)], maxValue: 1)
        }
        Card(spacing: 6) {
            CardTitle(symbol: "info.circle", title: "Details", tint: .secondary)
            if let v = g?.renderer { LegendRow(color: nil, label: "Renderer", value: MetricFormat.percent(v)) }
            if let v = g?.tiler { LegendRow(color: nil, label: "Tiler", value: MetricFormat.percent(v)) }
            LegendRow(color: nil, label: "Power", value: r.componentPower?.gpu.map(formatWatts) ?? "–")
            if let m = g?.memoryInUse { LegendRow(color: nil, label: "Memory in use", value: ByteFormat.size(m)) }
            if let t = temp { LegendRow(color: nil, label: "Temperature", value: unit.format(t)) }
        }
    }
}

// MARK: - Memory

private struct MemoryModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        if let m = r.memory {
            let t = Float(max(m.total, 1))
            let parts: [(Float, Color)] = [(Float(m.app) / t, Theme.series1), (Float(m.wired) / t, Theme.series2), (Float(m.compressed) / t, Theme.series3)]
            let pressure = m.pressure == .normal ? 0.18 : m.pressure == .warning ? 0.55 : 0.88
            Card {
                HStack(spacing: 14) {
                    AnimatedRing(parts: parts, center: MetricFormat.percent(m.usedFraction), caption: ByteFormat.size(m.used))
                        .frame(width: 112, height: 112)
                    ArcGauge(value: pressure, label: m.pressure == .normal ? "Normal" : m.pressure == .warning ? "High" : "Critical",
                             caption: "Pressure", tint: Theme.aqua,
                             status: m.pressure == .normal ? nil : m.pressure == .warning ? Theme.warning : Theme.critical)
                        .frame(width: 112, height: 112)
                }
                .frame(maxWidth: .infinity)
            }
            Card {
                CardTitle(symbol: "chart.xyaxis.line", title: "Usage history", tint: MenuBarItem.memory.tint, trailing: MetricFormat.percent(m.usedFraction))
                SmoothChart(series: [(model.memoryHistory, Theme.magenta)], maxValue: 1)
            }
            Card(spacing: 6) {
                CardTitle(symbol: "memorychip", title: "Breakdown", tint: .secondary, trailing: "\(ByteFormat.size(m.used)) of \(ByteFormat.size(m.total))",
                          help: Help.memoryBreakdown)
                StackedMeter(parts: parts)
                LegendRow(color: Theme.series1, label: "App", value: ByteFormat.size(m.app))
                LegendRow(color: Theme.series2, label: "Wired", value: ByteFormat.size(m.wired))
                LegendRow(color: Theme.series3, label: "Compressed", value: ByteFormat.size(m.compressed))
                LegendRow(color: .secondary.opacity(0.35), label: "Free", value: ByteFormat.size(m.free))
                LegendRow(color: nil, label: "Cached files", value: ByteFormat.size(m.cached))
                LegendRow(color: nil, label: "Swap", value: "\(ByteFormat.size(m.swapUsed)) of \(ByteFormat.size(m.swapTotal))")
            }
            TopProcessesCard(rows: model.hub.processes.topByMemory.map { ProcessRow(pid: $0.pid, name: $0.name, value: ByteFormat.size($0.memory)) },
                          valueTitle: "Memory")
        } else {
            EmptyNote(text: "Measuring…")
        }
    }
}

// MARK: - Disk

private struct DiskModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        let tint = Theme.blue
        ForEach(SystemInfo.volumes()) { v in
            Card(spacing: 6) {
                CardTitle(symbol: v.isInternal ? "internaldrive.fill" : "externaldrive.fill", title: v.name, tint: tint,
                          trailing: MetricFormat.percent(v.usedFraction))
                GlassMeter(value: v.usedFraction, tint: v.usedFraction > 0.9 ? Theme.warning : tint)
                HStack {
                    Text("\(ByteFormat.size(UInt64(max(0, v.available)))) free")
                    Spacer()
                    Text("of \(ByteFormat.size(UInt64(max(0, v.capacity))))")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        Card {
            CardTitle(symbol: "chart.xyaxis.line", title: "Activity", tint: tint)
            HStack(spacing: 18) {
                BigNumber(caption: "Read", value: r.disk.map { ByteFormat.rate($0.read) } ?? "–")
                BigNumber(caption: "Write", value: r.disk.map { ByteFormat.rate($0.write) } ?? "–")
                Spacer()
            }
            SmoothChart(series: [(model.diskReadHistory, Theme.series1), (model.diskWriteHistory, Theme.series2)], maxValue: nil)
            Legend(items: [("Read", Theme.series1), ("Write", Theme.series2)])
        }
        TopProcessesCard(rows: model.hub.processes.topByDisk.map {
            ProcessRow(pid: $0.pid, name: $0.name, value: "\(ByteFormat.rate($0.diskRead)) · \(ByteFormat.rate($0.diskWrite))")
        }, valueTitle: "Read · Write")
    }
}

// MARK: - Network

private struct NetworkModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings
    @State private var publicIP: String?
    @State private var fetching = false

    var body: some View {
        let n = r.network
        Card {
            HStack(spacing: 18) {
                BigNumber(caption: "Download", value: n.map { ByteFormat.rate($0.download) } ?? "–", symbol: "arrow.down.circle.fill")
                BigNumber(caption: "Upload", value: n.map { ByteFormat.rate($0.upload) } ?? "–", symbol: "arrow.up.circle.fill")
                Spacer()
            }
            SmoothChart(series: [(model.downloadHistory, Theme.series1), (model.uploadHistory, Theme.series2)], maxValue: nil)
            Legend(items: [("Download", Theme.series1), ("Upload", Theme.series2)])
        }
        Card(spacing: 6) {
            let status = model.connectivity
            CardTitle(symbol: status?.connected == false ? "wifi.slash" : "wifi", title: "Connection", tint: MenuBarItem.network.tint,
                      trailing: status.map { $0.connected ? "Connected" : "Offline" })
            if let s = status, s.connected { LegendRow(color: nil, label: "Type", value: s.interfaceType + (s.expensive ? " (metered)" : "")) }
            if let n {
                // Only interfaces that actually have an address (en2/en3 are often idle bridge ports).
                let addressed = n.interfaces.map(SystemInfo.addresses(of:)).filter { $0.ipv4 != nil }.prefix(2)
                ForEach(Array(addressed), id: \.name) { a in
                    LegendRow(color: nil, label: "Local IP (\(a.name))", value: a.ipv4 ?? "")
                }
                LegendRow(color: nil, label: "Total download", value: ByteFormat.size(n.totalIn))
                LegendRow(color: nil, label: "Total upload", value: ByteFormat.size(n.totalOut))
            }
            HStack {
                Text("Public IP").foregroundStyle(.secondary)
                Spacer()
                if let ip = publicIP {
                    Text(ip).monospacedDigit().textSelection(.enabled)
                } else {
                    Button(fetching ? "Looking up…" : "Show") { fetchPublicIP() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(fetching)
                        .help("Asks api.ipify.org for your public address. Nothing is sent until you click.")
                }
            }
            .font(.system(size: 12.5))
        }
    }

    /// Only on request: this contacts an outside server.
    private func fetchPublicIP() {
        fetching = true
        Task {
            var ip = "Unavailable"
            if let url = URL(string: "https://api.ipify.org"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let s = String(data: data, encoding: .utf8), s.count < 64 {
                ip = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            publicIP = ip
            fetching = false
        }
    }
}

// MARK: - Sensors

private struct SensorsModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        let unit = model.settings.stored.temperatureUnit
        let groups = r.sensors.keys.filter { $0 != .other }.sorted()
        let cpu = r.sensors[.cpuPerformance]?.max
        Card {
            CardTitle(symbol: "thermometer.medium", title: "CPU temperature", tint: MenuBarItem.temperature.tint, trailing: cpu.map { unit.format($0) })
            SmoothChart(series: [(model.temperatureHistory(.cpuPerformance), Theme.orange)], maxValue: 110, minValue: 20)
        }
        Card(spacing: 7) {
            CardTitle(symbol: "sensor.fill", title: "Temperatures", tint: .secondary, help: Help.temperatures)
            if groups.isEmpty {
                // Sensors exist but haven't been read yet (first tick after opening) vs. none at all.
                EmptyNote(text: (model.hub.sensors?.availableGroups.isEmpty ?? true) ? "No temperature sensors found." : "Reading sensors…")
            }
            ForEach(groups, id: \.self) { g in
                if let v = r.sensors[g] {
                    HStack(spacing: 8) {
                        Text(sensorLabel(g)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        GlassMeter(value: Float(temperatureGauge(v.max)),
                                   tint: v.max >= 95 ? Theme.critical : v.max >= 85 ? Theme.warning : Theme.orange, height: 6)
                            .frame(width: 80)
                        Text(unit.format(v.max)).monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    .font(.system(size: 12.5))
                }
            }
        }
        if model.hub.fans != nil {   // fanless Macs (MacBook Air) get no Fans card at all
            Card(spacing: 6) {
                CardTitle(symbol: "fan.fill", title: "Fans", tint: .secondary)
                if r.fans.isEmpty {
                    Text("Reading fans…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(r.fans) { f in
                    HStack(spacing: 8) {
                        Text("Fan \(f.id + 1)").foregroundStyle(.secondary)
                        Spacer()
                        if let fr = f.fraction { GlassMeter(value: Float(fr), height: 6).frame(width: 80) }
                        Text("\(Int(f.rpm)) rpm").monospacedDigit()
                    }
                    .font(.system(size: 12.5))
                }
            }
        }
        if let p = r.systemPower {
            Card(spacing: 6) {
                CardTitle(symbol: "bolt.fill", title: "Power", tint: .yellow, trailing: formatWatts(p))
                LegendRow(color: nil, label: "GPU", value: r.componentPower?.gpu.map(formatWatts) ?? "–")
            }
        }
    }
}

// MARK: - Power

private struct PowerModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        let tint = Theme.yellow
        if let f = r.battery?.flow {
            Card {
                PowerFlowStrip(adapterWatts: Double(f.adapterIn) / 1000, systemWatts: Double(f.systemLoad) / 1000,
                               batteryWatts: Double(f.battery) / 1000, batteryPercent: r.battery?.percent ?? 0)
            }
        }
        Card {
            CardTitle(symbol: "bolt.fill", title: "Whole Mac", tint: tint, trailing: r.systemPower.map(formatWatts) ?? "–", help: Help.systemPower)
            SmoothChart(series: [(model.powerHistory, Theme.yellow)], maxValue: nil)
        }
        Card(spacing: 7) {
            let c = r.componentPower
            let helper = model.helperState == .running
            let total = max(r.systemPower ?? 1, 0.001)
            CardTitle(symbol: "square.stack.3d.up.fill", title: "Components", tint: .secondary, help: Help.componentPower)
            component("CPU", c?.cpu, total: total, missing: helper ? "–" : "needs helper", tint: Theme.blue)
            component("GPU", c?.gpu, total: total, missing: "–", tint: Theme.blue)
            component("Neural Engine", c?.ane, total: total, missing: helper ? "–" : "needs helper", tint: Theme.blue)
            component("Memory", c?.dram, total: total, missing: helper ? "–" : "needs helper", tint: Theme.blue)
        }
        TopProcessesCard(rows: model.hub.processes.topByPower.map { ProcessRow(pid: $0.pid, name: $0.name, value: formatWatts($0.watts)) },
                      valueTitle: "Power", symbol: "bolt.horizontal")
    }

    private func component(_ name: String, _ watts: Double?, total: Double, missing: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let watts { GlassMeter(value: Float(watts / total), tint: tint, height: 6).frame(width: 80) }
            Text(watts.map(formatWatts) ?? missing).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
        }
        .font(.system(size: 12.5))
    }
}

// MARK: - Battery (AlDente-style)

private struct BatteryModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        if let b = r.battery {
            let unit = model.settings.stored.temperatureUnit
            if let f = b.flow {
                Card {
                    PowerFlowStrip(adapterWatts: Double(f.adapterIn) / 1000, systemWatts: r.systemPower ?? Double(f.systemLoad) / 1000,
                                   batteryWatts: Double(f.battery) / 1000, batteryPercent: b.percent)
                }
            }
            Card { hero(b) }
            ChargeControlSection()
            Card {
                HStack(alignment: .bottom) {
                    BigNumber(caption: "Battery level", value: "\(b.percent) %")
                    HelpBadge(Help.batteryLevelChart)
                    Spacer()
                    let time = model.batteryTimeDisplay(b)
                    BigNumber(caption: time.caption, value: time.value, symbol: time.symbol)
                    HelpBadge(Help.timeRemaining)
                }
                SmoothChart(series: [(model.batteryLevelHistory, Theme.aqua)], maxValue: 100,
                            reference: model.settings.stored.chargeControlEnabled ? Float(model.settings.stored.chargePolicy.limit) : nil,
                            referenceColor: Theme.orange, capacity: 720)
                Text(model.batteryLevelHistory.count < 2 ? "Builds up while Ultstat runs (one point a minute)." : "Last \(historySpan)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            let batteryTemps = model.temperatureHistory(.battery)
            if let t = r.sensors[.battery]?.max {
                Card {
                    CardTitle(symbol: "flame.fill", title: "Battery temperature", tint: .orange, trailing: unit.format(t))
                    SmoothChart(series: [(batteryTemps, Theme.orange)], maxValue: nil, minValue: 20, height: 60)
                }
            }
            Card(spacing: 6) {
                CardTitle(symbol: "bolt.fill", title: "Battery specs", tint: .yellow)
                LegendRow(color: nil, label: "Current", value: String(format: "%.2f A", Double(b.amperage) / 1000))
                LegendRow(color: nil, label: "Voltage", value: String(format: "%.2f V", Double(b.voltage) / 1000))
                LegendRow(color: nil, label: "Power", value: formatWatts(b.watts))
                if let p = r.systemPower { LegendRow(color: nil, label: "System load", value: formatWatts(p)) }
                LegendRow(color: nil, label: "Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                if let rem = b.remainingCapacity { LegendRow(color: nil, label: "Battery charge", value: "\(rem) mAh") }
                if let hw = b.hardwarePercent { LegendRow(color: nil, label: "Hardware percentage", value: String(format: "%.1f %%", hw)) }
            }
            Card(spacing: 6) {
                CardTitle(symbol: "heart.fill", title: "Battery health", tint: .pink,
                          trailing: b.health.map { String(format: "%.0f %%", $0 * 100) }, help: Help.batteryHealth)
                LegendRow(color: nil, label: "Design capacity", value: "\(b.designCapacity) mAh")
                if let full = b.fullChargeCapacity, b.designCapacity > 0 {
                    LegendRow(color: nil, label: "Maximum capacity",
                              value: "\(full) mAh · " + String(format: "%.1f %%", Double(full) / Double(b.designCapacity) * 100))
                }
                if let h = b.health { LegendRow(color: nil, label: "Gauge health", value: String(format: "%.1f %%", h * 100)) }
                LegendRow(color: nil, label: "Cycle count", value: "\(b.cycleCount)")
            }
            Card(spacing: 6) {
                CardTitle(symbol: "powerplug.fill", title: "Power adapter", tint: .yellow)
                if let a = b.adapter, b.externalConnected {
                    if let n = a.name { LegendRow(color: nil, label: "Name", value: n) }
                    if let w = a.watts { LegendRow(color: nil, label: "Rated power", value: "\(w) W") }
                    if let v = a.voltage { LegendRow(color: nil, label: "Voltage", value: String(format: "%.1f V", Double(v) / 1000)) }
                    if let c = a.current { LegendRow(color: nil, label: "Current", value: "\(c) mA") }
                    if let m = a.manufacturer { LegendRow(color: nil, label: "Manufacturer", value: m) }
                } else {
                    Text("Not connected.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        } else {
            EmptyNote(text: "This Mac has no battery.")
        }
    }

    private var historySpan: String {
        let m = model.batteryLevelHistory.count - 1
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
    }

    private func hero(_ b: BatterySnapshot) -> some View {
        HStack(spacing: 14) {
            BatteryGlyph(percent: b.percent, charging: b.isCharging, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                .frame(width: 78, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(b.percent)%").font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                Text(stateText(b)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.green)
                Text(BatteryTime.short(b)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func stateText(_ b: BatterySnapshot) -> String {
        if let mode = model.chargeStatus?.mode, model.settings.stored.chargeControlEnabled, model.helperReady {
            switch mode {
            case .holding: return "Paused at limit"
            case .sailing: return "Sailing"
            case .discharging: return "Discharging to limit"
            case .heatPaused: return "Paused: battery warm"
            case .toppingUp: return "Topping up to 100%"
            case .calibrating: return "Calibrating"
            case .frozen: return "Paused"
            case .charging, .onBattery: break
            }
        }
        if b.isCharging { return "Charging" }
        if b.externalConnected { return b.amperage < -50 ? "Discharging (adapter bypassed)" : "On power adapter" }
        return "On battery"
    }
}

/// AlDente's controls: limit, top up, discharge, calibration, sailing, heat protection.
private struct ChargeControlSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmCalibration = false

    var body: some View {
        let p = model.settings.stored.chargePolicy
        let ready = model.helperReady
        let unit = model.settings.stored.temperatureUnit
        Card {
            CardTitle(symbol: "battery.100percent.bolt", title: "Charge limit", tint: .green, help: Help.limit)
            if model.settings.stored.chargeControlEnabled, model.otherChargeControllerRunning {
                Label {
                    HStack(spacing: 4) { Text("AlDente is also running"); HelpBadge(Help.otherController) }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            if !ready {
                HStack {
                    Text(model.helperNeedsUpdate ? "The charge helper needs updating for this version."
                                                 : "Install the helper to control charging.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    if model.installing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(model.helperNeedsUpdate ? "Update" : "Install") { model.installHelper() }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("battery.install")
                    }
                }
                if let e = model.helperError { Text(e).font(.system(size: 11)).foregroundStyle(Theme.critical) }
            }
            HStack {
                Toggle(isOn: Binding(get: { model.settings.stored.chargeControlEnabled }, set: { model.setChargeControl($0) })) {
                    HelpLabel("Limit", help: Help.limit)
                }
                    .toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("battery.limitToggle")
                Spacer()
                HelpBadge(Help.limitLevel)
                Text("\(p.limit)%").font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(p.limit) }, set: { v in model.updatePolicy { $0.limit = Int(v) } }), in: 20...100, step: 1)
                .controlSize(.small)
                .tint(.green)
                .accessibilityIdentifier("battery.limitSlider")
            HStack(spacing: 8) {
                actionButton("Top Up", "bolt.fill", active: p.topUp, help: Help.topUp) { model.updatePolicy { $0.topUp.toggle() } }
                actionButton("Discharge", "arrow.down.to.line", active: p.dischargeAboveLimit, help: Help.discharge) {
                    model.updatePolicy { $0.dischargeAboveLimit.toggle() }
                }
                actionButton("Calibrate", "arrow.triangle.2.circlepath", active: p.calibration != nil, help: Help.calibrate) {
                    // Starting asks first (it runs for hours); stopping is immediate.
                    if p.calibration == nil { confirmCalibration = true } else { model.toggleCalibration() }
                }
            }
            if confirmCalibration {
                // Inline, not a dialog: sheets don't attach reliably to this borderless panel.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start calibration? It runs for many hours: discharges to 15 %, charges to 100 %, holds an hour, "
                         + "then returns to your limit. Keep the Mac plugged in.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Start Calibration") {
                            confirmCalibration = false
                            model.toggleCalibration()
                        }
                        .buttonStyle(.glassProminent)
                        Button("Cancel") { confirmCalibration = false }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let progress = model.calibrationProgress(percent: model.panelReadings.battery?.percent) {
                Text(progress).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Toggle(isOn: Binding(get: { p.sailingRange > 0 }, set: { on in model.updatePolicy { $0.sailingRange = on ? 5 : 0 } })) {
                    HelpLabel("Sailing", help: Help.sailing)
                }
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                if p.sailingRange > 0 {
                    Stepper("\(p.sailingRange)%", value: Binding(get: { p.sailingRange }, set: { v in model.updatePolicy { $0.sailingRange = v } }), in: 1...20)
                        .font(.system(size: 12)).monospacedDigit()
                }
            }
            HStack {
                Toggle(isOn: Binding(get: { p.heatProtection != nil },
                                     set: { on in model.updatePolicy { $0.heatProtection = on ? 40 : nil } })) {
                    HelpLabel("Heat protection", help: Help.heat)
                }
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                if let h = p.heatProtection {
                    Stepper("\(unit.format(Float(h)))\(unit == .celsius ? "C" : "F")",
                            value: Binding(get: { Int(h) }, set: { v in model.updatePolicy { $0.heatProtection = Double(v) } }), in: 30...50)
                        .font(.system(size: 12)).monospacedDigit()
                }
            }
            if !ready, model.settings.stored.chargeControlEnabled {
                Text("Your choices are saved and apply as soon as the helper is ready.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12.5))
    }

    private func actionButton(_ title: String, _ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                    .symbolEffect(.bounce, value: active)
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(active ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(Motion.animation, value: active)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { HelpBadge(help).padding(5) }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Small components

/// Per-core vertical bars (performance cores in blue, efficiency in amber) that grow smoothly.
struct CoreBars: View {
    var load: CPULoad
    var kinds: [CPUTopology.Kind]

    var body: some View {
        VStack(spacing: 5) {
            // Stats' layout: a 50 pt box with a faint background and 2 pt inset around the columns.
            BarsLayer(values: load.perCore,
                      colors: load.perCore.indices.map { $0 < kinds.count && kinds[$0] == .performance ? Theme.series1 : Theme.series2 })
                .frame(height: 46)
                .padding(2)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Legend(items: [(CPUTopology.performanceName, Theme.series1), (CPUTopology.efficiencyName, Theme.series2)])
        }
    }
}

/// iOS-style battery: coloured pill with the percentage inside, translucent remainder and cap.
struct BatteryGlyph: View {
    var percent: Int
    var charging: Bool
    var lowPower: Bool

    var body: some View {
        GeometryReader { geo in
            let capW = geo.size.width * 0.06
            let bodyW = max(0, geo.size.width - capW - 2)   // GeometryReader first lays out at zero width
            let level = CGFloat(min(max(percent, 0), 100)) / 100
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: geo.size.height * 0.3, style: .continuous).fill(.secondary.opacity(0.35))
                    RoundedRectangle(cornerRadius: geo.size.height * 0.3, style: .continuous).fill(fill)
                        .frame(width: max(geo.size.height * 0.4, bodyW * level))
                    HStack(spacing: 1) {
                        if charging { Image(systemName: "bolt.fill").font(.system(size: geo.size.height * 0.42, weight: .bold)) }
                        Text("\(percent)").font(.system(size: geo.size.height * 0.55, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: bodyW)
                }
                .frame(width: bodyW)
                RoundedRectangle(cornerRadius: capW / 2).fill(.secondary.opacity(0.45))
                    .frame(width: capW, height: geo.size.height * 0.36)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(percent) percent\(charging ? ", charging" : "")")
    }

    private var fill: Color {
        if charging { return Color(red: 0.20, green: 0.80, blue: 0.35) }
        if lowPower { return Color(red: 1.0, green: 0.80, blue: 0.0) }
        if percent <= 20 { return Color(red: 1.0, green: 0.27, blue: 0.23) }
        return .white
    }
}

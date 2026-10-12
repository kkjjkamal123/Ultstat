import AppKit
import SwiftUI
import UltstatCore
import UltstatKit

enum ModulePanelSize {
    static let width: CGFloat = 340
}

/// The panel for one menu-bar item, laid out like Stats (system modules) and AlDente (battery):
/// dashboards, history, sectioned details, top processes. Only the clicked module is built.
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
        .padding(14)
        .frame(width: ModulePanelSize.width)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .focusEffectDisabled()
    }

    private func body(_ r: Readings) -> some View {
        VStack(spacing: 9) { content(r) }.frame(maxWidth: .infinity).padding(.bottom, 2)
    }

    private var header: some View {
        ZStack {
            Text(title).font(.system(size: 16, weight: .semibold))
            HStack {
                Button("All metrics", systemImage: "square.grid.2x2") { model.openFullDashboard() }
                    .help("All metrics")
                    .accessibilityIdentifier("module.dashboard")
                Spacer()
                Button("Settings", systemImage: "gearshape") { model.openSettings() }
                    .help("Settings (⌘,)")
                    .accessibilityIdentifier("module.settings")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch item {
        case .memory: "RAM"
        case .temperature: "Sensors"
        default: item.title
        }
    }

    @ViewBuilder private func content(_ r: Readings) -> some View {
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

func formatWatts(_ w: Double) -> String { w < 1 ? String(format: "%.0f mW", w * 1000) : String(format: "%.2f W", w) }

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

/// Temperature as a 0...1 gauge position (30 °C … 100 °C).
func temperatureGauge(_ c: Float) -> Double { Double(min(max((c - 30) / 70, 0), 1)) }

// MARK: - CPU

private struct CPUModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        let c = r.cpu ?? .zero
        let unit = model.settings.stored.temperatureUnit
        let temp = r.sensors[.cpuPerformance]?.max
        HStack(spacing: 20) {
            RingChart(parts: [(c.system, Theme.series2), (c.user, Theme.series1)], center: MetricFormat.percent(c.total))
                .frame(width: 104, height: 104)
            PressureGauge(value: temp.map(temperatureGauge) ?? 0, label: temp.map { unit.format($0) } ?? "–")
        }
        SectionHeader(title: "Usage history")
        HistoryChart(series: [(model.cpuHistory, Theme.series1)], maxValue: 1)
        if !c.perCore.isEmpty {
            SectionHeader(title: "Cores")
            CoreBars(load: c, kinds: model.hub.cpu.topology.kinds)
        }
        SectionHeader(title: "Details")
        LegendRow(color: Theme.series2, label: "System", value: MetricFormat.percent(c.system))
        LegendRow(color: Theme.series1, label: "User", value: MetricFormat.percent(c.user))
        LegendRow(color: .secondary.opacity(0.35), label: "Idle", value: MetricFormat.percent(max(0, 1 - c.total)))
        if let p = c.performance { LegendRow(color: nil, label: "\(CPUTopology.performanceName) cores", value: MetricFormat.percent(p)) }
        if let e = c.efficiency { LegendRow(color: nil, label: "\(CPUTopology.efficiencyName) cores", value: MetricFormat.percent(e)) }
        if let l = SystemInfo.loadAverage() {
            LegendRow(color: nil, label: "Average load", value: String(format: "%.2f  %.2f  %.2f", l.0, l.1, l.2))
        }
        if let w = r.componentPower?.cpu { LegendRow(color: nil, label: "Power", value: formatWatts(w)) }
        LegendRow(color: nil, label: "Uptime", value: formatDuration(SystemInfo.uptime()))
        SectionHeader(title: "Top processes")
        ProcessTable(rows: model.hub.processes.topByCPU.map { ProcessRow(pid: $0.pid, name: $0.name, value: String(format: "%.1f%%", $0.cpu * 100)) },
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
        HStack(spacing: 20) {
            RingChart(parts: [(g?.utilization ?? 0, Theme.series1)], center: g.map { MetricFormat.percent($0.utilization) } ?? "–")
                .frame(width: 104, height: 104)
            PressureGauge(value: temp.map(temperatureGauge) ?? 0, label: temp.map { unit.format($0) } ?? "–")
        }
        SectionHeader(title: "Usage history")
        HistoryChart(series: [(model.gpuHistory, Theme.series1)], maxValue: 1)
        SectionHeader(title: "Details")
        LegendRow(color: Theme.series1, label: "Utilization", value: g.map { MetricFormat.percent($0.utilization) } ?? "–")
        if let v = g?.renderer { LegendRow(color: nil, label: "Renderer utilization", value: MetricFormat.percent(v)) }
        if let v = g?.tiler { LegendRow(color: nil, label: "Tiler utilization", value: MetricFormat.percent(v)) }
        if let w = r.componentPower?.gpu { LegendRow(color: nil, label: "Power", value: formatWatts(w)) }
        if let m = g?.memoryInUse { LegendRow(color: nil, label: "Memory in use", value: ByteFormat.size(m)) }
        if let t = temp { LegendRow(color: nil, label: "Temperature", value: unit.format(t)) }
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
            HStack(spacing: 20) {
                PressureGauge(value: m.pressure == .normal ? 0.18 : m.pressure == .warning ? 0.55 : 0.88,
                              label: m.pressure == .normal ? "Normal" : m.pressure == .warning ? "Warning" : "Critical")
                RingChart(parts: parts, center: MetricFormat.percent(m.usedFraction)).frame(width: 104, height: 104)
            }
            SectionHeader(title: "Usage history")
            HistoryChart(series: [(model.memoryHistory, Theme.series1)], maxValue: 1)
            SectionHeader(title: "Details")
            LegendRow(color: nil, label: "Used", value: ByteFormat.size(m.used))
            StackedMeter(parts: parts)
            LegendRow(color: Theme.series1, label: "App", value: ByteFormat.size(m.app))
            LegendRow(color: Theme.series2, label: "Wired", value: ByteFormat.size(m.wired))
            LegendRow(color: Theme.series3, label: "Compressed", value: ByteFormat.size(m.compressed))
            LegendRow(color: .secondary.opacity(0.35), label: "Free", value: ByteFormat.size(m.free))
            LegendRow(color: nil, label: "Cached files", value: ByteFormat.size(m.cached))
            LegendRow(color: nil, label: "Swap", value: "\(ByteFormat.size(m.swapUsed)) of \(ByteFormat.size(m.swapTotal))")
            SectionHeader(title: "Top processes")
            ProcessTable(rows: model.hub.processes.topByMemory.map { ProcessRow(pid: $0.pid, name: $0.name, value: ByteFormat.size($0.memory)) },
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
        let volumes = SystemInfo.volumes()
        SectionHeader(title: "Drives")
        ForEach(volumes) { v in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: v.isInternal ? "internaldrive" : "externaldrive").foregroundStyle(.secondary)
                    Text(v.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(MetricFormat.percent(v.usedFraction)).font(.system(size: 12.5)).monospacedDigit()
                }
                Meter(value: v.usedFraction, tint: v.usedFraction > 0.9 ? Theme.warning : Theme.series1)
                HStack {
                    Text("\(ByteFormat.size(UInt64(max(0, v.available)))) free").foregroundStyle(.secondary)
                    Spacer()
                    Text("of \(ByteFormat.size(UInt64(max(0, v.capacity))))").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            .padding(9)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        SectionHeader(title: "Activity")
        HistoryChart(series: [(model.diskReadHistory, Theme.series1), (model.diskWriteHistory, Theme.series2)], maxValue: nil, height: 70)
        Legend(items: [("Read", Theme.series1), ("Write", Theme.series2)])
        if let d = r.disk {
            LegendRow(color: Theme.series1, label: "Read", value: ByteFormat.rate(d.read))
            LegendRow(color: Theme.series2, label: "Write", value: ByteFormat.rate(d.write))
        }
        SectionHeader(title: "Top processes")
        ProcessTable(rows: model.hub.processes.topByDisk.map {
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
        HStack(spacing: 34) {
            BigStat(title: "Downloading", value: n.map { ByteFormat.rate($0.download) } ?? "–", color: Theme.series1)
            BigStat(title: "Uploading", value: n.map { ByteFormat.rate($0.upload) } ?? "–", color: Theme.series2)
        }
        SectionHeader(title: "Usage history")
        HistoryChart(series: [(model.downloadHistory, Theme.series1), (model.uploadHistory, Theme.series2)], maxValue: nil)
        Legend(items: [("Download", Theme.series1), ("Upload", Theme.series2)])
        SectionHeader(title: "Details")
        let status = model.connectivity
        LegendRow(color: nil, label: "Status", value: status.map { $0.connected ? "Connected" : "Offline" } ?? "–")
        if let s = status, s.connected { LegendRow(color: nil, label: "Connection", value: s.interfaceType + (s.expensive ? " (metered)" : "")) }
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
                    .controlSize(.small)
                    .disabled(fetching)
                    .help("Asks api.ipify.org for your public address. Nothing is sent until you click.")
            }
        }
        .font(.system(size: 12.5))
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
        SectionHeader(title: "CPU temperature")
        HistoryChart(series: [(model.temperatureHistory(.cpuPerformance), Theme.series1)], maxValue: 110)
        SectionHeader(title: "Temperatures")
        if groups.isEmpty { EmptyNote(text: "No temperature sensors found.") }
        ForEach(groups, id: \.self) { g in
            if let v = r.sensors[g] {
                HStack(spacing: 8) {
                    Text(sensorLabel(g)).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Meter(value: Float(temperatureGauge(v.max)), tint: v.max >= 95 ? Theme.critical : v.max >= 85 ? Theme.warning : Theme.series1)
                        .frame(width: 70)
                    Text(unit.format(v.max)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 12.5))
            }
        }
        if let p = r.systemPower {
            SectionHeader(title: "Power")
            LegendRow(color: nil, label: "Whole Mac", value: formatWatts(p))
            if let g = r.componentPower?.gpu { LegendRow(color: nil, label: "GPU", value: formatWatts(g)) }
        }
        SectionHeader(title: "Fans")
        if r.fans.isEmpty {
            Text("This Mac has no fans.").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(r.fans) { f in
            HStack(spacing: 8) {
                Text("Fan \(f.id + 1)").foregroundStyle(.secondary)
                Spacer()
                if let fr = f.fraction { Meter(value: Float(fr)).frame(width: 70) }
                Text("\(Int(f.rpm)) rpm").monospacedDigit()
            }
            .font(.system(size: 12.5))
        }
    }
}

// MARK: - Power

private struct PowerModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        BigStat(title: "Whole Mac", value: r.systemPower.map { String(format: "%.2f W", $0) } ?? "–", color: Theme.series1)
        SectionHeader(title: "Power history")
        HistoryChart(series: [(model.powerHistory, Theme.series1)], maxValue: nil)
        SectionHeader(title: "Components")
        let c = r.componentPower
        let helper = model.helperState == .running
        LegendRow(color: nil, label: "CPU", value: c?.cpu.map(formatWatts) ?? (helper ? "–" : "needs helper"))
        LegendRow(color: nil, label: "GPU", value: c?.gpu.map(formatWatts) ?? "–")
        LegendRow(color: nil, label: "Neural Engine", value: c?.ane.map(formatWatts) ?? (helper ? "–" : "needs helper"))
        LegendRow(color: nil, label: "Memory", value: c?.dram.map(formatWatts) ?? (helper ? "–" : "needs helper"))
        if let f = r.battery?.flow {
            SectionHeader(title: "Power flow")
            PowerFlowView(flow: f)
        }
        SectionHeader(title: "Top energy users")
        ProcessTable(rows: model.hub.processes.topByPower.map { ProcessRow(pid: $0.pid, name: $0.name, value: formatWatts($0.watts)) },
                     valueTitle: "Power")
    }
}

// MARK: - Battery (AlDente-style)

private struct BatteryModule: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        if let b = r.battery {
            hero(b)
            ChargeControlSection()
            if let f = b.flow {
                SectionHeader(title: "Power flow")
                PowerFlowView(flow: f)
                SectionHeader(title: "Power consumption")
                HistoryChart(series: [(model.powerFlowHistory, Theme.series1)], maxValue: nil, height: 60)
            }
            SectionHeader(title: "Battery health")
            if let h = b.health { LegendRow(color: nil, label: "Maximum capacity", value: String(format: "%.1f%%", h * 100)) }
            if let full = b.fullChargeCapacity, b.designCapacity > 0 {
                LegendRow(color: nil, label: "macOS capacity", value: String(format: "%.1f%%", Double(full) / Double(b.designCapacity) * 100))
            }
            LegendRow(color: nil, label: "Cycles", value: "\(b.cycleCount)")
            if let t = r.sensors[.battery]?.max { LegendRow(color: nil, label: "Temperature", value: model.settings.stored.temperatureUnit.format(t)) }
            LegendRow(color: nil, label: "Voltage", value: String(format: "%.2f V", Double(b.voltage) / 1000))
            LegendRow(color: nil, label: "Current", value: "\(b.amperage) mA")
            LegendRow(color: nil, label: "Power", value: String(format: "%.2f W", b.watts))
            if let hw = b.hardwarePercent { LegendRow(color: nil, label: "Hardware percentage", value: String(format: "%.1f%%", hw)) }
            if let full = b.fullChargeCapacity { LegendRow(color: nil, label: "Full charge capacity", value: "\(full) mAh") }
            LegendRow(color: nil, label: "Design capacity", value: "\(b.designCapacity) mAh")
            if let a = b.adapter, b.externalConnected {
                SectionHeader(title: "Power adapter")
                if let n = a.name { LegendRow(color: nil, label: "Name", value: n) }
                if let w = a.watts { LegendRow(color: nil, label: "Power", value: "\(w) W") }
                if let v = a.voltage { LegendRow(color: nil, label: "Voltage", value: String(format: "%.1f V", Double(v) / 1000)) }
                if let c = a.current { LegendRow(color: nil, label: "Current", value: "\(c) mA") }
                if let m = a.manufacturer { LegendRow(color: nil, label: "Manufacturer", value: m) }
            }
        } else {
            EmptyNote(text: "This Mac has no battery.")
        }
    }

    private func hero(_ b: BatterySnapshot) -> some View {
        HStack(spacing: 14) {
            BatteryGlyph(percent: b.percent, charging: b.isCharging, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                .frame(width: 84, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(b.percent)%").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(BatteryTime.short(b)).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(stateText(b)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.series1)
            }
            Spacer()
        }
    }

    private func stateText(_ b: BatterySnapshot) -> String {
        if let mode = model.chargeStatus?.mode, model.settings.stored.chargeControlEnabled {
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

    var body: some View {
        let p = model.settings.stored.chargePolicy
        let ready = model.helperReady
        SectionHeader(title: "Charge limit")
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
                        .controlSize(.small).accessibilityIdentifier("battery.install")
                }
            }
            if let e = model.helperError { Text(e).font(.system(size: 11)).foregroundStyle(Theme.critical) }
        }
        Group {
            HStack {
                Toggle("Limit", isOn: Binding(get: { model.settings.stored.chargeControlEnabled }, set: { model.setChargeControl($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("battery.limitToggle")
                Spacer()
                Text("\(p.limit)%").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(p.limit) }, set: { v in model.updatePolicy { $0.limit = Int(v) } }), in: 20...100, step: 1)
                .controlSize(.small)
                .accessibilityIdentifier("battery.limitSlider")
            HStack(spacing: 8) {
                actionButton("Top Up", "bolt.fill", active: p.topUp) { model.updatePolicy { $0.topUp.toggle() } }
                actionButton("Discharge", "arrow.down.to.line", active: p.dischargeAboveLimit) { model.updatePolicy { $0.dischargeAboveLimit.toggle() } }
                actionButton("Calibrate", "arrow.triangle.2.circlepath", active: p.calibration != nil) {
                    model.updatePolicy { $0.calibration = $0.calibration == nil ? .discharging : nil }
                }
            }
            HStack {
                Toggle("Sailing", isOn: Binding(get: { p.sailingRange > 0 }, set: { on in model.updatePolicy { $0.sailingRange = on ? 5 : 0 } }))
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                if p.sailingRange > 0 {
                    Stepper("\(p.sailingRange)%", value: Binding(get: { p.sailingRange }, set: { v in model.updatePolicy { $0.sailingRange = v } }), in: 1...20)
                        .font(.system(size: 12)).monospacedDigit()
                }
            }
            HStack {
                Toggle("Heat protection", isOn: Binding(get: { p.heatProtection != nil },
                                                        set: { on in model.updatePolicy { $0.heatProtection = on ? 40 : nil } }))
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                if let h = p.heatProtection {
                    let unit = model.settings.stored.temperatureUnit
                    Stepper("\(unit.format(Float(h)))\(unit == .celsius ? "C" : "F")",
                            value: Binding(get: { Int(h) }, set: { v in model.updatePolicy { $0.heatProtection = Double(v) } }), in: 30...50)
                        .font(.system(size: 12)).monospacedDigit()
                }
            }
        }
        .font(.system(size: 12.5))
        if !ready, model.settings.stored.chargeControlEnabled {
            Text("Your choices are saved and apply as soon as the helper is ready.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }

    private func actionButton(_ title: String, _ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(active ? AnyShapeStyle(Theme.series1) : AnyShapeStyle(.fill.tertiary), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Small components

struct BigStat: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Capsule().fill(color).frame(width: 24, height: 3)
        }
    }
}

/// Per-core vertical bars, performance cores in the brand colour.
struct CoreBars: View {
    var load: CPULoad
    var kinds: [CPUTopology.Kind]

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(load.perCore.enumerated()), id: \.offset) { i, v in
                    let perf = i < kinds.count && kinds[i] == .performance
                    UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5)
                        .fill(perf ? Theme.series1 : Theme.series2)
                        .frame(height: max(2, 40 * CGFloat(v)))
                        .frame(maxHeight: 40, alignment: .bottom)
                }
            }
            .frame(height: 40)
            .padding(6)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

import SwiftUI
import UltstatCore
import UltstatKit

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let r = model.readings
        VStack(spacing: 8) {
            header
            ScrollView {
                VStack(spacing: 8) {
                    cpuCard(r)
                    HStack(alignment: .top, spacing: 8) {
                        memoryCard(r)
                        gpuCard(r)
                    }
                    networkCard(r)
                    diskCard(r)
                    if !r.sensors.isEmpty { sensorsCard(r) }
                    if let b = r.battery { BatteryCard(b: b, systemPower: r.systemPower) }
                    if !r.fans.isEmpty { fansCard(r) }
                    if !r.accessories.isEmpty { accessoriesCard(r) }
                    ProcessesCard()
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: r)
            }
            .scrollIndicators(.never)
            footer
        }
        .padding(10)
        .frame(width: 340, height: 600)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Ultstat").font(.system(size: 13, weight: .bold, design: .rounded))
            Spacer()
            SystemStatePill()
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack {
            Button("Settings", systemImage: "gearshape") { model.openSettings() }
                .accessibilityIdentifier("dashboard.settings")
            Spacer()
            Text(Host.current().localizedName ?? "")
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer()
            Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                .accessibilityIdentifier("dashboard.quit")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .font(.system(size: 13))
        .padding(.horizontal, 4)
    }

    // MARK: Cards

    private func cpuCard(_ r: Readings) -> some View {
        let c = r.cpu ?? .zero
        let kinds = model.hub.cpu.topology.kinds
        return MetricCard(title: "CPU", symbol: "cpu", value: MetricFormat.percent(c.total)) {
            Sparkline(values: model.cpuHistory, maxValue: 1).frame(height: 34)
            if !c.perCore.isEmpty {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(c.perCore.enumerated()), id: \.offset) { i, v in
                        let perf = i < kinds.count && kinds[i] == .performance
                        UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                            .fill(perf ? Theme.series1 : Theme.series2)
                            .frame(height: max(2, 22 * CGFloat(v)))
                            .frame(maxHeight: 22, alignment: .bottom)
                    }
                }
                .frame(height: 22)
                .accessibilityLabel("Per-core load")
                Legend(items: [(CPUTopology.performanceName, Theme.series1), (CPUTopology.efficiencyName, Theme.series2)])
            }
            HStack(spacing: 12) {
                StatRow(label: "User", value: MetricFormat.percent(c.user))
                StatRow(label: "System", value: MetricFormat.percent(c.system))
            }
            if let p = c.performance, let e = c.efficiency {
                HStack(spacing: 12) {
                    StatRow(label: CPUTopology.performanceName, value: MetricFormat.percent(p))
                    StatRow(label: CPUTopology.efficiencyName, value: MetricFormat.percent(e))
                }
            }
        }
    }

    private func memoryCard(_ r: Readings) -> some View {
        let m = r.memory
        let pressureStatus: Color? = switch m?.pressure {
        case .warning: Theme.warning
        case .critical: Theme.critical
        default: nil
        }
        return MetricCard(title: "Memory", symbol: "memorychip", value: m.map { MetricFormat.percent($0.usedFraction) } ?? "–", status: pressureStatus) {
            if let m {
                let t = Float(max(m.total, 1))
                StackedMeter(parts: [(Float(m.app) / t, Theme.series1), (Float(m.wired) / t, Theme.series2), (Float(m.compressed) / t, Theme.series3)])
                Legend(items: [("App", Theme.series1), ("Wired", Theme.series2), ("Compr.", Theme.series3)])
                StatRow(label: "Used", value: ByteFormat.size(m.used))
                StatRow(label: "Swap", value: ByteFormat.size(m.swapUsed))
                StatRow(label: "Pressure", value: m.pressure == .normal ? "Normal" : m.pressure == .warning ? "Warning" : "Critical")
            }
        }
    }

    private func gpuCard(_ r: Readings) -> some View {
        MetricCard(title: "GPU", symbol: "rectangle.3.group", value: r.gpu.map { MetricFormat.percent($0.utilization) } ?? "–") {
            Sparkline(values: model.gpuHistory, maxValue: 1).frame(height: 30)
            if let rnd = r.gpu?.renderer { StatRow(label: "Renderer", value: MetricFormat.percent(rnd)) }
            if let t = r.gpu?.tiler { StatRow(label: "Tiler", value: MetricFormat.percent(t)) }
            if let w = r.componentPower?.gpu { StatRow(label: "Power", value: w < 1 ? String(format: "%.0f mW", w * 1000) : String(format: "%.2f W", w)) }
        }
    }

    private func networkCard(_ r: Readings) -> some View {
        let n = r.network
        let down = model.downloadHistory, up = model.uploadHistory
        // One scale for both series, so a bigger rate always draws higher.
        let top = max(down.max() ?? 0, up.max() ?? 0, 1_000)
        return MetricCard(title: "Network", symbol: "arrow.up.arrow.down", value: n.map { "↓ " + ByteFormat.rate($0.download) } ?? "–") {
            ZStack {
                Sparkline(values: down, maxValue: top, tint: Theme.series1)
                Sparkline(values: up, maxValue: top, tint: Theme.series2, filled: false)
            }
            .frame(height: 32)
            Legend(items: [("Download", Theme.series1), ("Upload", Theme.series2)])
            if let n {
                HStack(spacing: 12) {
                    StatRow(label: "Upload", value: ByteFormat.rate(n.upload))
                    StatRow(label: "Total ↓", value: ByteFormat.size(n.totalIn))
                }
            }
        }
    }

    private func diskCard(_ r: Readings) -> some View {
        let d = r.disk
        let full = (d?.usedFraction ?? 0) > 0.9
        return MetricCard(title: "Disk", symbol: "internaldrive", value: d.map { MetricFormat.percent($0.usedFraction) } ?? "–",
                          status: full ? Theme.warning : nil) {
            if let d {
                Meter(value: d.usedFraction, tint: full ? Theme.warning : Theme.series1)
                HStack(spacing: 12) {
                    StatRow(label: "Read", value: ByteFormat.rate(d.read))
                    StatRow(label: "Write", value: ByteFormat.rate(d.write))
                }
                StatRow(label: "Free", value: ByteFormat.size(d.available))
            }
        }
    }

    private func fansCard(_ r: Readings) -> some View {
        MetricCard(title: r.fans.count == 1 ? "Fan" : "Fans", symbol: "fan", value: r.fans.map { "\(Int($0.rpm))" }.joined(separator: " · ") + " rpm") {
            ForEach(r.fans) { f in
                if let fr = f.fraction { Meter(value: Float(fr)) }
            }
        }
    }

    private func accessoriesCard(_ r: Readings) -> some View {
        MetricCard(title: "Accessories", symbol: "keyboard", value: "") {
            ForEach(r.accessories) { a in
                let low = a.percent <= 15
                HStack {
                    Text(a.component.map { "\(a.name) (\($0))" } ?? a.name).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if low { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
                    Text("\(a.percent)%").monospacedDigit()
                }
                .font(.system(size: 11))
            }
        }
    }

    private func sensorLabel(_ g: SensorGroup) -> String {
        switch g {
        case .cpuPerformance: "CPU \(CPUTopology.performanceName)"
        case .cpuEfficiency: "CPU \(CPUTopology.efficiencyName)"
        default: g.displayName
        }
    }

    private func sensorsCard(_ r: Readings) -> some View {
        let unit = model.settings.stored.temperatureUnit
        let hottest = r.sensors.values.map(\.max).max() ?? 0
        let status: Color? = hottest >= 95 ? Theme.critical : hottest >= 85 ? Theme.warning : nil
        return MetricCard(title: "Temperatures", symbol: "thermometer.medium", value: unit.format(hottest), status: status) {
            Sparkline(values: model.temperatureHistory(.cpuPerformance), maxValue: 110).frame(height: 26)
            ForEach(r.sensors.keys.sorted(), id: \.self) { g in
                if let v = r.sensors[g] {
                    StatRow(label: sensorLabel(g),
                            value: "\(unit.format(v.max))  avg \(unit.format(v.average))")
                }
            }
        }
    }
}

/// Thermal pressure and Low Power Mode, read from ProcessInfo (no sampling).
struct SystemStatePill: View {
    @State private var thermal = ProcessInfo.processInfo.thermalState
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        HStack(spacing: 6) {
            if lowPower {
                Label("Low Power", systemImage: "leaf.fill").foregroundStyle(Theme.warning)
            }
            Label(thermalText, systemImage: "thermometer.variable")
                .foregroundStyle(thermal == .nominal ? AnyShapeStyle(.secondary) : AnyShapeStyle(thermal == .critical ? Theme.critical : Theme.warning))
        }
        .font(.system(size: 10, weight: .medium))
        .labelStyle(.titleAndIcon)
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private var thermalText: String {
        switch thermal {
        case .nominal: "Thermal: Nominal"
        case .fair: "Thermal: Fair"
        case .serious: "Thermal: Serious"
        case .critical: "Thermal: Critical"
        @unknown default: "Thermal"
        }
    }
}

struct BatteryCard: View {
    @Environment(AppModel.self) private var model
    var b: BatterySnapshot
    var systemPower: Double?

    var body: some View {
        let status: Color? = b.externalConnected ? nil : b.percent <= 10 ? Theme.critical : b.percent <= 20 ? Theme.warning : nil
        MetricCard(title: "Battery", symbol: MenuBarRenderer.batterySymbol(b), value: "\(b.percent)%", status: status) {
            Meter(value: Float(b.percent) / 100, tint: status ?? Theme.series1)
            if let f = b.flow { PowerFlowView(flow: f) }
            StatRow(label: "State", value: stateText)
            if let hw = b.hardwarePercent { StatRow(label: "Gauge charge", value: String(format: "%.1f%%", hw)) }
            if let h = b.health { StatRow(label: "Health", value: String(format: "%.1f%% · %d cycles", h * 100, b.cycleCount)) }
            if let a = b.adapter, b.externalConnected {
                StatRow(label: "Adapter", value: "\(a.name ?? "Charger") · \(a.watts ?? 0) W")
            }
            ChargeLimitQuickControl()
        }
    }

    private var calibrationText: String {
        switch model.settings.stored.chargePolicy.calibration {
        case .discharging: "Calibrating: discharging to 15%"
        case .charging: "Calibrating: charging to 100%"
        case .holding(let until): "Calibrating: holding until \(until.formatted(date: .omitted, time: .shortened))"
        case nil: "Calibrating"
        }
    }

    private var stateText: String {
        if let mode = model.chargeStatus?.mode, model.settings.stored.chargeControlEnabled, b.externalConnected {
            switch mode {
            case .holding: return "Paused at limit"
            case .sailing: return "Sailing"
            case .discharging: return "Discharging to limit"
            case .heatPaused: return "Paused: battery warm"
            case .toppingUp: return "Topping up"
            case .calibrating: return calibrationText
            case .charging, .onBattery: break
            }
        }
        if b.isCharging { return b.minutesToFull.map { "Charging · \($0 / 60)h \($0 % 60)m left" } ?? "Charging" }
        if b.externalConnected { return "On adapter, not charging" }
        return b.minutesToEmpty.map { "On battery · \($0 / 60)h \($0 % 60)m left" } ?? "On battery"
    }
}

/// Adapter → Mac ← Battery, in watts.
struct PowerFlowView: View {
    var flow: PowerFlow

    var body: some View {
        HStack(spacing: 6) {
            node("powerplug", watts(flow.adapterIn), active: flow.adapterIn > 300)
            arrow(active: flow.adapterIn > 300)
            node("laptopcomputer", watts(flow.systemLoad), active: true)
            // Charging: Mac → battery. Discharging: battery → Mac.
            arrow(active: abs(flow.battery) > 100, pointsLeft: flow.battery < 0)
            node(flow.battery > 0 ? "battery.100percent.bolt" : "battery.75percent", watts(abs(flow.battery)), active: abs(flow.battery) > 100)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Adapter \(watts(flow.adapterIn)), system \(watts(flow.systemLoad)), battery \(watts(flow.battery))")
    }

    private func watts(_ mw: Int) -> String { String(format: "%.1f W", Double(mw) / 1000) }

    private func node(_ symbol: String, _ value: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 14)).symbolRenderingMode(.hierarchical)
            Text(value).font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(active ? .primary : .tertiary)
        .frame(maxWidth: .infinity)
    }

    private func arrow(active: Bool, pointsLeft: Bool = false) -> some View {
        Image(systemName: pointsLeft ? "arrow.left" : "arrow.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(active ? Theme.series1 : Color.secondary.opacity(0.3))
    }
}

/// Inline charge-limit control shown on the battery card.
struct ChargeLimitQuickControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let enabled = model.settings.stored.chargeControlEnabled
        HStack {
            Toggle("Limit", isOn: Binding(get: { enabled }, set: { model.setChargeControl($0) }))
                .toggleStyle(.switch).controlSize(.mini)
                .disabled(model.helperState != .running)
                .accessibilityIdentifier("battery.limitToggle")
            Spacer()
            if model.helperState != .running {
                Button("Set up") { model.openSettings() }.controlSize(.small)
            } else {
                Stepper("\(model.settings.stored.chargePolicy.limit)%",
                        value: Binding(get: { model.settings.stored.chargePolicy.limit },
                                       set: { v in model.updatePolicy { $0.limit = v } }),
                        in: ChargePolicy.limitRange, step: 5)
                    .font(.system(size: 11)).monospacedDigit()
                    .disabled(!enabled)
                    .accessibilityIdentifier("battery.limitStepper")
            }
        }
    }
}

/// Top processes by CPU, memory or measured power. Data exists only while the popover is open.
struct ProcessesCard: View {
    @Environment(AppModel.self) private var model
    @State private var order: Order = .cpu

    enum Order: String, CaseIterable, Identifiable {
        case cpu = "CPU", memory = "Memory", power = "Power"
        var id: String { rawValue }
    }

    /// Reading `readings.processes` subscribes this view to every tick; the orderings come from the sampler.
    private var rows: [ProcessUsage] {
        _ = model.readings.processes
        return switch order {
        case .cpu: model.hub.processes.topByCPU
        case .memory: model.hub.processes.topByMemory
        case .power: model.hub.processes.topByPower
        }
    }

    var body: some View {
        let rows = rows
        MetricCard(title: "Processes", symbol: "list.bullet.rectangle", value: "") {
            Picker("Order", selection: $order) {
                ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("processes.order")
            if rows.isEmpty {
                Text("Measuring…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(rows.prefix(6)) { p in
                StatRow(label: p.name, value: value(p))
            }
            if order == .power {
                Text("Measured energy of your apps; system processes are not visible without root.")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private func value(_ p: ProcessUsage) -> String {
        switch order {
        case .cpu: String(format: "%.1f%%", p.cpu * 100)
        case .memory: ByteFormat.size(p.memory)
        case .power:
            if p.watts < 0.1 { String(format: "%.0f mW", p.watts * 1000) } else { String(format: "%.2f W", p.watts) }
        }
    }
}

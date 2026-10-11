import SwiftUI
import UltstatCore

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
        HStack {
            Text("Ultstat").font(.system(size: 13, weight: .bold, design: .rounded))
            Spacer()
            Text(Host.current().localizedName ?? "")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack {
            Button("Settings", systemImage: "gearshape") { model.openSettings() }
                .accessibilityIdentifier("dashboard.settings")
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
        return MetricCard(title: "CPU", symbol: "cpu", value: MetricFormat.percent(c.total), tint: .blue) {
            Sparkline(values: model.cpuHistory, maxValue: 1, tint: .blue).frame(height: 36)
            if !c.perCore.isEmpty {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(c.perCore.enumerated()), id: \.offset) { i, v in
                        let perf = i < model.hub.cpu.topology.kinds.count && model.hub.cpu.topology.kinds[i] == .performance
                        RoundedRectangle(cornerRadius: 2)
                            .fill((perf ? Color.blue : Color.teal).gradient)
                            .frame(height: max(2, 22 * CGFloat(v)))
                            .frame(maxHeight: 22, alignment: .bottom)
                    }
                }
                .frame(height: 22)
                .accessibilityLabel("Per-core load")
            }
            HStack(spacing: 12) {
                StatRow(label: "User", value: MetricFormat.percent(c.user))
                StatRow(label: "System", value: MetricFormat.percent(c.system))
            }
            if let p = c.performance, let e = c.efficiency {
                HStack(spacing: 12) {
                    StatRow(label: "P-cores", value: MetricFormat.percent(p))
                    StatRow(label: "E-cores", value: MetricFormat.percent(e))
                }
            }
        }
    }

    private func memoryCard(_ r: Readings) -> some View {
        let m = r.memory
        return MetricCard(title: "Memory", symbol: "memorychip", value: m.map { MetricFormat.percent($0.usedFraction) } ?? "–", tint: .purple) {
            if let m {
                let t = Float(max(m.total, 1))
                StackedMeter(parts: [(Float(m.app) / t, .purple), (Float(m.wired) / t, .orange), (Float(m.compressed) / t, .pink)])
                StatRow(label: "Used", value: ByteFormat.size(m.used))
                StatRow(label: "Swap", value: ByteFormat.size(m.swapUsed))
                StatRow(label: "Pressure", value: m.pressure == .normal ? "Normal" : m.pressure == .warning ? "Warning" : "Critical")
            }
        }
    }

    private func gpuCard(_ r: Readings) -> some View {
        MetricCard(title: "GPU", symbol: "rectangle.3.group", value: r.gpu.map { MetricFormat.percent($0.utilization) } ?? "–", tint: .green) {
            Sparkline(values: model.gpuHistory, maxValue: 1, tint: .green).frame(height: 30)
            if let rnd = r.gpu?.renderer { StatRow(label: "Renderer", value: MetricFormat.percent(rnd)) }
        }
    }

    private func networkCard(_ r: Readings) -> some View {
        let n = r.network
        return MetricCard(title: "Network", symbol: "arrow.up.arrow.down", value: n.map { "↓ " + ByteFormat.rate($0.download) } ?? "–", tint: .cyan) {
            ZStack {
                Sparkline(values: model.downloadHistory, tint: .cyan)
                Sparkline(values: model.uploadHistory, tint: .orange)
            }
            .frame(height: 32)
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
        return MetricCard(title: "Disk", symbol: "internaldrive", value: d.map { MetricFormat.percent($0.usedFraction) } ?? "–", tint: .indigo) {
            if let d {
                Meter(value: d.usedFraction, tint: .indigo)
                HStack(spacing: 12) {
                    StatRow(label: "Read", value: ByteFormat.rate(d.read))
                    StatRow(label: "Write", value: ByteFormat.rate(d.write))
                }
                StatRow(label: "Free", value: ByteFormat.size(d.available))
            }
        }
    }

    private func sensorsCard(_ r: Readings) -> some View {
        let unit = model.settings.stored.temperatureUnit
        let hottest = r.sensors.values.map(\.max).max() ?? 0
        return MetricCard(title: "Temperatures", symbol: "thermometer.medium", value: unit.format(hottest), tint: hottest > 85 ? .red : .orange) {
            ForEach(r.sensors.keys.sorted(), id: \.self) { g in
                if let v = r.sensors[g] {
                    StatRow(label: g.displayName, value: "\(unit.format(v.max))  avg \(unit.format(v.average))")
                }
            }
        }
    }
}

struct BatteryCard: View {
    @Environment(AppModel.self) private var model
    var b: BatterySnapshot
    var systemPower: Double?

    var body: some View {
        MetricCard(title: "Battery", symbol: MenuBarRenderer.batterySymbol(b), value: "\(b.percent)%", tint: b.percent <= 20 ? .red : .green) {
            Meter(value: Float(b.percent) / 100, tint: b.percent <= 20 ? .red : .green)
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

    private var stateText: String {
        if let mode = model.chargeStatus?.mode, model.settings.stored.chargeControlEnabled, b.externalConnected {
            switch mode {
            case .holding: return "Paused at limit"
            case .sailing: return "Sailing"
            case .discharging: return "Discharging to limit"
            case .heatPaused: return "Paused: battery warm"
            case .toppingUp: return "Topping up"
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
            Text(value).font(.system(size: 10, weight: .medium)).monospacedDigit().contentTransition(.numericText())
        }
        .foregroundStyle(active ? .primary : .tertiary)
        .frame(maxWidth: .infinity)
    }

    private func arrow(active: Bool, pointsLeft: Bool = false) -> some View {
        Image(systemName: pointsLeft ? "arrow.left" : "arrow.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.3))
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

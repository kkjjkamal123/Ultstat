import SwiftUI
import UltstatCore
import UltstatKit

/// Keeps detailed sampling running while a window page that shows live data is on screen
/// (the same reference count the menu-bar panels use).
struct LiveDetail: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onAppear { model.popoverOpened() }
            .onDisappear { model.popoverClosed() }
    }
}

/// A module's cards laid out in columns for the wide window.
struct WindowModulePage: View {
    @Environment(AppModel.self) private var model
    var item: MenuBarItem

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ModuleContent(item: item, r: model.panelReadings)
            }
            .padding(20)
        }
        .modifier(LiveDetail())
    }
}

/// AlDente-style overview: power flow across the top, battery/adapter cards, history charts,
/// energy users and calibration.
struct SettingsDashboard: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 225), spacing: 14, alignment: .top)]

    var body: some View {
        let r = model.panelReadings
        ScrollView {
            VStack(spacing: 14) {
                PowerBanner(r: r)
                if let b = r.battery {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        specs(b, r)
                        health(b)
                        adapter(b)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        levelCard(b, r)
                        temperatureCard(r)
                        VStack(spacing: 14) {
                            energyApps
                            calibration
                        }
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    consumptionCard(r)
                    usageCard("CPU", "cpu", value: r.cpu.map { MetricFormat.percent($0.total) }, history: model.cpuHistory, tint: Theme.blue)
                    usageCard("Memory", "memorychip", value: r.memory.map { MetricFormat.percent($0.usedFraction) },
                              history: model.memoryHistory, tint: Theme.magenta)
                }
            }
            .padding(20)
        }
        .modifier(LiveDetail())
    }

    // MARK: Cards

    private func specs(_ b: BatterySnapshot, _ r: Readings) -> some View {
        Card(spacing: 6) {
            CardTitle(symbol: "bolt.fill", title: "Battery Specs", tint: .yellow)
            LegendRow(color: nil, label: "Current", value: String(format: "%.2f A", Double(b.amperage) / 1000))
            LegendRow(color: nil, label: "Voltage", value: String(format: "%.2f V", Double(b.voltage) / 1000))
            LegendRow(color: nil, label: "Power", value: String(format: "%.2f W", b.watts))
            if let p = r.systemPower { LegendRow(color: nil, label: "System load", value: String(format: "%.2f W", p)) }
            LegendRow(color: nil, label: "Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "Enabled" : "Off")
            if let rem = b.remainingCapacity { LegendRow(color: nil, label: "Battery charge", value: "\(rem) mAh") }
        }
    }

    private func health(_ b: BatterySnapshot) -> some View {
        Card(spacing: 6) {
            CardTitle(symbol: "heart.fill", title: "Battery Health", tint: .pink)
            LegendRow(color: nil, label: "Design capacity", value: "\(b.designCapacity) mAh · 100 %")
            if let full = b.fullChargeCapacity, b.designCapacity > 0 {
                LegendRow(color: nil, label: "Maximum capacity",
                          value: "\(full) mAh · " + String(format: "%.0f %%", Double(full) / Double(b.designCapacity) * 100))
            }
            if let h = b.health { LegendRow(color: nil, label: "Gauge health", value: String(format: "%.1f %%", h * 100)) }
            LegendRow(color: nil, label: "Cycle count", value: "\(b.cycleCount)")
            if let hw = b.hardwarePercent { LegendRow(color: nil, label: "Hardware charge", value: String(format: "%.1f %%", hw)) }
        }
    }

    private func adapter(_ b: BatterySnapshot) -> some View {
        Card(spacing: 6) {
            CardTitle(symbol: "powerplug.fill", title: "Power Adapter Specs", tint: .yellow)
            if let a = b.adapter, b.externalConnected {
                if let n = a.name { LegendRow(color: nil, label: "Name", value: n) }
                if let w = a.watts { LegendRow(color: nil, label: "Rated power", value: "\(w) W") }
                if let v = a.voltage { LegendRow(color: nil, label: "Voltage", value: String(format: "%.1f V", Double(v) / 1000)) }
                if let c = a.current { LegendRow(color: nil, label: "Current", value: String(format: "%.2f A", Double(c) / 1000)) }
                if let m = a.manufacturer { LegendRow(color: nil, label: "Manufacturer", value: m) }
            } else {
                Text("Power adapter specs are not available while on battery.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func levelCard(_ b: BatterySnapshot, _ r: Readings) -> some View {
        Card {
            HStack(alignment: .bottom) {
                BigNumber(caption: "Battery level", value: "\(b.percent) %")
                Spacer()
                if b.isCharging {
                    BigNumber(caption: "Time to full", value: BatteryTime.minutes(b).map { BatteryTime.format(minutes: $0.minutes) } ?? "--",
                              symbol: "clock")
                } else {
                    BigNumber(caption: "Time remaining", value: remaining(b, r), symbol: "clock")
                }
            }
            SmoothChart(series: [(model.batteryLevelHistory, Theme.aqua)], maxValue: 100,
                        reference: model.settings.stored.chargeControlEnabled ? Float(model.settings.stored.chargePolicy.limit) : nil,
                        referenceColor: Theme.orange, height: 150)
            Text(model.batteryLevelHistory.count < 2 ? "Builds up while Ultstat runs (one point a minute)." : "Dashed line: your charge limit")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func temperatureCard(_ r: Readings) -> some View {
        let unit = model.settings.stored.temperatureUnit
        return Card {
            BigNumber(caption: "Battery temperature", value: r.sensors[.battery].map { unit.format($0.max) } ?? "–", symbol: "flame")
            SmoothChart(series: [(model.temperatureHistory(.battery), Theme.orange)], maxValue: nil, minValue: 20, height: 150)
        }
    }

    private var energyApps: some View {
        Card(spacing: 6) {
            CardTitle(symbol: "bolt.horizontal.fill", title: "Apps using significant energy", tint: .orange)
            let top = model.hub.processes.topByPower.filter { $0.watts >= 0.1 }.prefix(5)
            if top.isEmpty {
                Text("No apps using significant energy").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ProcessTable(rows: top.map { ProcessRow(pid: $0.pid, name: $0.name, value: formatWatts($0.watts)) }, valueTitle: "Power")
            }
        }
    }

    private var calibration: some View {
        let p = model.settings.stored.chargePolicy
        let running = p.calibration != nil
        return Card(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(running ? "Calibrating" : "Calibration").font(.system(size: 13, weight: .semibold))
                    Text("Discharges to 15 %, charges to 100 %, holds an hour, then returns to your limit.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(running ? "Stop Calibration" : "Start Calibration", systemImage: running ? "stop.fill" : "play.fill") {
                    model.updatePolicy { $0.calibration = $0.calibration == nil ? .discharging : nil }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help(running ? "Stop calibration" : "Start calibration")
            }
        }
    }

    private func consumptionCard(_ r: Readings) -> some View {
        Card {
            HStack(alignment: .bottom) {
                BigNumber(caption: "Power consumption", value: r.systemPower.map { String(format: "%.2f W", $0) } ?? "–", symbol: "bolt")
                Spacer()
                if let b = r.battery {
                    BigNumber(caption: "Time remaining", value: remaining(b, r), symbol: "clock")
                }
            }
            SmoothChart(series: [(model.powerHistory, Theme.yellow)], maxValue: nil, height: 110)
        }
    }

    private func usageCard(_ title: String, _ symbol: String, value: String?, history: [Float], tint: Color) -> some View {
        Card {
            BigNumber(caption: "\(title) usage", value: value ?? "–", symbol: symbol)
            SmoothChart(series: [(history, tint)], maxValue: 1, height: 110)
        }
    }

    /// Battery time left: macOS's estimate on battery, or how long it would last at the current load.
    private func remaining(_ b: BatterySnapshot, _ r: Readings) -> String {
        if let (m, toFull) = BatteryTime.minutes(b), !toFull { return BatteryTime.format(minutes: m) }
        return BatteryTime.minutesAtCurrentLoad(b, systemWatts: r.systemPower).map(BatteryTime.format(minutes:)) ?? "--"
    }
}

/// Top banner: where the power goes (adapter → Mac → battery), as in AlDente.
private struct PowerBanner: View {
    @Environment(AppModel.self) private var model
    var r: Readings

    var body: some View {
        let f = r.battery?.flow
        let adapter = Double(f?.adapterIn ?? 0) / 1000
        let battery = Double(f?.battery ?? 0) / 1000
        let system = r.systemPower ?? Double(f?.systemLoad ?? 0) / 1000
        let c = r.componentPower
        let soc = [c?.cpu, c?.gpu, c?.ane, c?.dram].compactMap { $0 }.reduce(0, +)
        Card(spacing: 14) {
            HStack(spacing: 0) {
                chip("powerplug.fill", "Power Adapter", adapter, .yellow)
                divider
                chip("laptopcomputer", "MacBook", system, Theme.blue)
                divider
                chip("battery.100percent", "Battery", battery, .green, signed: true)
                if soc > 0 {
                    divider
                    chip("cpu", "SoC", soc, .orange)
                    divider
                    chip("ellipsis", "Other", max(0, system - soc), .secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                node("powerplug.fill", active: adapter > 0.3)
                flowBar(adapter, max: max(adapter, system, 1), tint: .yellow)
                node("laptopcomputer", active: true)
                flowBar(abs(battery) > 0.3 ? abs(battery) : system, max: max(adapter, system, 1), tint: abs(battery) > 0.3 ? .green : Theme.blue,
                        label: abs(battery) > 0.3 ? (battery > 0 ? "Charging" : "From battery") : "System")
                node("battery.100percent", active: abs(battery) > 0.3)
            }
            .frame(height: 70)
        }
    }

    private var divider: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 12) }

    private func chip(_ symbol: String, _ title: String, _ watts: Double, _ tint: Color, signed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).foregroundStyle(.secondary)
            Text((signed && watts < -0.05 ? "−" : "") + watt(abs(watts))).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
    }

    private func watt(_ w: Double) -> String { w < 1 ? "< 1 W" : String(format: "%.1f W", w) }

    private func node(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: 52)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func flowBar(_ watts: Double, max top: Double, tint: Color, label: String? = nil) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05))
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.08), tint.opacity(0.45)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(1, Swift.max(0.04, watts / top))))
            }
            VStack(spacing: 1) {
                Text(String(format: "%.2f W", watts)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                if let label { Text(label).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
    }
}

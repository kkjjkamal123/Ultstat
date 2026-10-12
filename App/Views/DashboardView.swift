import SwiftUI
import UltstatCore
import UltstatKit

enum DashboardTab: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, network, disk, sensors, power, battery, processes

    var id: String { rawValue }

    /// The module panel this tab shows (processes has its own view).
    var item: MenuBarItem? {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .disk: .disk
        case .sensors: .temperature
        case .power: .power
        case .battery: .battery
        case .processes: nil
        }
    }

    init(_ item: MenuBarItem) {
        self = Self.allCases.first { $0.item == item } ?? .cpu
    }

    var title: String { item.map { $0 == .temperature ? "Sensors" : $0.title } ?? "Processes" }
    var symbol: String { item?.symbol ?? "list.bullet.rectangle" }
}

/// All metrics: a summary of every key number, then one tab of detail using the same cards as the
/// single-metric panels. Opened from the combined menu-bar item or a panel's header. Only the
/// selected tab's views exist, which keeps opening fast.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DashboardView.tabKey) private var tab: DashboardTab = .cpu

    static let tabKey = "dashboard.tab"

    var body: some View {
        let r = model.panelReadings
        VStack(spacing: 10) {
            header
            SummaryGrid(r: r, selected: tab, select: { tab = $0 })
            TabStrip(selection: $tab)
            ScrollView {
                VStack(spacing: 8) { tabContent(r) }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusEffectDisabled()   // the panel behind is Liquid Glass (DashboardPanel)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Ultstat").font(.system(size: 15, weight: .bold))
                SystemStatePill()
            }
            Spacer()
            Group {
                Button("Settings", systemImage: "gearshape") { model.openSettings() }
                    .accessibilityIdentifier("dashboard.settings")
                    .help("Settings (⌘,)")
                Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                    .accessibilityIdentifier("dashboard.quit")
                    .help("Quit Ultstat")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
        }
    }

    @ViewBuilder private func tabContent(_ r: Readings) -> some View {
        if let item = tab.item {
            ModuleContent(item: item, r: r)
            if item == .battery, !r.accessories.isEmpty { accessoriesCard(r) }
        } else {
            ProcessesCard()
        }
    }

    private func accessoriesCard(_ r: Readings) -> some View {
        Card(spacing: 6) {
            CardTitle(symbol: "headphones", title: "Accessories", tint: .secondary)
            ForEach(r.accessories) { a in
                HStack {
                    Text(a.component.map { "\(a.name) (\($0))" } ?? a.name).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if a.percent <= 15 { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
                    GlassMeter(value: Float(a.percent) / 100, tint: Theme.aqua, height: 6).frame(width: 60)
                    Text("\(a.percent)%").monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                .font(.system(size: 12.5))
            }
        }
    }
}

/// Low Power Mode and thermal state, as a small line under the app name.
struct SystemStatePill: View {
    @State private var thermal = ProcessInfo.processInfo.thermalState
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        HStack(spacing: 8) {
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

/// Top processes by CPU, memory or energy, with app icons.
struct ProcessesCard: View {
    @Environment(AppModel.self) private var model
    @State private var order: Order = .cpu

    enum Order: String, CaseIterable, Identifiable {
        case cpu = "CPU", memory = "Memory", power = "Power", disk = "Disk"
        var id: String { rawValue }
    }

    /// Reading `panelReadings` subscribes this view to every tick; the orderings come from the sampler.
    private var rows: [ProcessUsage] {
        _ = model.panelReadings.processes
        return switch order {
        case .cpu: model.hub.processes.topByCPU
        case .memory: model.hub.processes.topByMemory
        case .power: model.hub.processes.topByPower
        case .disk: model.hub.processes.topByDisk
        }
    }

    var body: some View {
        Card {
            CardTitle(symbol: "list.bullet.rectangle", title: "Processes", tint: .secondary)
            Picker("Order", selection: $order) {
                ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("processes.order")
            ProcessTable(rows: rows.map { ProcessRow(pid: $0.pid, name: $0.name, value: value($0)) }, valueTitle: order.rawValue)
            if order == .power {
                Text("Measured energy of your apps; system processes are not visible without root.")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
        }
    }

    private func value(_ p: ProcessUsage) -> String {
        switch order {
        case .cpu: String(format: "%.1f%%", p.cpu * 100)
        case .memory: ByteFormat.size(p.memory)
        case .power: formatWatts(p.watts)
        case .disk: "\(ByteFormat.rate(p.diskRead)) · \(ByteFormat.rate(p.diskWrite))"
        }
    }
}

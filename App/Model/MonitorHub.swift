import AppKit
import Synchronization
import UltstatCore
import UltstatKit

/// Owns every sampler and turns "what is on screen" into scheduler demand.
///
/// Nothing is sampled unless a menu-bar item or the open popover shows it. The popover adds
/// detail demand (per-core CPU, all sensor groups, live power flow) only while it is visible.
@MainActor
final class MonitorHub {
    let scheduler: Scheduler
    let cpu: CPUSampler
    let memory: MemorySampler
    let network: NetworkSampler
    let disk: DiskSampler
    let gpu: GPUSampler?
    let sensors: SensorSampler?
    let battery: BatteryMonitor?
    let processes: ProcessSampler
    let energy: EnergySampler?
    let fans: FanSampler?
    private(set) var accessories: AccessorySampler
    private let bus: ReadingsBus
    private let power: PowerSampler?
    private let smc: SMC?

    private var menuTokens: [MenuBarItem: [DemandToken]] = [:]
    private var detailTokens: [DemandToken] = []
    private var detailVisible = false
    private var menuItems: Set<MenuBarItem> = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(bus: ReadingsBus, interval: Int, bluetoothAccessories: Bool) {
        self.bus = bus
        scheduler = Scheduler(configuration: .init(interval: .seconds(interval), leewayFraction: 0.25))
        cpu = CPUSampler { v in bus.update { $0.cpu = v } }
        memory = MemorySampler { v in bus.update { $0.memory = v } }
        network = NetworkSampler { v in bus.update { $0.network = v } }
        disk = DiskSampler { v in bus.update { $0.disk = v } }
        gpu = GPUSampler { v in bus.update { $0.gpu = v } }
        smc = try? SMC()
        if let smc {
            let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("io.github.kkjjkamal23.Ultstat/sensors.plist")
            let catalog = SensorCatalog.load(smc: smc, cacheURL: cacheURL)
            sensors = SensorSampler(smc: smc, catalog: catalog) { v in bus.update { $0.sensors = v } }
            power = PowerSampler(smc: smc) { w in bus.update { $0.systemPower = w } }
            fans = FanSampler(smc: smc) { v in bus.update { $0.fans = v } }
        } else {
            sensors = nil
            power = nil
            fans = nil
        }
        accessories = AccessorySampler(cadence: 15, includeBluetooth: bluetoothAccessories) { v in bus.update { $0.accessories = v } }
        processes = ProcessSampler { v in bus.update { $0.processes = v } }
        energy = EnergySampler(privileged: false) { v in
            bus.update { r in
                var c = r.componentPower ?? ComponentPower(cpu: nil, gpu: nil, ane: nil, dram: nil)
                c.gpu = v.gpu   // the app can only see GPU energy; CPU/ANE/DRAM come from the helper
                r.componentPower = c
            }
        }
        battery = BatteryMonitor { v in bus.update { $0.battery = v } }
        battery?.start()
        observeSystemState()
    }

    // MARK: Demand

    func setMenuItems(_ items: Set<MenuBarItem>) {
        guard items != menuItems else { return }
        for removed in menuItems.subtracting(items) { menuTokens[removed] = nil }
        for added in items.subtracting(menuItems) { menuTokens[added] = tokens(for: added) }
        menuItems = items
        updateSensorGroups()
    }

    func setDetailVisible(_ visible: Bool) {
        guard visible != detailVisible else { return }
        detailVisible = visible
        cpu.setPerCore(visible)
        if visible {
            detailTokens = MenuBarItem.allCases.flatMap { tokens(for: $0) }
            if let battery { detailTokens.append(scheduler.demand(battery)) }
            detailTokens.append(scheduler.demand(processes))
            if let energy { detailTokens.append(scheduler.demand(energy)) }
            if let fans { detailTokens.append(scheduler.demand(fans)) }
            detailTokens.append(scheduler.demand(accessories))
        } else {
            detailTokens = []
        }
        updateSensorGroups()
    }

    /// Rebuilds the accessory sampler when the Bluetooth (earbuds) option changes.
    func setBluetoothAccessories(_ on: Bool) {
        guard on != accessories.includeBluetooth else { return }
        let bus = self.bus
        accessories = AccessorySampler(cadence: 15, includeBluetooth: on) { v in bus.update { $0.accessories = v } }
        if detailVisible {
            setDetailVisible(false)
            setDetailVisible(true)
        }
    }

    func setInterval(_ seconds: Int) {
        scheduler.setInterval(.seconds(max(1, seconds)))
    }

    private func tokens(for item: MenuBarItem) -> [DemandToken] {
        switch item {
        case .cpu: [scheduler.demand(cpu)]
        case .gpu: gpu.map { [scheduler.demand($0)] } ?? []
        case .memory: [scheduler.demand(memory)]
        case .network: [scheduler.demand(network)]
        case .disk: [scheduler.demand(disk)]
        case .temperature: sensors.map { [scheduler.demand($0)] } ?? []
        case .power: power.map { [scheduler.demand($0)] } ?? []
        case .battery: []   // event-driven; no polling needed for the menu bar
        }
    }

    private func updateSensorGroups() {
        guard let sensors else { return }
        if detailVisible {
            sensors.setEnabled(Set(sensors.availableGroups))
        } else if menuItems.contains(.temperature) {
            sensors.setEnabled([.cpuPerformance, .cpuEfficiency])
        } else {
            sensors.setEnabled([])
        }
    }

    // MARK: System state → suspend/resume

    private func observeSystemState() {
        let nc = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Notification.Name, Scheduler.SuspendReason)] = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaysAsleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive),
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .systemSleep),
        ]
        for (off, on, reason) in pairs {
            workspaceObservers.append(nc.addObserver(forName: off, object: nil, queue: nil) { [scheduler] _ in scheduler.suspend(reason) })
            workspaceObservers.append(nc.addObserver(forName: on, object: nil, queue: nil) { [scheduler] _ in scheduler.resume(reason) })
        }
    }
}

/// Total system power from the SMC (`PSTR`, watts). One coprocessor read per sample.
final class PowerSampler: Sampler {
    let cadence = 2
    private let smc: SMC
    private let onUpdate: @Sendable (Double) -> Void
    private let key: SMCKey

    init?(smc: SMC, onUpdate: @escaping @Sendable (Double) -> Void) {
        guard smc.info("PSTR") != nil else { return nil }
        self.smc = smc
        self.onUpdate = onUpdate
        key = "PSTR"
    }

    func sample(tick: UInt64) {
        if let w = smc.double(key), w.isFinite, w >= 0 { onUpdate(w) }
    }
}

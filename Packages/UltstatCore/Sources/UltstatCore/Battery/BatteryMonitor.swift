import Foundation
import IOKit
import Synchronization

public struct PowerFlow: Sendable, Equatable {
    /// Milliwatts. Positive `battery` means charging, negative means discharging.
    public var adapterIn: Int
    public var systemLoad: Int
    public var battery: Int
    public var adapterLoss: Int
}

public struct AdapterInfo: Sendable, Equatable {
    public var name: String?
    public var watts: Int?
    public var voltage: Int?   // mV
    public var current: Int?   // mA
    public var isWireless: Bool
}

public struct BatterySnapshot: Sendable, Equatable {
    /// The percentage macOS shows.
    public var percent: Int
    /// Charge measured by the gauge: remaining ÷ full-charge capacity. macOS rounds and smooths
    /// its own figure, so this can differ by a few points.
    public var hardwarePercent: Double?
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    public var amperage: Int          // mA, negative while discharging
    public var voltage: Int           // mV
    public var cycleCount: Int
    public var designCapacity: Int    // mAh
    public var fullChargeCapacity: Int?
    public var nominalChargeCapacity: Int?
    public var remainingCapacity: Int?
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var notChargingReason: Int?
    public var adapter: AdapterInfo?
    public var flow: PowerFlow?

    public init(percent: Int, hardwarePercent: Double?, isCharging: Bool, externalConnected: Bool, fullyCharged: Bool,
                amperage: Int, voltage: Int, cycleCount: Int, designCapacity: Int, fullChargeCapacity: Int?,
                nominalChargeCapacity: Int?, remainingCapacity: Int?, minutesToEmpty: Int?, minutesToFull: Int?,
                notChargingReason: Int?, adapter: AdapterInfo?, flow: PowerFlow?) {
        self.percent = percent
        self.hardwarePercent = hardwarePercent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.amperage = amperage
        self.voltage = voltage
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.nominalChargeCapacity = nominalChargeCapacity
        self.remainingCapacity = remainingCapacity
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.notChargingReason = notChargingReason
        self.adapter = adapter
        self.flow = flow
    }

    /// Nominal ÷ design capacity, the basis of macOS's "Maximum Capacity" (capped at 100 % there).
    public var health: Double? {
        guard designCapacity > 0, let n = nominalChargeCapacity else { return nil }
        return Double(n) / Double(designCapacity)
    }

    public var watts: Double { Double(amperage) * Double(voltage) / 1_000_000 }
}

/// Battery state, pushed by IOKit instead of polled.
///
/// `start()` registers a `kIOGeneralInterest` notification on `AppleSmartBattery`; the gauge posts
/// one whenever its readings refresh or a charger is attached/removed. Each notification costs one
/// selective property read (~80 µs). Live power flow for an open display is a separate ~12 µs read
/// via `sample(tick:)`, which runs only while demanded through the `Scheduler`.
public final class BatteryMonitor: Sampler, @unchecked Sendable {
    public let cadence: Int
    private let service: io_service_t
    private let queue = DispatchQueue(label: "ultstat.battery", qos: .utility)
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    private struct State {
        var latest: BatterySnapshot?
        var flowHistory = RingBuffer(capacity: 180)
    }

    private let state = Mutex(State())
    private let onUpdate: @Sendable (BatterySnapshot) -> Void

    public init?(cadence: Int = 2, onUpdate: @escaping @Sendable (BatterySnapshot) -> Void = { _ in }) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != IO_OBJECT_NULL else { return nil }   // desktop Macs
        service = svc
        self.cadence = cadence
        self.onUpdate = onUpdate
    }

    deinit {
        stop()
        IOObjectRelease(service)
    }

    public var latest: BatterySnapshot? { state.withLock { $0.latest } }
    public var flowHistory: RingBuffer { state.withLock { $0.flowHistory } }

    /// Begins event delivery and publishes one snapshot immediately.
    public func start() {
        queue.sync {
            guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
            IONotificationPortSetDispatchQueue(p, queue)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let kr = IOServiceAddInterestNotification(p, service, kIOGeneralInterest, { refcon, _, _, _ in
                guard let refcon else { return }
                Unmanaged<BatteryMonitor>.fromOpaque(refcon).takeUnretainedValue().refresh()
            }, refcon, &notifier)
            guard kr == KERN_SUCCESS else {
                IONotificationPortDestroy(p)
                return
            }
            port = p
        }
        queue.async { [weak self] in self?.refresh() }
    }

    public func stop() {
        queue.sync {
            if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
            if let p = port { IONotificationPortDestroy(p); port = nil }
        }
    }

    /// Re-reads the gauge. Called from IOKit notifications; safe to call directly.
    public func refresh() {
        guard let snap = read() else { return }
        let changed = state.withLock { s -> Bool in
            defer { s.latest = snap }
            return s.latest != snap
        }
        if changed { onUpdate(snap) }
    }

    /// Live power-flow tick (only while a power display is visible).
    public func sample(tick: UInt64) {
        guard let flow = readFlow() else { return }
        let snap = state.withLock { s -> BatterySnapshot? in
            guard var snap = s.latest else { return nil }
            snap.flow = flow
            s.latest = snap
            s.flowHistory.append(Float(flow.systemLoad) / 1000)
            return snap
        }
        if let snap { onUpdate(snap) }
    }

    // MARK: - Reading

    private func prop(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func int(_ key: String) -> Int? { (prop(key) as? NSNumber)?.intValue }
    private func bool(_ key: String) -> Bool { (prop(key) as? NSNumber)?.boolValue ?? false }

    public func read() -> BatterySnapshot? {
        guard let percent = int("CurrentCapacity") else { return nil }
        let data = prop("BatteryData") as? [String: Any]
        let charger = prop("ChargerData") as? [String: Any]
        func d(_ k: String) -> Int? { (data?[k] as? NSNumber)?.intValue }

        let full = d("FullChargeCapacity")
        let remaining = d("RemainingCapacity")
        let hw = (full ?? 0) > 0 ? remaining.map { Double($0) / Double(full!) * 100 } : nil
        let toEmpty = int("AvgTimeToEmpty").flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        let toFull = int("AvgTimeToFull").flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }

        var adapter: AdapterInfo?
        if let a = prop("AdapterDetails") as? [String: Any], !a.isEmpty {
            adapter = AdapterInfo(
                name: (a["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
                watts: (a["Watts"] as? NSNumber)?.intValue,
                voltage: (a["AdapterVoltage"] as? NSNumber)?.intValue,
                current: (a["Current"] as? NSNumber)?.intValue,
                isWireless: (a["IsWireless"] as? NSNumber)?.boolValue ?? false
            )
        }

        return BatterySnapshot(
            percent: percent,
            hardwarePercent: hw,
            isCharging: bool("IsCharging"),
            externalConnected: bool("ExternalConnected"),
            fullyCharged: bool("FullyCharged"),
            amperage: int("InstantAmperage") ?? int("Amperage") ?? 0,
            voltage: int("Voltage") ?? 0,
            cycleCount: int("CycleCount") ?? 0,
            designCapacity: d("DesignCapacity") ?? int("DesignCapacity") ?? 0,
            fullChargeCapacity: full,
            nominalChargeCapacity: d("NominalChargeCapacity"),
            remainingCapacity: remaining,
            minutesToEmpty: toEmpty,
            minutesToFull: toFull,
            notChargingReason: (charger?["NotChargingReason"] as? NSNumber)?.intValue,
            adapter: adapter,
            flow: readFlow()
        )
    }

    public func readFlow() -> PowerFlow? {
        guard let t = prop("PowerTelemetryData") as? [String: Any] else { return nil }
        func v(_ k: String) -> Int { (t[k] as? NSNumber)?.intValue ?? 0 }
        return PowerFlow(adapterIn: v("SystemPowerIn"), systemLoad: v("SystemLoad"),
                         battery: v("BatteryPower"), adapterLoss: v("AdapterEfficiencyLoss"))
    }
}

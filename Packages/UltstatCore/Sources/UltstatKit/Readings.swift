import Foundation
import Synchronization
import UltstatCore

/// Latest value of every metric. A value type so the UI receives one consistent snapshot per tick.
public struct Readings: Equatable, Sendable {
    public init() {}

    public var cpu: CPULoad?
    public var gpu: GPULoad?
    public var memory: MemoryUsage?
    public var network: NetworkThroughput?
    public var disk: DiskActivity?
    public var sensors: [SensorGroup: GroupReading] = [:]
    public var battery: BatterySnapshot?
    public var systemPower: Double?          // W, from SMC PSTR
    public var componentPower: ComponentPower?
    public var fans: [FanReading] = []
    public var accessories: [AccessoryBattery] = []
    public var processes: [ProcessUsage] = []  // top by CPU; other orderings read from the sampler
}

/// Collects sampler callbacks (scheduler queue) and publishes them to the main actor at most
/// once per batch, however many samplers fired.
public final class ReadingsBus: Sendable {
    private struct Pending {
        var readings = Readings()
        var scheduled = false
    }

    private let pending = Mutex(Pending())
    private let deliver: @MainActor @Sendable (Readings) -> Void

    public init(deliver: @escaping @MainActor @Sendable (Readings) -> Void) {
        self.deliver = deliver
    }

    public func update(_ body: (inout Readings) -> Void) {
        let shouldSchedule = pending.withLock { p -> Bool in
            body(&p.readings)
            defer { p.scheduled = true }
            return !p.scheduled
        }
        guard shouldSchedule else { return }
        // Samplers of one tick finish within microseconds of each other; one hop carries them all.
        DispatchQueue.main.async { [self] in
            let snapshot = pending.withLock { p -> Readings in
                p.scheduled = false
                return p.readings
            }
            MainActor.assumeIsolated { deliver(snapshot) }
        }
    }
}

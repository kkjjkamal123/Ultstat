import Foundation
import Synchronization
import UltstatCore

/// Latest value of every metric. A value type so the UI receives one consistent snapshot per tick.
struct Readings: Equatable, Sendable {
    var cpu: CPULoad?
    var gpu: GPULoad?
    var memory: MemoryUsage?
    var network: NetworkThroughput?
    var disk: DiskActivity?
    var sensors: [SensorGroup: GroupReading] = [:]
    var battery: BatterySnapshot?
    var systemPower: Double?          // W, from SMC PSTR
    var componentPower: ComponentPower?
    var fans: [FanReading] = []
    var accessories: [AccessoryBattery] = []
    var processes: [ProcessUsage] = []  // top by CPU; other orderings read from the sampler
}

/// Collects sampler callbacks (scheduler queue) and publishes them to the main actor at most
/// once per batch, however many samplers fired.
final class ReadingsBus: Sendable {
    private struct Pending {
        var readings = Readings()
        var scheduled = false
    }

    private let pending = Mutex(Pending())
    private let deliver: @MainActor @Sendable (Readings) -> Void

    init(deliver: @escaping @MainActor @Sendable (Readings) -> Void) {
        self.deliver = deliver
    }

    func update(_ body: (inout Readings) -> Void) {
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

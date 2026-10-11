import Synchronization

public struct GroupReading: Sendable, Equatable {
    public var max: Float
    public var average: Float
}

/// Temperatures from SMC, read in a rotating window so each tick costs a handful of key reads.
///
/// An SMC read is a coprocessor round trip (~100–175 µs on M5). Reading every temperature key
/// each tick would cost ~20 ms; instead each demanded group reads `keysPerTick` keys per sample,
/// cycling through its keys, and reports max/average over the most recent value of every key.
public final class SensorSampler: Sampler {
    public let cadence: Int
    public let keysPerTick: Int
    public let catalog: SensorCatalog
    private let smc: SMC

    private struct GroupState {
        let keys: [SMCKey]
        var values: [Float]
        var cursor = 0
        var filled = 0
        var history = RingBuffer(capacity: 180)
    }

    private struct State {
        var groups: [SensorGroup: GroupState] = [:]
        var enabled: Set<SensorGroup> = []
        var latest: [SensorGroup: GroupReading] = [:]
    }

    private let state: Mutex<State>
    private let onUpdate: @Sendable ([SensorGroup: GroupReading]) -> Void

    public init(smc: SMC, catalog: SensorCatalog, cadence: Int = 2, keysPerTick: Int = 3,
                onUpdate: @escaping @Sendable ([SensorGroup: GroupReading]) -> Void = { _ in }) {
        self.smc = smc
        self.catalog = catalog
        self.cadence = cadence
        self.keysPerTick = keysPerTick
        self.onUpdate = onUpdate
        var groups: [SensorGroup: GroupState] = [:]
        for g in SensorGroup.allCases {
            let keys = catalog.keys(in: g).map { SMCKey($0) }
            if !keys.isEmpty { groups[g] = GroupState(keys: keys, values: .init(repeating: 0, count: keys.count)) }
        }
        state = Mutex(State(groups: groups))
    }

    public var availableGroups: [SensorGroup] { state.withLock { $0.groups.keys.sorted() } }
    public var latest: [SensorGroup: GroupReading] { state.withLock { $0.latest } }

    public func history(_ group: SensorGroup) -> RingBuffer? { state.withLock { $0.groups[group]?.history } }

    /// Only enabled groups are read. Newly enabled groups are filled completely on their first
    /// sample so they never report a partial maximum.
    public func setEnabled(_ groups: Set<SensorGroup>) {
        state.withLock { s in
            for g in groups.subtracting(s.enabled) { s.groups[g]?.filled = 0 }
            s.enabled = groups
            s.latest = s.latest.filter { groups.contains($0.key) }
        }
    }

    public func sample(tick: UInt64) {
        let readings = state.withLock { s -> [SensorGroup: GroupReading] in
            for g in s.enabled {
                guard var gs = s.groups[g] else { continue }
                let n = gs.keys.count
                let budget = gs.filled < n ? n : min(keysPerTick, n)   // full sweep until primed
                for _ in 0..<budget {
                    if let v = smc.double(gs.keys[gs.cursor]), v > 0, v < 150 { gs.values[gs.cursor] = Float(v) }
                    gs.cursor = (gs.cursor + 1) % n
                }
                gs.filled = Swift.min(n, gs.filled + budget)
                var mx: Float = 0, sum: Float = 0, cnt: Float = 0
                for v in gs.values where v > 0 {
                    mx = Swift.max(mx, v)
                    sum += v
                    cnt += 1
                }
                if cnt > 0 {
                    s.latest[g] = GroupReading(max: mx, average: sum / cnt)
                    gs.history.append(mx)
                }
                s.groups[g] = gs
            }
            return s.latest
        }
        if !readings.isEmpty { onUpdate(readings) }
    }
}

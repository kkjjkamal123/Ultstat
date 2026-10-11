import Darwin
import Synchronization

public struct CPULoad: Sendable, Equatable {
    /// 0...1 across all cores.
    public var total: Float
    public var user: Float
    public var system: Float
    /// Per logical CPU, 0...1. Empty unless per-core detail is enabled.
    public var perCore: [Float]
    /// Mean of performance / efficiency cores; nil without per-core detail.
    public var performance: Float?
    public var efficiency: Float?

    public init(total: Float, user: Float, system: Float, perCore: [Float], performance: Float?, efficiency: Float?) {
        self.total = total
        self.user = user
        self.system = system
        self.perCore = perCore
        self.performance = performance
        self.efficiency = efficiency
    }

    public static let zero = CPULoad(total: 0, user: 0, system: 0, perCore: [], performance: nil, efficiency: nil)
}

/// CPU utilisation from Mach tick counters.
///
/// Exactly one kernel call per tick:
/// - totals only: `HOST_CPU_LOAD_INFO` (fixed-size, no allocation);
/// - per-core: `host_processor_info` (vm-allocates per call), with totals summed from the cores.
///
/// xnu rate-limits `host_statistics` to roughly 10 calls per second per process and then
/// silently returns cached counters. A zero delta therefore means "no new data", never 0 % load,
/// and such ticks are dropped rather than recorded.
public final class CPUSampler: Sampler {
    public let cadence: Int
    public let topology: CPUTopology

    private struct State {
        var perCore = false
        var lastTotal: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
        var lastCores: [UInt32] = []   // flat [user, system, idle, nice] * n
        var latest: CPULoad = .zero
        var history = RingBuffer(capacity: 180)
    }

    private let state: Mutex<State>
    private let onUpdate: @Sendable (CPULoad) -> Void

    public init(cadence: Int = 1, topology: CPUTopology = .current(), onUpdate: @escaping @Sendable (CPULoad) -> Void = { _ in }) {
        self.cadence = cadence
        self.topology = topology
        self.onUpdate = onUpdate
        state = Mutex(State())
    }

    public var latest: CPULoad { state.withLock { $0.latest } }
    public var history: RingBuffer { state.withLock { $0.history } }

    /// Enable while something displays per-core bars; disable to drop back to the cheap path.
    public func setPerCore(_ on: Bool) {
        state.withLock {
            guard $0.perCore != on else { return }
            $0.perCore = on
            // Baselines from the other path are stale; start both fresh.
            $0.lastCores = []
            $0.lastTotal = nil
        }
    }

    public func sample(tick: UInt64) {
        let perCore = state.withLock { $0.perCore }
        guard let load = perCore ? readCores() : readTotals() else { return }
        state.withLock {
            $0.latest = load
            $0.history.append(load.total)
        }
        onUpdate(load)
    }

    private func readTotals() -> CPULoad? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(machHost, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let now = (
            user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3)
        )
        return state.withLock { s -> CPULoad? in
            defer { s.lastTotal = now }
            guard let prev = s.lastTotal else { return nil }
            // Tick counters are 32-bit in the kernel and wrap; subtract in that width.
            let du = Float(UInt32(truncatingIfNeeded: now.user &- prev.user))
            let ds = Float(UInt32(truncatingIfNeeded: now.system &- prev.system))
            let di = Float(UInt32(truncatingIfNeeded: now.idle &- prev.idle))
            let dn = Float(UInt32(truncatingIfNeeded: now.nice &- prev.nice))
            let all = du + ds + di + dn
            guard all > 0 else { return nil }
            return CPULoad(total: (du + ds + dn) / all, user: (du + dn) / all, system: ds / all,
                           perCore: [], performance: nil, efficiency: nil)
        }
    }

    private func readCores() -> CPULoad? {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(machHost, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount) == KERN_SUCCESS,
              let infoArray else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let n = Int(cpuCount)
        let stride = Int(CPU_STATE_MAX)
        let current = (0..<(n * stride)).map { UInt32(bitPattern: infoArray[$0]) }

        return state.withLock { s -> CPULoad? in
            defer { s.lastCores = current }
            guard s.lastCores.count == current.count else { return nil }
            var per = [Float](repeating: 0, count: n)
            var tu: Float = 0, ts: Float = 0, ti: Float = 0
            var pSum: Float = 0, pN: Float = 0, eSum: Float = 0, eN: Float = 0
            for c in 0..<n {
                let b = c * stride
                let du = Float(current[b + Int(CPU_STATE_USER)] &- s.lastCores[b + Int(CPU_STATE_USER)])
                    + Float(current[b + Int(CPU_STATE_NICE)] &- s.lastCores[b + Int(CPU_STATE_NICE)])
                let ds = Float(current[b + Int(CPU_STATE_SYSTEM)] &- s.lastCores[b + Int(CPU_STATE_SYSTEM)])
                let di = Float(current[b + Int(CPU_STATE_IDLE)] &- s.lastCores[b + Int(CPU_STATE_IDLE)])
                tu += du; ts += ds; ti += di
                let all = du + ds + di
                let busy = all > 0 ? (du + ds) / all : 0
                per[c] = busy
                if c < topology.kinds.count {
                    if topology.kinds[c] == .performance { pSum += busy; pN += 1 } else { eSum += busy; eN += 1 }
                }
            }
            let all = tu + ts + ti
            guard all > 0 else { return nil }
            return CPULoad(total: (tu + ts) / all, user: tu / all, system: ts / all, perCore: per,
                           performance: pN > 0 ? pSum / pN : nil, efficiency: eN > 0 ? eSum / eN : nil)
        }
    }
}

/// `mach_host_self()` returns a new send right on every call; cache one for the process lifetime.
let machHost = mach_host_self()

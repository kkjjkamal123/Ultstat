import Darwin
import Synchronization

public struct MemoryUsage: Sendable, Equatable {
    public var total: UInt64
    /// Activity Monitor's "Memory Used" = app + wired + compressed.
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: Pressure

    public enum Pressure: Int, Sendable {
        case normal = 1, warning = 2, critical = 4
    }

    public var usedFraction: Float { total > 0 ? Float(Double(used) / Double(total)) : 0 }
}

/// Memory from `HOST_VM_INFO64` plus two sysctls. No allocations per tick.
public final class MemorySampler: Sampler {
    public let cadence: Int
    private let pageSize: UInt64 = {
        var size: vm_size_t = 0
        return host_page_size(machHost, &size) == KERN_SUCCESS ? UInt64(size) : UInt64(sysconf(_SC_PAGESIZE))
    }()
    private let total: UInt64 = {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &v, &size, nil, 0)
        return v
    }()

    private struct State {
        var latest: MemoryUsage?
        var history = RingBuffer(capacity: 180)
    }

    private let state = Mutex(State())
    private let onUpdate: @Sendable (MemoryUsage) -> Void

    public init(cadence: Int = 2, onUpdate: @escaping @Sendable (MemoryUsage) -> Void = { _ in }) {
        self.cadence = cadence
        self.onUpdate = onUpdate
    }

    public var latest: MemoryUsage? { state.withLock { $0.latest } }
    public var history: RingBuffer { state.withLock { $0.history } }

    public func sample(tick: UInt64) {
        guard let usage = read() else { return }
        state.withLock {
            $0.latest = usage
            $0.history.append(usage.usedFraction)
        }
        onUpdate(usage)
    }

    public func read() -> MemoryUsage? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHost, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let p = pageSize
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (anonymous &- purgeable) * p
        let wired = UInt64(stats.wire_count) * p
        let compressed = UInt64(stats.compressor_page_count) * p
        let cached = (UInt64(stats.external_page_count) + purgeable) * p
        let used = app + wired + compressed

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        return MemoryUsage(
            total: total, used: min(used, total), app: app, wired: wired, compressed: compressed,
            cached: cached, free: total > used ? total - used : 0,
            swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
            pressure: MemoryUsage.Pressure(rawValue: Int(level)) ?? .normal
        )
    }
}

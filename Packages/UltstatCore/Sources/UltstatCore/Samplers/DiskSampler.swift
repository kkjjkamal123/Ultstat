import Foundation
import IOKit
import Synchronization

public struct DiskActivity: Sendable, Equatable {
    /// Bytes per second since the previous sample.
    public var read: Double
    public var write: Double
    public var capacity: UInt64
    public var available: UInt64

    public var usedFraction: Float {
        capacity > 0 ? Float(Double(capacity - min(available, capacity)) / Double(capacity)) : 0
    }
}

/// Disk throughput from every `IOBlockStorageDriver`'s `Statistics`, and boot-volume capacity
/// from `statfs`. Driver handles are cached; every `capacityEvery` samples the set is rescanned
/// and replaced if drives were attached or ejected.
/// Capacity is refreshed every `capacityEvery` samples (it moves slowly and `statfs` hits the FS).
public final class DiskSampler: Sampler {
    public let cadence: Int
    public let capacityEvery: Int

    private struct State {
        var drivers: [io_registry_entry_t] = []
        var last: (read: UInt64, write: UInt64, at: UInt64)?
        var capacity: (total: UInt64, free: UInt64) = (0, 0)
        var samples = 0
        var latest: DiskActivity?
        var readHistory = RingBuffer(capacity: 180)
        var writeHistory = RingBuffer(capacity: 180)
    }

    private let state = Mutex(State())
    private let onUpdate: @Sendable (DiskActivity) -> Void

    public init(cadence: Int = 1, capacityEvery: Int = 30, onUpdate: @escaping @Sendable (DiskActivity) -> Void = { _ in }) {
        self.cadence = cadence
        self.capacityEvery = capacityEvery
        self.onUpdate = onUpdate
    }

    deinit {
        state.withLock { $0.drivers.forEach { IOObjectRelease($0) } }
    }

    public var latest: DiskActivity? { state.withLock { $0.latest } }
    public var readHistory: RingBuffer { state.withLock { $0.readHistory } }
    public var writeHistory: RingBuffer { state.withLock { $0.writeHistory } }

    /// Call when disks appear/disappear (DiskArbitration) to rebuild the cached driver list.
    public func invalidateDrivers() {
        state.withLock { s in
            s.drivers.forEach { IOObjectRelease($0) }
            s.drivers = []
            s.last = nil
        }
    }

    public func sample(tick: UInt64) {
        let result = state.withLock { s -> DiskActivity? in
            if s.samples % max(1, capacityEvery) == 0 {
                s.capacity = Self.bootCapacity()
                // Pick up drives attached or ejected since the last scan; rebaseline if the set changed.
                let fresh = Self.findDrivers()
                if fresh.count != s.drivers.count || s.drivers.isEmpty {
                    s.drivers.forEach { IOObjectRelease($0) }
                    s.drivers = fresh
                    s.last = nil
                } else {
                    fresh.forEach { IOObjectRelease($0) }
                }
            }
            s.samples += 1

            var r: UInt64 = 0, w: UInt64 = 0
            for d in s.drivers {
                guard let stats = IORegistryEntryCreateCFProperty(d, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
                r &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            defer { s.last = (r, w, now) }
            guard let last = s.last, now > last.at else { return nil }
            let dt = Double(now - last.at) / 1e9
            let a = DiskActivity(
                read: r >= last.read ? Double(r - last.read) / dt : 0,
                write: w >= last.write ? Double(w - last.write) / dt : 0,
                capacity: s.capacity.total, available: s.capacity.free
            )
            s.latest = a
            s.readHistory.append(Float(a.read))
            s.writeHistory.append(Float(a.write))
            return a
        }
        if let result { onUpdate(result) }
    }

    private static func findDrivers() -> [io_registry_entry_t] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(it) }
        var out: [io_registry_entry_t] = []
        while case let d = IOIteratorNext(it), d != IO_OBJECT_NULL { out.append(d) }
        return out
    }

    private static func bootCapacity() -> (UInt64, UInt64) {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return (0, 0) }
        let bs = UInt64(fs.f_bsize)
        return (UInt64(fs.f_blocks) * bs, UInt64(fs.f_bavail) * bs)
    }
}

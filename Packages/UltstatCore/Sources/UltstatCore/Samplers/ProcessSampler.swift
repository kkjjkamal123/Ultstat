import Darwin
import Synchronization

public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    /// Share of one core (1.0 = one core fully busy).
    public var cpu: Double
    /// Bytes of physical footprint (what Activity Monitor calls "Memory").
    public var memory: UInt64
    /// Average power over the last interval, watts (from the kernel's per-process energy counter).
    public var watts: Double
    /// Disk bytes per second read / written over the last interval.
    public var diskRead: Double = 0
    public var diskWrite: Double = 0

    public init(pid: Int32, name: String, cpu: Double, memory: UInt64, watts: Double, diskRead: Double = 0, diskWrite: Double = 0) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.watts = watts
        self.diskRead = diskRead
        self.diskWrite = diskWrite
    }
}

/// Top processes from `libproc`, with no child processes (Stats spawns `ps`/`top` for this).
///
/// Costs roughly 1–2 µs per process per sample, so it only runs while a view that shows it is open.
/// `rusage_info` times are Mach absolute-time units (125/3 ns on Apple Silicon) and are converted.
public final class ProcessSampler: Sampler {
    public let cadence: Int
    public let limit: Int

    private struct Prev {
        var cpuTicks: UInt64
        var energy: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
    }

    private struct State {
        var prev: [Int32: Prev] = [:]
        var lastSample: UInt64 = 0
        var pids = [Int32](repeating: 0, count: 2048)
        var names: [Int32: String] = [:]
        var byCPU: [ProcessUsage] = []
        var byMemory: [ProcessUsage] = []
        var byPower: [ProcessUsage] = []
        var byDisk: [ProcessUsage] = []
    }

    private let state = Mutex(State())
    private let onUpdate: @Sendable ([ProcessUsage]) -> Void
    private let ticksToNanos: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    public init(cadence: Int = 2, limit: Int = 8, onUpdate: @escaping @Sendable ([ProcessUsage]) -> Void = { _ in }) {
        self.cadence = cadence
        self.limit = limit
        self.onUpdate = onUpdate
    }

    public var topByCPU: [ProcessUsage] { state.withLock { $0.byCPU } }
    public var topByMemory: [ProcessUsage] { state.withLock { $0.byMemory } }
    public var topByPower: [ProcessUsage] { state.withLock { $0.byPower } }
    public var topByDisk: [ProcessUsage] { state.withLock { $0.byDisk } }

    public func sample(tick: UInt64) {
        let top = state.withLock { s -> [ProcessUsage]? in
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let dt = s.lastSample > 0 ? Double(now - s.lastSample) : 0
            s.lastSample = now

            var bytes = s.pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            if bytes >= Int32(s.pids.count) {  // grow and retry once
                s.pids = [Int32](repeating: 0, count: Int(bytes) * 2)
                bytes = s.pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            }
            guard bytes > 0 else { return nil }
            let count = Int(bytes)

            var next: [Int32: Prev] = [:]
            next.reserveCapacity(count)
            var all: [ProcessUsage] = []
            all.reserveCapacity(count)
            var info = rusage_info_v6()
            for i in 0..<count {
                let pid = s.pids[i]
                guard pid > 0 else { continue }
                let ok = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
                    }
                }
                guard ok else { continue }
                let ticks = info.ri_user_time &+ info.ri_system_time
                next[pid] = Prev(cpuTicks: ticks, energy: info.ri_energy_nj, diskRead: info.ri_diskio_bytesread, diskWrite: info.ri_diskio_byteswritten)
                guard dt > 0, let p = s.prev[pid] else { continue }
                let cpu = ticks >= p.cpuTicks ? Double(ticks - p.cpuTicks) * ticksToNanos / dt : 0
                let watts = info.ri_energy_nj >= p.energy ? Double(info.ri_energy_nj - p.energy) / dt : 0 // nJ/ns = W
                let secs = dt / 1e9
                let dr = info.ri_diskio_bytesread >= p.diskRead ? Double(info.ri_diskio_bytesread - p.diskRead) / secs : 0
                let dw = info.ri_diskio_byteswritten >= p.diskWrite ? Double(info.ri_diskio_byteswritten - p.diskWrite) / secs : 0
                all.append(ProcessUsage(pid: pid, name: "", cpu: cpu, memory: info.ri_phys_footprint, watts: watts, diskRead: dr, diskWrite: dw))
            }
            s.prev = next
            s.names = s.names.filter { next[$0.key] != nil }   // forget exited processes
            guard dt > 0 else { return nil }

            func top(_ key: (ProcessUsage) -> Double) -> [ProcessUsage] {
                var picked = Array(all.sorted { key($0) > key($1) }.prefix(limit))
                for j in picked.indices { picked[j].name = name(pid: picked[j].pid, cache: &s.names) }
                return picked
            }
            s.byCPU = top { $0.cpu }
            s.byMemory = top { Double($0.memory) }
            s.byPower = top { $0.watts }
            s.byDisk = top { $0.diskRead + $0.diskWrite }
            return s.byCPU
        }
        if let top { onUpdate(top) }
    }

    /// Names are resolved only for the processes shown, and cached per pid.
    private func name(pid: Int32, cache: inout [Int32: String]) -> String {
        if let n = cache[pid] { return n }
        var buf = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let len = proc_name(pid, &buf, UInt32(buf.count))
        var n = len > 0 ? String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        if n.isEmpty {
            // Fall back to the executable's file name (proc_name truncates and can be empty).
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let full = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                n = full.split(separator: "/").last.map(String.init) ?? full
            }
        }
        if n.isEmpty { n = "pid \(pid)" }
        cache[pid] = n
        return n
    }
}

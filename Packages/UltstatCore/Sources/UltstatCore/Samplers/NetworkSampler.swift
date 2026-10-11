import Darwin
import Synchronization

public struct NetworkThroughput: Sendable, Equatable {
    /// Bytes per second since the previous sample.
    public var download: Double
    public var upload: Double
    /// Lifetime counters of the measured interfaces.
    public var totalIn: UInt64
    public var totalOut: UInt64
    public var interfaces: [String]
}

/// Interface byte counters.
///
/// Discovery walks every kernel interface once via `sysctl(NET_RT_IFLIST2)` (~60 µs; a Mac easily
/// has 40+ interfaces). Each tick then reads only the counted interfaces with the per-interface
/// `IFMIB_IFDATA` sysctl (~0.7 µs each). Rediscovery happens every `rediscoverEvery` samples and
/// immediately after `invalidateInterfaces()` (wire to SCDynamicStore network-change events).
///
/// Counts physical interfaces only (`en*`, plus cellular/tethering `pdp_ip*`), skipping loopback,
/// AWDL and tunnels so VPN traffic isn't double counted.
public final class NetworkSampler: Sampler {
    public let cadence: Int

    public let rediscoverEvery: Int

    private struct State {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var interfaces: [(index: Int32, name: String)] = []
        var samples = 0
        var last: (inBytes: UInt64, outBytes: UInt64, at: UInt64)?
        var latest: NetworkThroughput?
        var downHistory = RingBuffer(capacity: 180)
        var upHistory = RingBuffer(capacity: 180)
    }

    private let state = Mutex(State())
    private let onUpdate: @Sendable (NetworkThroughput) -> Void

    public init(cadence: Int = 1, rediscoverEvery: Int = 30, onUpdate: @escaping @Sendable (NetworkThroughput) -> Void = { _ in }) {
        self.cadence = cadence
        self.rediscoverEvery = rediscoverEvery
        self.onUpdate = onUpdate
    }

    public var latest: NetworkThroughput? { state.withLock { $0.latest } }
    public var downloadHistory: RingBuffer { state.withLock { $0.downHistory } }
    public var uploadHistory: RingBuffer { state.withLock { $0.upHistory } }

    /// Forces interface rediscovery on the next sample (network configuration changed).
    public func invalidateInterfaces() {
        state.withLock { $0.interfaces = [] }
    }

    public func sample(tick: UInt64) {
        let result = state.withLock { s -> NetworkThroughput? in
            if s.interfaces.isEmpty || s.samples % max(1, rediscoverEvery) == 0 {
                guard let found = Self.discover(&s.buffer) else { return nil }
                if found.map(\.index) != s.interfaces.map(\.index) { s.last = nil } // set changed: rebaseline
                s.interfaces = found
            }
            s.samples += 1
            var inB: UInt64 = 0, outB: UInt64 = 0
            for i in s.interfaces {
                guard let (ib, ob) = Self.counters(index: i.index) else { continue }
                inB &+= ib
                outB &+= ob
            }
            let names = s.interfaces.map(\.name)
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            defer { s.last = (inB, outB, now) }
            guard let last = s.last, now > last.at else { return nil }
            let dt = Double(now - last.at) / 1e9
            // Counters reset when an interface goes away; treat a decrease as zero, never negative.
            let down = inB >= last.inBytes ? Double(inB - last.inBytes) / dt : 0
            let up = outB >= last.outBytes ? Double(outB - last.outBytes) / dt : 0
            let t = NetworkThroughput(download: down, upload: up, totalIn: inB, totalOut: outB, interfaces: names)
            s.latest = t
            s.downHistory.append(Float(down))
            s.upHistory.append(Float(up))
            return t
        }
        if let result { onUpdate(result) }
    }

    /// `en*` (Wi-Fi, Ethernet, Thunderbolt) and `pdp_ip*` (cellular tethering).
    static func isCounted(_ name: UnsafeRawBufferPointer) -> Bool {
        guard name.count >= 2 else { return false }
        if name[0] == 0x65, name[1] == 0x6E { return true }                     // "en"
        return name.count >= 6 && name.prefix(6).elementsEqual("pdp_ip".utf8)
    }

    static func counters(index: Int32) -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
        var data = ifmibdata()
        var len = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, 6, &data, &len, nil, 0) == 0 else { return nil }
        return (data.ifmd_data.ifi_ibytes, data.ifmd_data.ifi_obytes)
    }

    /// One `sysctl` for every interface. Names come from the `sockaddr_dl` the kernel places after
    /// each `if_msghdr2`, so there are no per-interface syscalls (`if_indextoname` is ~100 µs each).
    static func discover(_ buffer: inout [UInt8]) -> [(index: Int32, name: String)]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = buffer.count
        var rc = buffer.withUnsafeMutableBytes { sysctl(&mib, 6, $0.baseAddress, &len, nil, 0) }
        if rc != 0, errno == ENOMEM {
            var needed = 0
            guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0 else { return nil }
            buffer = [UInt8](repeating: 0, count: needed * 2)
            len = buffer.count
            rc = buffer.withUnsafeMutableBytes { sysctl(&mib, 6, $0.baseAddress, &len, nil, 0) }
        }
        guard rc == 0 else { return nil }

        var found: [(index: Int32, name: String)] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let h2Size = MemoryLayout<if_msghdr2>.size
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let msglen = Int(raw.load(fromByteOffset: offset, as: UInt16.self))
                guard msglen > 0 else { break }
                defer { offset += msglen }
                let type = raw.load(fromByteOffset: offset + 3, as: UInt8.self)
                guard Int32(type) == RTM_IFINFO2, msglen >= h2Size + 8 else { continue }
                let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard h2.ifm_flags & IFF_UP != 0, h2.ifm_flags & IFF_LOOPBACK == 0 else { continue }
                // sockaddr_dl: len(1) family(1) index(2) type(1) nlen(1) alen(1) slen(1) data[...]
                let sdl = offset + h2Size
                let nlen = Int(raw[sdl + 5])
                guard nlen > 0, sdl + 8 + nlen <= offset + msglen else { continue }
                let name = UnsafeRawBufferPointer(rebasing: raw[(sdl + 8)..<(sdl + 8 + nlen)])
                guard isCounted(name) else { continue }
                found.append((Int32(h2.ifm_index), String(decoding: name, as: UTF8.self)))
            }
        }
        return found
    }
}

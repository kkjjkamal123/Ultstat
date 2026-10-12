import Darwin
import Foundation
import Network

/// Cheap on-demand system facts for the detail panels (read when a panel opens / ticks).
public enum SystemInfo {
    /// 1, 5 and 15-minute load averages.
    public static func loadAverage() -> (Double, Double, Double)? {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) == 3 else { return nil }
        return (l[0], l[1], l[2])
    }

    public static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    public struct Interface: Sendable, Equatable {
        public var name: String
        public var ipv4: String?
        public var ipv6: String?
    }

    /// IPv4/IPv6 addresses of an interface (getifaddrs; only called while a panel shows it).
    public static func addresses(of interface: String) -> Interface {
        var result = Interface(name: interface)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard String(cString: ifa.ifa_name) == interface, let addr = ifa.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6,
                  getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let s = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET { result.ipv4 = s } else if !s.hasPrefix("fe80"), result.ipv6 == nil { result.ipv6 = s }
        }
        return result
    }

    public struct Volume: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public var name: String
        public var path: String
        public var capacity: Int64
        public var available: Int64
        public var isInternal: Bool
        public var isRemovable: Bool
        public var usedFraction: Float { capacity > 0 ? Float(Double(capacity - available) / Double(capacity)) : 0 }
    }

    /// Mounted, user-visible volumes (FileManager resource values; panel-open only).
    public static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return Volume(name: v.volumeName ?? url.lastPathComponent, path: url.path, capacity: Int64(total),
                          available: free, isInternal: v.volumeIsInternal ?? false, isRemovable: v.volumeIsRemovable ?? false)
        }
    }
}

/// Connection status, pushed by Network.framework (no polling).
public final class ConnectivityMonitor: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public var connected: Bool
        public var interfaceType: String
        public var expensive: Bool
        public var constrained: Bool
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ultstat.connectivity", qos: .utility)
    private let lock = NSLock()
    private var _status: Status?

    public init(onChange: @escaping @Sendable (Status) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let type: String = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet"
                : path.usesInterfaceType(.cellular) ? "Cellular" : path.usesInterfaceType(.other) ? "Other" : "None"
            let s = Status(connected: path.status == .satisfied, interfaceType: type, expensive: path.isExpensive, constrained: path.isConstrained)
            self?.lock.lock()
            self?._status = s
            self?.lock.unlock()
            onChange(s)
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public var status: Status? {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }
}

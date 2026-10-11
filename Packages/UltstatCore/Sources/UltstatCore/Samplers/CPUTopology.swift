import Foundation
import IOKit

/// Which cluster each logical CPU belongs to, read once from the device tree.
public struct CPUTopology: Sendable, Equatable {
    public enum Kind: Character, Sendable {
        case performance = "P"   // "Super" cores on M5 and later
        case efficiency = "E"
    }

    /// Indexed by logical CPU id.
    public let kinds: [Kind]

    public init(kinds: [Kind]) { self.kinds = kinds }

    public var performanceCount: Int { kinds.lazy.filter { $0 == .performance }.count }
    public var efficiencyCount: Int { kinds.lazy.filter { $0 == .efficiency }.count }

    /// Reads `IODeviceTree:/cpus/cpu*` `cluster-type` and `logical-cpu-id`.
    public static func current() -> CPUTopology {
        var pairs: [(Int, Kind)] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("cpus"), &iterator) == KERN_SUCCESS else {
            return fallback()
        }
        defer { IOObjectRelease(iterator) }
        let cpus = IOIteratorNext(iterator)
        guard cpus != IO_OBJECT_NULL else { return fallback() }
        defer { IOObjectRelease(cpus) }

        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &children) == KERN_SUCCESS else { return fallback() }
        defer { IOObjectRelease(children) }
        while case let cpu = IOIteratorNext(children), cpu != IO_OBJECT_NULL {
            defer { IOObjectRelease(cpu) }
            guard let type = data(cpu, "cluster-type")?.first.map({ Character(UnicodeScalar($0)) }),
                  let kind = Kind(rawValue: type),
                  let idBytes = data(cpu, "logical-cpu-id"), idBytes.count >= 4
            else { continue }
            let id = Int(UInt32(idBytes[0]) | UInt32(idBytes[1]) << 8 | UInt32(idBytes[2]) << 16 | UInt32(idBytes[3]) << 24)
            pairs.append((id, kind))
        }
        guard !pairs.isEmpty else { return fallback() }
        pairs.sort { $0.0 < $1.0 }
        return CPUTopology(kinds: pairs.map(\.1))
    }

    private static func data(_ entry: io_registry_entry_t, _ key: String) -> [UInt8]? {
        guard let cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        if let d = cf as? Data { return [UInt8](d) }
        if let n = cf as? NSNumber { return withUnsafeBytes(of: n.uint32Value.littleEndian) { Array($0) } }
        return nil
    }

    /// sysctl-based fallback: efficiency cores first, matching every Apple Silicon layout so far.
    private static func fallback() -> CPUTopology {
        let p = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        let e = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        return CPUTopology(kinds: Array(repeating: .efficiency, count: e) + Array(repeating: .performance, count: p))
    }
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}


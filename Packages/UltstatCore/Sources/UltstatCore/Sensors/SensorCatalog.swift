import Foundation

/// Sensor groups, derived from SMC key naming that has been stable from M1 through M5.
public enum SensorGroup: String, Codable, Sendable, CaseIterable, Comparable {
    case cpuPerformance, cpuEfficiency, gpu, soc, memory, battery, ssd, wireless, charger, other

    /// Classifies a temperature key (`T???`). Returns nil for keys that are not temperatures.
    public static func classify(_ key: String) -> SensorGroup? {
        let u = Array(key.utf8)
        guard u.count == 4, u[0] == 0x54 /* T */ else { return nil }
        switch (u[1], u[2]) {
        case (0x70, _): return .cpuPerformance            // Tp**
        case (0x65, _): return .cpuEfficiency             // Te**
        case (0x67, _): return .gpu                       // Tg**
        case (0x73, _): return .soc                       // Ts**
        case (0x6D, _): return .memory                    // Tm**
        case (0x42, _) where u[3] == 0x54: return .battery // TB?T
        case (0x48, _): return .ssd                       // TH**
        case (0x57, _): return .wireless                  // TW**
        case (0x43, 0x48): return .charger                // TCH*
        default: return .other
        }
    }

    public static func < (a: SensorGroup, b: SensorGroup) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var displayName: String {
        switch self {
        case .cpuPerformance: "CPU Performance"
        case .cpuEfficiency: "CPU Efficiency"
        case .gpu: "GPU"
        case .soc: "SoC"
        case .memory: "Memory"
        case .battery: "Battery"
        case .ssd: "SSD"
        case .wireless: "Wi-Fi"
        case .charger: "Charger"
        case .other: "Other"
        }
    }
}

/// The temperature, power, voltage, current and fan keys this Mac actually exposes.
public struct SensorCatalog: Codable, Sendable, Equatable {
    public struct Sensor: Codable, Sendable, Hashable {
        public let key: String
        public let group: SensorGroup
    }

    public var model: String
    public var osBuild: String
    public var temperatures: [Sensor]
    /// Float power keys in watts (`P???`), e.g. `PSTR` total system power.
    public var power: [String]
    public var fans: Int

    public func keys(in group: SensorGroup) -> [String] {
        temperatures.lazy.filter { $0.group == group }.map(\.key)
    }

    /// Enumerates the SMC once (~0.4 s on M5) and keeps plausible float sensors.
    public static func discover(smc: SMC) -> SensorCatalog {
        var temps: [Sensor] = []
        var power: [String] = []
        for key in smc.allKeys() {
            let name = key.description
            guard let first = name.utf8.first, first == 0x54 || first == 0x50 else { continue } // T or P
            guard let info = smc.info(key), info.type == .flt, let v = smc.double(key) else { continue }
            if first == 0x54, let group = SensorGroup.classify(name), v > 5, v < 130 {
                temps.append(Sensor(key: name, group: group))
            } else if first == 0x50, v >= 0, v < 500 {
                power.append(name)
            }
        }
        let fans = smc.double("FNum").map { Int($0) } ?? 0
        return SensorCatalog(model: Self.currentModel, osBuild: Self.currentBuild,
                             temperatures: temps, power: power, fans: max(0, fans))
    }

    /// Loads the cached catalog when it matches this Mac and OS build, otherwise rediscovers and saves.
    public static func load(smc: SMC, cacheURL: URL) -> SensorCatalog {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? PropertyListDecoder().decode(SensorCatalog.self, from: data),
           cached.model == currentModel, cached.osBuild == currentBuild, !cached.temperatures.isEmpty {
            return cached
        }
        let fresh = discover(smc: smc)
        if let data = try? PropertyListEncoder().encode(fresh) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return fresh
    }

    static var currentModel: String { sysctlString("hw.model") ?? "unknown" }
    static var currentBuild: String { sysctlString("kern.osversion") ?? "unknown" }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

import Foundation
import notify

/// The SMC operations charge control needs. `SMC` conforms; tests use a fake.
public protocol SMCAccess: AnyObject, Sendable {
    func info(_ key: SMCKey) -> SMCKeyInfo?
    func read(_ key: SMCKey) throws(SMCError) -> SMCValue
    func write(_ key: SMCKey, bytes: [UInt8]) throws(SMCError)
}

extension SMC: SMCAccess {}

/// Root preferences + Darwin notifications, abstracted for tests.
public protocol SystemPreferences: Sendable {
    func value(_ key: String, domain: String) -> Any?
    func set(_ key: String, _ value: Any?, domain: String)
    func synchronize(domain: String) -> Bool
    func post(_ notification: String)
}

/// Turns `ChargeOutputs` into hardware state.
public protocol ChargeActuator: AnyObject, Sendable {
    var mechanism: ChargeStatus.Mechanism { get }
    func apply(_ outputs: ChargeOutputs, mode: ChargeMode, policy: ChargePolicy, percent: Double) throws
    func setMagSafeLED(_ mode: Int) throws
    /// Puts the hardware back to stock behaviour. Must be safe to call repeatedly.
    func restoreStock() throws
}

public enum ChargeControlError: Error, CustomStringConvertible, Sendable {
    case smc(SMCError)
    case preferences(String)

    public var description: String {
        switch self {
        case .smc(let e): "SMC: \(e)"
        case .preferences(let s): "Preferences: \(s)"
        }
    }
}

/// Picks the mechanism by probing which keys this firmware exposes.
public func detectChargeMechanism(smc: any SMCAccess) -> ChargeStatus.Mechanism {
    if smc.info("CHTE") != nil { return .smcTahoe }
    if smc.info("CH0B") != nil || smc.info("CH0C") != nil { return .smcLegacy }
    if smc.info("CHIE") != nil { return .nativeLimit }
    return .unsupported
}

// MARK: - Shared SMC plumbing

/// Writes a key only when the desired bytes differ from what we last wrote (or what is there).
final class SMCWriteCache: @unchecked Sendable {
    private let smc: any SMCAccess
    private var written: [SMCKey: [UInt8]] = [:]
    private let lock = NSLock()

    init(smc: any SMCAccess) { self.smc = smc }

    func set(_ key: SMCKey, _ bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        if written[key] == bytes { return }
        if written[key] == nil, let current = try? smc.read(key), current.bytes == bytes {
            written[key] = bytes
            return
        }
        do { try smc.write(key, bytes: bytes) } catch { throw ChargeControlError.smc(error) }
        written[key] = bytes
    }

    func has(_ key: SMCKey) -> Bool { smc.info(key) != nil }
}

private let ledKey: SMCKey = "ACLC"

// MARK: - macOS 26 "Tahoe" firmware: CHTE (inhibit) + CHIE (adapter)

public final class TahoeSMCActuator: ChargeActuator {
    public let mechanism = ChargeStatus.Mechanism.smcTahoe
    private let cache: SMCWriteCache

    public init(smc: any SMCAccess) { cache = SMCWriteCache(smc: smc) }

    public func apply(_ o: ChargeOutputs, mode: ChargeMode, policy: ChargePolicy, percent: Double) throws {
        // Inhibit = 0x01000000 packed most-significant byte first: bytes 01 00 00 00 (matches the
        // packing AlDente's helper uses for this key; see docs/charging-control.md).
        try cache.set("CHTE", o.allowCharging ? [0x00, 0x00, 0x00, 0x00] : [0x01, 0x00, 0x00, 0x00])
        try cache.set("CHIE", [o.discharge ? 0x08 : 0x00])
    }

    public func setMagSafeLED(_ mode: Int) throws {
        if cache.has(ledKey) { try cache.set(ledKey, [UInt8(mode)]) }
    }

    public func restoreStock() throws {
        try apply(.stock, mode: .charging, policy: .stock, percent: 0)
        try setMagSafeLED(0)
    }
}

// MARK: - Legacy Apple Silicon: CH0B/CH0C (inhibit) + CH0I (adapter)

public final class LegacySMCActuator: ChargeActuator {
    public let mechanism = ChargeStatus.Mechanism.smcLegacy
    private let cache: SMCWriteCache

    public init(smc: any SMCAccess) { cache = SMCWriteCache(smc: smc) }

    public func apply(_ o: ChargeOutputs, mode: ChargeMode, policy: ChargePolicy, percent: Double) throws {
        let inhibit: UInt8 = o.allowCharging ? 0x00 : 0x02
        if cache.has("CH0B") { try cache.set("CH0B", [inhibit]) }
        if cache.has("CH0C") { try cache.set("CH0C", [inhibit]) }
        if cache.has("CH0I") { try cache.set("CH0I", [o.discharge ? 0x01 : 0x00]) }
    }

    public func setMagSafeLED(_ mode: Int) throws {
        if cache.has(ledKey) { try cache.set(ledKey, [UInt8(mode)]) }
    }

    public func restoreStock() throws {
        try apply(.stock, mode: .charging, policy: .stock, percent: 0)
        try setMagSafeLED(0)
    }
}

// MARK: - macOS 27+: native Manual Charge Limit (MCL) + CHIE for discharge

/// Drives macOS's own charge limiter through its root preferences domain. macOS then enforces
/// the limit itself, including in sleep and without Ultstat running. See docs/charging-control.md.
public final class NativeLimitActuator: ChargeActuator, @unchecked Sendable {
    public static let domain = "com.apple.smartcharging.topoffprotection"
    public static let reloadNotification = "com.apple.smartcharging.defaultschanged"
    static let managedKeys = ["enabled", "mclLimitValue", "MCLFeatureState"]
    static let stateKeys = ["checkpoint", "currentState"]

    public let mechanism = ChargeStatus.Mechanism.nativeLimit
    private let cache: SMCWriteCache
    private let prefs: any SystemPreferences
    private let lock = NSLock()
    private var appliedTarget: Int?
    /// Values present before Ultstat first touched the domain, for `restoreStock()`.
    private var originals: [String: Any?]?

    public init(smc: any SMCAccess, prefs: any SystemPreferences) {
        cache = SMCWriteCache(smc: smc)
        self.prefs = prefs
    }

    /// Native-limit target for a given state. macOS holds the battery at this value by itself.
    static func target(for o: ChargeOutputs, mode: ChargeMode, policy: ChargePolicy, percent: Double) -> Int? {
        switch mode {
        case .onBattery, .toppingUp:
            return policy.isLimiting && mode == .onBattery ? policy.limit : nil
        case .charging:
            return policy.isLimiting ? policy.limit : nil
        case .holding, .discharging:
            return policy.limit
        case .sailing:
            return max(ChargePolicy.limitRange.lowerBound, policy.limit - policy.sailingRange)
        case .heatPaused:
            // Freeze at the current level: macOS won't charge above it.
            return max(ChargePolicy.limitRange.lowerBound, min(100, Int(percent.rounded(.down))))
        case .calibrating:
            // The cycle must reach 100 %; the discharge phase uses the adapter bypass (CHIE) instead.
            return nil
        }
    }

    public func apply(_ o: ChargeOutputs, mode: ChargeMode, policy: ChargePolicy, percent: Double) throws {
        try setTarget(Self.target(for: o, mode: mode, policy: policy, percent: percent))
        if cache.has("CHIE") { try cache.set("CHIE", [o.discharge ? 0x08 : 0x00]) }
    }

    public func setMagSafeLED(_ mode: Int) throws {
        if cache.has(ledKey) { try cache.set(ledKey, [UInt8(mode)]) }
    }

    public func restoreStock() throws {
        if cache.has("CHIE") { try cache.set("CHIE", [0x00]) }
        try setMagSafeLED(0)
        lock.lock()
        defer { lock.unlock() }
        guard let originals else { return }   // never touched the domain
        for key in Self.managedKeys { prefs.set(key, originals[key].flatMap { $0 }, domain: Self.domain) }
        try commit()
        self.originals = nil
        appliedTarget = nil
    }

    private func setTarget(_ target: Int?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard target != appliedTarget else { return }
        if originals == nil {
            originals = Dictionary(uniqueKeysWithValues: Self.managedKeys.map { ($0, prefs.value($0, domain: Self.domain)) })
        }
        if let target {
            prefs.set("enabled", false, domain: Self.domain)          // Optimized Battery Charging off
            prefs.set("mclLimitValue", target, domain: Self.domain)
            prefs.set("MCLFeatureState", 1, domain: Self.domain)
        } else {
            prefs.set("MCLFeatureState", 0, domain: Self.domain)
        }
        try commit()
        appliedTarget = target
    }

    /// Clears the daemon's cached state, flushes, and tells it to reload. Caller holds `lock`.
    private func commit() throws {
        for key in Self.stateKeys { prefs.set(key, nil, domain: Self.domain) }
        guard prefs.synchronize(domain: Self.domain) else {
            throw ChargeControlError.preferences("CFPreferencesSynchronize failed for \(Self.domain)")
        }
        prefs.post(Self.reloadNotification)
    }
}

/// Real implementation: CFPreferences in the calling user's scope (root in the helper) and notify(3).
public struct CFSystemPreferences: SystemPreferences {
    public init() {}

    public func value(_ key: String, domain: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    public func set(_ key: String, _ value: Any?, domain: String) {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    public func synchronize(domain: String) -> Bool {
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    public func post(_ notification: String) {
        notify_post(notification)
    }
}

public func makeChargeActuator(smc: any SMCAccess, prefs: any SystemPreferences = CFSystemPreferences()) -> (any ChargeActuator)? {
    switch detectChargeMechanism(smc: smc) {
    case .smcTahoe: TahoeSMCActuator(smc: smc)
    case .smcLegacy: LegacySMCActuator(smc: smc)
    case .nativeLimit: NativeLimitActuator(smc: smc, prefs: prefs)
    case .unsupported: nil
    }
}

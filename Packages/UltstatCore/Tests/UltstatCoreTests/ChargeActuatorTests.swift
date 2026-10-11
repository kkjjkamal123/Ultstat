import Foundation
import Testing
@testable import UltstatCore

/// In-memory SMC with a fixed key set; records every write.
final class FakeSMC: SMCAccess, @unchecked Sendable {
    var values: [SMCKey: [UInt8]]
    var writes: [(SMCKey, [UInt8])] = []
    var failWrites = false

    init(_ values: [SMCKey: [UInt8]]) { self.values = values }

    func info(_ key: SMCKey) -> SMCKeyInfo? {
        values[key].map { SMCKeyInfo(size: $0.count, type: .hex, attributes: 0xD4) }
    }

    func read(_ key: SMCKey) throws(SMCError) -> SMCValue {
        guard let v = values[key], let i = info(key) else { throw .keyNotFound(key) }
        return SMCValue(info: i, bytes: v)
    }

    func write(_ key: SMCKey, bytes: [UInt8]) throws(SMCError) {
        if failWrites { throw .writeFailed(key, 1, firmwareResult: 0x84) }
        guard values[key] != nil else { throw .keyNotFound(key) }
        values[key] = bytes
        writes.append((key, bytes))
    }
}

final class FakePrefs: SystemPreferences, @unchecked Sendable {
    var store: [String: Any] = [:]
    var posted: [String] = []
    var syncOK = true
    func value(_ key: String, domain: String) -> Any? { store[key] }
    func set(_ key: String, _ value: Any?, domain: String) { store[key] = value }
    func synchronize(domain: String) -> Bool { syncOK }
    func post(_ notification: String) { posted.append(notification) }
}

@Suite struct ChargeActuatorTests {
    @Test func detectsMechanismByKeyPresence() {
        #expect(detectChargeMechanism(smc: FakeSMC(["CHTE": [0, 0, 0, 0], "CHIE": [0]])) == .smcTahoe)
        #expect(detectChargeMechanism(smc: FakeSMC(["CH0B": [0], "CH0C": [0]])) == .smcLegacy)
        #expect(detectChargeMechanism(smc: FakeSMC(["CHIE": [0]])) == .nativeLimit, "M5 / macOS 27 layout")
        #expect(detectChargeMechanism(smc: FakeSMC([:])) == .unsupported)
    }

    @Test func tahoeWritesExactBytesAndSkipsRedundantWrites() throws {
        let smc = FakeSMC(["CHTE": [0, 0, 0, 0], "CHIE": [0], "ACLC": [0]])
        let a = TahoeSMCActuator(smc: smc)
        try a.apply(ChargeOutputs(allowCharging: false, discharge: false), mode: .holding, policy: ChargePolicy(), percent: 80)
        #expect(smc.values["CHTE"] == [0x01, 0x00, 0x00, 0x00])
        #expect(smc.writes.count == 1, "CHIE already 0x00, so it is not rewritten")
        try a.apply(ChargeOutputs(allowCharging: false, discharge: false), mode: .holding, policy: ChargePolicy(), percent: 80)
        #expect(smc.writes.count == 1, "identical state writes nothing")
        try a.apply(ChargeOutputs(allowCharging: false, discharge: true), mode: .discharging, policy: ChargePolicy(), percent: 90)
        #expect(smc.values["CHIE"] == [0x08])
        try a.restoreStock()
        #expect(smc.values["CHTE"] == [0, 0, 0, 0] && smc.values["CHIE"] == [0])
    }

    @Test func legacyUsesBothInhibitKeys() throws {
        let smc = FakeSMC(["CH0B": [0], "CH0C": [0], "CH0I": [0]])
        let a = LegacySMCActuator(smc: smc)
        try a.apply(ChargeOutputs(allowCharging: false, discharge: true), mode: .discharging, policy: ChargePolicy(), percent: 90)
        #expect(smc.values["CH0B"] == [2] && smc.values["CH0C"] == [2] && smc.values["CH0I"] == [1])
        try a.restoreStock()
        #expect(smc.values["CH0B"] == [0] && smc.values["CH0C"] == [0] && smc.values["CH0I"] == [0])
    }

    @Test func smcFailureSurfacesAsError() {
        let smc = FakeSMC(["CHTE": [0, 0, 0, 0], "CHIE": [0]])
        smc.failWrites = true
        let a = TahoeSMCActuator(smc: smc)
        #expect(throws: ChargeControlError.self) {
            try a.apply(ChargeOutputs(allowCharging: false, discharge: false), mode: .holding, policy: ChargePolicy(), percent: 80)
        }
    }

    @Test func nativeLimitWritesSequenceAndNotifies() throws {
        let smc = FakeSMC(["CHIE": [0]])
        let prefs = FakePrefs()
        prefs.store = ["enabled": true, "checkpoint": 3, "currentState": 1]
        let a = NativeLimitActuator(smc: smc, prefs: prefs)
        try a.apply(ChargeOutputs(allowCharging: false, discharge: false), mode: .holding, policy: ChargePolicy(limit: 75), percent: 75)
        #expect(prefs.store["mclLimitValue"] as? Int == 75)
        #expect(prefs.store["MCLFeatureState"] as? Int == 1)
        #expect(prefs.store["enabled"] as? Bool == false)
        #expect(prefs.store["checkpoint"] == nil && prefs.store["currentState"] == nil, "daemon state reset")
        #expect(prefs.posted == [NativeLimitActuator.reloadNotification])

        try a.apply(ChargeOutputs(allowCharging: false, discharge: false), mode: .holding, policy: ChargePolicy(limit: 75), percent: 75)
        #expect(prefs.posted.count == 1, "same target is not rewritten")
    }

    @Test func nativeLimitSailingAndHeatTargets() {
        let p = ChargePolicy(limit: 80, sailingRange: 5)
        let paused = ChargeOutputs(allowCharging: false, discharge: false)
        #expect(NativeLimitActuator.target(for: paused, mode: .sailing, policy: p, percent: 78) == 75)
        #expect(NativeLimitActuator.target(for: paused, mode: .heatPaused, policy: p, percent: 63.7) == 63)
        #expect(NativeLimitActuator.target(for: .stock, mode: .toppingUp, policy: p, percent: 90) == nil)
        #expect(NativeLimitActuator.target(for: .stock, mode: .charging, policy: .stock, percent: 50) == nil)
        #expect(NativeLimitActuator.target(for: paused, mode: .heatPaused, policy: p, percent: 3) == 20, "clamped to the minimum")
    }

    @Test func nativeLimitRestoresOriginalPreferences() throws {
        let smc = FakeSMC(["CHIE": [0x08]])
        let prefs = FakePrefs()
        prefs.store = ["enabled": true]          // user had OBC on, no MCL configured
        let a = NativeLimitActuator(smc: smc, prefs: prefs)
        try a.apply(ChargeOutputs(allowCharging: false, discharge: true), mode: .discharging, policy: ChargePolicy(limit: 60), percent: 90)
        #expect(smc.values["CHIE"] == [0x08])
        try a.restoreStock()
        #expect(prefs.store["enabled"] as? Bool == true)
        #expect(prefs.store["mclLimitValue"] == nil && prefs.store["MCLFeatureState"] == nil)
        #expect(smc.values["CHIE"] == [0x00], "adapter re-enabled")
        try a.restoreStock() // idempotent
    }

    @Test func nativeLimitSyncFailureThrows() {
        let prefs = FakePrefs()
        prefs.syncOK = false
        let a = NativeLimitActuator(smc: FakeSMC(["CHIE": [0]]), prefs: prefs)
        #expect(throws: ChargeControlError.self) {
            try a.apply(ChargeOutputs(allowCharging: false, discharge: false), mode: .holding, policy: ChargePolicy(), percent: 80)
        }
    }
}

/// SMC fake for float keys (fans).
final class FakeFloatSMC: SMCAccess, @unchecked Sendable {
    var floats: [SMCKey: Float]
    init(_ f: [String: Float]) { floats = Dictionary(uniqueKeysWithValues: f.map { (SMCKey($0.key), $0.value) }) }
    func info(_ key: SMCKey) -> SMCKeyInfo? { floats[key] == nil ? nil : SMCKeyInfo(size: 4, type: .flt, attributes: 0x80) }
    func read(_ key: SMCKey) throws(SMCError) -> SMCValue {
        guard let v = floats[key], let i = info(key) else { throw .keyNotFound(key) }
        return SMCValue(info: i, bytes: withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) })
    }
    func write(_ key: SMCKey, bytes: [UInt8]) throws(SMCError) { throw .writeFailed(key, 1, firmwareResult: 0) }
}

@Suite struct FanAndAccessoryTests {
    @Test func fanlessMacHasNoSampler() {
        #expect(FanSampler(smc: FakeFloatSMC([:])) == nil)
        #expect(FanSampler(smc: FakeFloatSMC(["FNum": 0])) == nil)
    }

    @Test func readsTwoFans() {
        let smc = FakeFloatSMC(["FNum": 2, "F0Ac": 1800, "F0Mn": 1200, "F0Mx": 6000, "F1Ac": 2400, "F1Mn": 1200, "F1Mx": 6000])
        let s = FanSampler(smc: smc)!
        s.sample(tick: 0)
        #expect(s.latest.map(\.rpm) == [1800, 2400])
        #expect(abs((s.latest[0].fraction ?? 0) - 0.125) < 1e-9)
    }

    @Test func accessoryKinds() {
        #expect(AccessorySampler.kind(for: "Magic Keyboard with Touch ID") == .keyboard)
        #expect(AccessorySampler.kind(for: "Kamal’s AirPods Pro") == .headphones)
        #expect(AccessorySampler.kind(for: "DUALSHOCK 4 Wireless Controller") == .gamepad)
        #expect(AccessorySampler.kind(for: "Magic Trackpad") == .trackpad)
        #expect(AccessorySampler.kind(for: "Something") == .other)
    }

    @Test func hidScanDoesNotCrashWithoutDevices() {
        let s = AccessorySampler(includeBluetooth: false)
        s.sample(tick: 0)
        #expect(s.latest.allSatisfy { (0...100).contains($0.percent) })
    }
}

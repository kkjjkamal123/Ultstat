import Foundation
import Testing
import UltstatCore
@testable import UltstatKit

@Suite struct AlertEngineTests {
    private func cpu(_ pct: Double) -> Readings {
        var r = Readings()
        r.cpu = CPULoad(total: Float(pct / 100), user: 0, system: 0, perCore: [], performance: nil, efficiency: nil)
        return r
    }

    private let t0 = Date(timeIntervalSince1970: 0)

    @Test func sustainsBeforeFiringAndFiresOnce() {
        var e = AlertEngine()
        let rule = AlertRule(metric: .cpuAbove, threshold: 90, sustain: 30)
        #expect(e.evaluate([rule], readings: cpu(95), now: t0).isEmpty)
        #expect(e.evaluate([rule], readings: cpu(96), now: t0 + 29).isEmpty)
        #expect(e.evaluate([rule], readings: cpu(97), now: t0 + 30).count == 1)
        #expect(e.evaluate([rule], readings: cpu(99), now: t0 + 60).isEmpty, "once per excursion")
    }

    @Test func spikeShorterThanSustainNeverFires() {
        var e = AlertEngine()
        let rule = AlertRule(metric: .cpuAbove, threshold: 90, sustain: 30)
        _ = e.evaluate([rule], readings: cpu(95), now: t0)
        _ = e.evaluate([rule], readings: cpu(50), now: t0 + 10)
        #expect(e.evaluate([rule], readings: cpu(95), now: t0 + 35).isEmpty, "the sustain clock restarted")
    }

    @Test func hysteresisPreventsFlapping() {
        var e = AlertEngine()
        let rule = AlertRule(metric: .cpuAbove, threshold: 90)
        #expect(e.evaluate([rule], readings: cpu(91), now: t0).count == 1)
        _ = e.evaluate([rule], readings: cpu(85), now: t0 + 1)       // dipped, not recovered (needs ≤ 80)
        #expect(e.evaluate([rule], readings: cpu(91), now: t0 + 2).isEmpty)
        _ = e.evaluate([rule], readings: cpu(79), now: t0 + 3)       // recovered
        #expect(e.evaluate([rule], readings: cpu(91), now: t0 + 4).count == 1)
    }

    @Test func belowRulesAndMissingData() {
        var e = AlertEngine()
        let rule = AlertRule(metric: .batteryBelow, threshold: 20)
        #expect(e.evaluate([rule], readings: Readings(), now: t0).isEmpty, "no battery data: no alert")
        var r = Readings()
        r.battery = BatterySnapshot(percent: 19, hardwarePercent: nil, isCharging: false, externalConnected: false, fullyCharged: false,
                                    amperage: -500, voltage: 12_000, cycleCount: 1, designCapacity: 5000, fullChargeCapacity: nil,
                                    nominalChargeCapacity: nil, remainingCapacity: nil, minutesToEmpty: nil, minutesToFull: nil,
                                    notChargingReason: nil, adapter: nil, flow: nil)
        let f = e.evaluate([rule], readings: r, now: t0)
        #expect(f.count == 1)
        #expect(f.first?.title == "Battery below 20%")
        #expect(f.first?.body == "Now 19%.")
    }

    @Test func disabledAndRemovedRules() {
        var e = AlertEngine()
        var rule = AlertRule(metric: .cpuAbove, threshold: 10)
        rule.enabled = false
        #expect(e.evaluate([rule], readings: cpu(50), now: t0).isEmpty)
        rule.enabled = true
        #expect(e.evaluate([rule], readings: cpu(50), now: t0).count == 1)
        #expect(e.evaluate([], readings: cpu(50), now: t0 + 1).isEmpty)
        #expect(e.evaluate([rule], readings: cpu(50), now: t0 + 2).count == 1, "removed rule's state is forgotten")
    }
}

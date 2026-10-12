import Testing
import UltstatCore
@testable import UltstatKit

@Suite struct BatteryTimeTests {
    private func snap(plugged: Bool, charging: Bool, amps: Int, toEmpty: Int? = nil, toFull: Int? = nil,
                      remaining: Int? = 3000, full: Int? = 5600, fully: Bool = false) -> BatterySnapshot {
        BatterySnapshot(percent: 50, hardwarePercent: nil, isCharging: charging, externalConnected: plugged, fullyCharged: fully,
                        amperage: amps, voltage: 12_000, cycleCount: 1, designCapacity: 5760, fullChargeCapacity: full,
                        nominalChargeCapacity: nil, remainingCapacity: remaining, minutesToEmpty: toEmpty, minutesToFull: toFull,
                        notChargingReason: nil, adapter: nil, flow: nil)
    }

    @Test func usesMacOSEstimateWhenPresent() {
        #expect(BatteryTime.short(snap(plugged: false, charging: false, amps: -900, toEmpty: 185)) == "3h 05m left")
        #expect(BatteryTime.short(snap(plugged: true, charging: true, amps: 2000, toFull: 42)) == "Full in 42m")
    }

    @Test func derivesEstimateFromGaugeWhenMissing() {
        // 3000 mAh at 1000 mA = 3 h.
        #expect(BatteryTime.minutes(snap(plugged: false, charging: false, amps: -1000))?.minutes == 180)
        // (5600 - 3000) mAh at 2600 mA = 1 h to full.
        #expect(BatteryTime.short(snap(plugged: true, charging: true, amps: 2600)) == "Full in 1h 00m")
    }

    @Test func pluggedNotChargingStates() {
        #expect(BatteryTime.short(snap(plugged: true, charging: false, amps: 0)) == "Plugged in")
        #expect(BatteryTime.short(snap(plugged: true, charging: false, amps: 0, fully: true)) == "Charged")
        #expect(BatteryTime.short(snap(plugged: false, charging: false, amps: -10)) == "On battery", "no load: no estimate")
    }

    @Test func absurdEstimatesAreHidden() {
        #expect(BatteryTime.short(snap(plugged: false, charging: false, amps: -1, toEmpty: 60 * 100)) == "On battery")
    }

    @Test func dischargingWhilePluggedShowsTimeLeft() {
        // Adapter bypassed by a charge limiter: plugged in, but the battery drains.
        let b = snap(plugged: true, charging: false, amps: -1000)
        #expect(BatteryTime.minutes(b)?.minutes == 180)
        #expect(BatteryTime.short(b) == "3h 00m left")
        #expect(BatteryTime.compact(b) == "3:00")
    }

    @Test func compactPlaceholder() {
        #expect(BatteryTime.compact(snap(plugged: true, charging: false, amps: 0)) == "--")
        #expect(BatteryTime.compact(snap(plugged: false, charging: false, amps: -900, toEmpty: 65)) == "1:05")
    }
}

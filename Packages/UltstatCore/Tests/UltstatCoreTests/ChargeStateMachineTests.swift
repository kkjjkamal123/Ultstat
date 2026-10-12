import Foundation
import Testing
@testable import UltstatCore

@Suite struct ChargeStateMachineTests {
    private func run(_ m: inout ChargeStateMachine, _ p: ChargePolicy, _ pct: Double,
                     plugged: Bool = true, temp: Double? = nil) -> ChargeOutputs {
        m.step(policy: p, inputs: ChargeInputs(percent: pct, externalConnected: plugged, batteryTemperature: temp))
    }

    @Test func chargesBelowLimitAndHoldsAtLimit() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 80, sailingRange: 0)
        #expect(run(&m, p, 50) == .stock)
        #expect(m.mode == .charging)
        #expect(run(&m, p, 80) == ChargeOutputs(allowCharging: false, discharge: false))
        #expect(m.mode == .holding)
        #expect(run(&m, p, 85) == ChargeOutputs(allowCharging: false, discharge: false), "above limit without discharge just holds")
    }

    @Test func sailingWaitsForTheFullRange() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 80, sailingRange: 5)
        _ = run(&m, p, 80)
        #expect(m.mode == .holding)
        for pct in [79.0, 77, 75.5] {
            #expect(run(&m, p, pct).allowCharging == false)
            #expect(m.mode == .sailing)
        }
        #expect(run(&m, p, 75) == .stock, "at limit − range charging resumes")
        #expect(m.mode == .charging)
        #expect(run(&m, p, 78).allowCharging, "once charging, keep charging up to the limit")
    }

    @Test func sailingDoesNotTriggerFromAFreshPlugIn() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 80, sailingRange: 5)
        _ = run(&m, p, 78, plugged: false)
        #expect(run(&m, p, 78).allowCharging, "plugging in below the limit charges immediately")
    }

    @Test func dischargesDownToLimitThenHolds() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 60, sailingRange: 0, dischargeAboveLimit: true)
        #expect(run(&m, p, 95) == ChargeOutputs(allowCharging: false, discharge: true))
        #expect(m.mode == .discharging)
        #expect(run(&m, p, 60.5).discharge)
        #expect(run(&m, p, 60) == ChargeOutputs(allowCharging: false, discharge: false))
        #expect(m.mode == .holding)
    }

    @Test func unplugAlwaysRestoresStock() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 60, dischargeAboveLimit: true)
        _ = run(&m, p, 90)
        #expect(m.mode == .discharging)
        #expect(run(&m, p, 90, plugged: false) == .stock, "never leave the adapter disabled when unplugged")
        #expect(m.mode == .onBattery)
    }

    @Test func heatProtectionWithHysteresis() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 100, heatProtection: 40)
        #expect(run(&m, p, 50, temp: 39.9).allowCharging)
        #expect(!run(&m, p, 50, temp: 40).allowCharging)
        #expect(m.mode == .heatPaused)
        #expect(!run(&m, p, 50, temp: 38.5).allowCharging, "within hysteresis stays paused")
        #expect(run(&m, p, 50, temp: 38).allowCharging)
        #expect(m.mode == .charging)
    }

    @Test func heatBeatsTopUp() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 80, heatProtection: 35, topUp: true)
        #expect(!run(&m, p, 90, temp: 36).allowCharging)
        #expect(m.mode == .heatPaused)
    }

    @Test func topUpChargesToFullThenReportsCompletion() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 80, topUp: true)
        #expect(run(&m, p, 85) == .stock)
        #expect(m.mode == .toppingUp)
        #expect(!m.topUpCompleted)
        #expect(!run(&m, p, 100).allowCharging)
        #expect(m.topUpCompleted)
    }

    @Test func limit100IsStock() {
        var m = ChargeStateMachine()
        #expect(run(&m, .stock, 99) == .stock)
        #expect(run(&m, .stock, 100) == .stock)
    }

    @Test func validationClampsHostileInput() {
        let p = ChargePolicy(limit: -5, sailingRange: 500, heatProtection: .nan, magSafeLED: 99).validated()
        #expect(p.limit == 20)
        #expect(p.sailingRange == 0, "range ≥ limit is meaningless and disabled")
        #expect(p.heatProtection == nil)
        #expect(p.magSafeLED == 0)
        #expect(ChargePolicy(limit: 250).validated().limit == 100)
        #expect(ChargePolicy(heatProtection: 10).validated().heatProtection == 30)
    }

    /// Exhaustive sweep: no input combination may leave discharge on while unplugged,
    /// or both allow charging and discharge at once.
    @Test func invariantsHoldForEveryInput() {
        for limit in stride(from: 20, through: 100, by: 10) {
            for range in [0, 3, 10] {
                for discharge in [false, true] {
                    for heat in [nil, 40.0] {
                        for topUp in [false, true] {
                            let p = ChargePolicy(limit: limit, sailingRange: range, dischargeAboveLimit: discharge,
                                                 heatProtection: heat, topUp: topUp)
                            var m = ChargeStateMachine()
                            for pct in stride(from: 0.0, through: 100, by: 2.5) {
                                for plugged in [true, false] {
                                    for temp in [30.0, 41.0] {
                                        let o = run(&m, p, pct, plugged: plugged, temp: temp)
                                        #expect(!(o.allowCharging && o.discharge))
                                        if !plugged { #expect(o == .stock) }
                                        if o.discharge { #expect(pct > Double(limit)) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Suite struct CalibrationTests {
    @Test func fullCycle() {
        var m = ChargeStateMachine()
        var p = ChargePolicy(limit: 80, calibration: .discharging)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func step(_ pct: Double, plugged: Bool = true, at t: Date = t0) -> ChargeOutputs {
            let o = m.step(policy: p, inputs: ChargeInputs(percent: pct, externalConnected: plugged), now: t)
            if m.calibrationChanged { p.calibration = m.nextCalibration }
            return o
        }
        #expect(step(90) == ChargeOutputs(allowCharging: false, discharge: true))
        #expect(m.mode == .calibrating)
        #expect(step(15) == .stock)
        #expect(p.calibration == .charging)
        #expect(step(60).allowCharging)
        _ = step(100)
        #expect(p.calibration == .holding(until: t0.addingTimeInterval(3600)))
        #expect(step(100, at: t0.addingTimeInterval(1800)) == .stock, "holds at 100 % for the full hour")
        _ = step(100, at: t0.addingTimeInterval(3600))
        #expect(p.calibration == nil, "finished")
        #expect(!step(100).allowCharging, "normal 80 % limit resumes")
    }

    @Test func dischargePhaseAdvancesOnBattery() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 80, calibration: .discharging)
        #expect(m.step(policy: p, inputs: ChargeInputs(percent: 14, externalConnected: false)) == .stock)
        #expect(m.calibrationChanged && m.nextCalibration == .charging)
    }

    @Test func heatStillWinsDuringCalibration() {
        var m = ChargeStateMachine()
        let p = ChargePolicy(limit: 80, heatProtection: 40, calibration: .charging)
        #expect(!m.step(policy: p, inputs: ChargeInputs(percent: 50, externalConnected: true, batteryTemperature: 42)).allowCharging)
        #expect(m.mode == .heatPaused)
    }

    @Test func calibrationPolicyRoundTrips() throws {
        let p = ChargePolicy(calibration: .holding(until: Date(timeIntervalSince1970: 42)))
        let d = try PropertyListEncoder().encode(p)
        #expect(try PropertyListDecoder().decode(ChargePolicy.self, from: d) == p)
    }
}

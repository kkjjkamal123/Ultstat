import Foundation

public enum ChargeMode: String, Codable, Sendable {
    /// No charger connected; nothing to control.
    case onBattery
    /// Charging normally (below limit, or limiting disabled).
    case charging
    /// At the limit; charging paused, running from the adapter.
    case holding
    /// Above `limit - sailingRange` after reaching the limit; waiting before charging resumes.
    case sailing
    /// Adapter bypassed; battery powering the Mac down to the limit.
    case discharging
    /// Charging paused because the battery is too hot.
    case heatPaused
    /// One-shot charge to 100 %.
    case toppingUp
    /// Calibration cycle in progress.
    case calibrating
    /// Charging paused at the current level (used while the helper can't supervise, e.g. asleep).
    case frozen
}

public struct ChargeInputs: Equatable, Sendable {
    public var percent: Double
    public var externalConnected: Bool
    public var batteryTemperature: Double?

    public init(percent: Double, externalConnected: Bool, batteryTemperature: Double? = nil) {
        self.percent = percent
        self.externalConnected = externalConnected
        self.batteryTemperature = batteryTemperature
    }
}

/// Desired actuator state. Hardware back ends translate this to SMC writes or the native limit.
public struct ChargeOutputs: Equatable, Sendable {
    public var allowCharging: Bool
    public var discharge: Bool

    public init(allowCharging: Bool, discharge: Bool) {
        self.allowCharging = allowCharging
        self.discharge = discharge
    }

    public static let stock = ChargeOutputs(allowCharging: true, discharge: false)
}

/// Pure, deterministic charging policy. No I/O; every transition is unit-tested.
public struct ChargeStateMachine: Sendable {
    /// Degrees below the heat threshold before charging resumes (prevents flapping).
    public static let heatHysteresis = 2.0

    public private(set) var mode: ChargeMode = .charging
    /// Set when a top-up completes so the owner can clear `policy.topUp` and persist it.
    public private(set) var topUpCompleted = false
    /// Set when the calibration phase changed; the owner persists `nextCalibration`.
    public private(set) var calibrationChanged = false
    /// The calibration phase after this step (nil once finished).
    public private(set) var nextCalibration: CalibrationPhase?

    public init(mode: ChargeMode = .charging) { self.mode = mode }

    public mutating func step(policy raw: ChargePolicy, inputs: ChargeInputs, now: Date = Date()) -> ChargeOutputs {
        let policy = raw.validated()
        topUpCompleted = false
        calibrationChanged = false
        nextCalibration = policy.calibration
        let pct = inputs.percent
        let limit = Double(policy.limit)

        guard inputs.externalConnected else {
            // On battery the pack discharges by itself, which also advances calibration.
            if case .discharging = policy.calibration, inputs.percent <= CalibrationPhase.floor {
                advance(to: .charging)
            }
            mode = .onBattery
            return .stock
        }

        // Heat protection outranks everything, including top-up: a hot battery is never pushed
        // to 100 %. Hysteresis keeps charging paused until it has cooled by `heatHysteresis`.
        if let threshold = policy.heatProtection, let t = inputs.batteryTemperature {
            if t >= threshold || (mode == .heatPaused && t > threshold - Self.heatHysteresis) {
                mode = .heatPaused
                return ChargeOutputs(allowCharging: false, discharge: false)
            }
        }

        if let phase = policy.calibration {
            return calibrate(phase, inputs: inputs, now: now)
        }

        if policy.topUp {
            if pct >= 100 {
                topUpCompleted = true
                mode = .holding
                return ChargeOutputs(allowCharging: false, discharge: false)
            }
            mode = .toppingUp
            return .stock
        }

        guard policy.isLimiting else {
            mode = .charging
            return .stock
        }

        if pct > limit, policy.dischargeAboveLimit {
            mode = .discharging
            return ChargeOutputs(allowCharging: false, discharge: true)
        }

        if pct >= limit {
            mode = .holding
            return ChargeOutputs(allowCharging: false, discharge: false)
        }

        // Below the limit. Sail if we came from a paused state and haven't dropped far enough.
        let wasPaused = [.holding, .sailing, .discharging, .heatPaused].contains(mode)
        if wasPaused, policy.sailingRange > 0, pct > limit - Double(policy.sailingRange) {
            mode = .sailing
            return ChargeOutputs(allowCharging: false, discharge: false)
        }

        mode = .charging
        return .stock
    }

    // MARK: Sleep

    /// What to apply before the system sleeps, when the helper is frozen and can't react to the
    /// battery. Never discharges; never blocks a top-up or the charging part of a calibration.
    public static func sleepPlan(policy raw: ChargePolicy) -> (outputs: ChargeOutputs, mode: ChargeMode) {
        let policy = raw.validated()
        switch policy.calibration {
        case .charging, .holding: return (.stock, .calibrating)
        case .discharging: return (ChargeOutputs(allowCharging: false, discharge: false), .frozen)
        case nil: break
        }
        if policy.topUp { return (.stock, .toppingUp) }
        guard policy.isLimiting else { return (.stock, .charging) }
        return (ChargeOutputs(allowCharging: false, discharge: false), .holding)
    }

    // MARK: Calibration

    private mutating func advance(to phase: CalibrationPhase?) {
        nextCalibration = phase
        calibrationChanged = true
    }

    private mutating func calibrate(_ phase: CalibrationPhase, inputs: ChargeInputs, now: Date) -> ChargeOutputs {
        mode = .calibrating
        switch phase {
        case .discharging:
            if inputs.percent <= CalibrationPhase.floor {
                advance(to: .charging)
                return .stock
            }
            return ChargeOutputs(allowCharging: false, discharge: true)
        case .charging:
            if inputs.percent >= 100 {
                advance(to: .holding(until: now.addingTimeInterval(CalibrationPhase.holdDuration)))
            }
            return .stock
        case .holding(let until):
            if now >= until {
                advance(to: nil)   // done; the next step applies the normal limit
                mode = .holding
                return ChargeOutputs(allowCharging: false, discharge: false)
            }
            return .stock
        }
    }
}

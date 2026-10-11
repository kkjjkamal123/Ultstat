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

    public init(mode: ChargeMode = .charging) { self.mode = mode }

    public mutating func step(policy raw: ChargePolicy, inputs: ChargeInputs) -> ChargeOutputs {
        let policy = raw.validated()
        topUpCompleted = false
        let pct = inputs.percent
        let limit = Double(policy.limit)

        guard inputs.externalConnected else {
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
}

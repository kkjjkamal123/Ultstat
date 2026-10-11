/// What the user asked for. Always pass through `validated()` before acting on it.
public struct ChargePolicy: Codable, Equatable, Sendable {
    /// Upper limit in percent. 100 disables limiting.
    public var limit: Int
    /// Sailing: once at `limit`, don't resume charging until the battery drops below `limit - sailingRange`.
    public var sailingRange: Int
    /// Actively discharge (adapter bypassed) while above `limit`.
    public var dischargeAboveLimit: Bool
    /// Pause charging while the battery is at or above this temperature (°C). nil = off.
    public var heatProtection: Double?
    /// One-shot charge to 100 %. Cleared once reached.
    public var topUp: Bool
    /// Use the gauge's measured charge instead of the percentage macOS displays.
    public var useHardwarePercent: Bool
    /// MagSafe LED: 0 system default, 1 off, 3 green, 4 amber.
    public var magSafeLED: Int

    public init(limit: Int = 80, sailingRange: Int = 5, dischargeAboveLimit: Bool = false,
                heatProtection: Double? = nil, topUp: Bool = false, useHardwarePercent: Bool = false,
                magSafeLED: Int = 0) {
        self.limit = limit
        self.sailingRange = sailingRange
        self.dischargeAboveLimit = dischargeAboveLimit
        self.heatProtection = heatProtection
        self.topUp = topUp
        self.useHardwarePercent = useHardwarePercent
        self.magSafeLED = magSafeLED
    }

    public static let stock = ChargePolicy(limit: 100, sailingRange: 0)

    public static let limitRange = 20...100
    public static let heatRange = 30.0...50.0

    public func validated() -> ChargePolicy {
        var p = self
        p.limit = min(Self.limitRange.upperBound, max(Self.limitRange.lowerBound, p.limit))
        p.sailingRange = min(20, max(0, p.sailingRange))
        if p.sailingRange >= p.limit { p.sailingRange = 0 }
        if let h = p.heatProtection {
            p.heatProtection = h.isFinite ? min(Self.heatRange.upperBound, max(Self.heatRange.lowerBound, h)) : nil
        }
        if ![0, 1, 3, 4].contains(p.magSafeLED) { p.magSafeLED = 0 }
        return p
    }

    public var isLimiting: Bool { limit < 100 }
}

/// What the helper is doing right now.
public struct ChargeStatus: Codable, Equatable, Sendable {
    public enum Mechanism: String, Codable, Sendable {
        case nativeLimit      // macOS 26+ "Manual Charge Limit" via powerd preferences
        case smcTahoe         // CHTE / CHIE
        case smcLegacy        // CH0B / CH0C / CH0I
        case unsupported
    }

    public var mechanism: Mechanism
    public var mode: ChargeMode
    public var policy: ChargePolicy
    public var lastError: String?

    public init(mechanism: Mechanism, mode: ChargeMode, policy: ChargePolicy, lastError: String? = nil) {
        self.mechanism = mechanism
        self.mode = mode
        self.policy = policy
        self.lastError = lastError
    }
}

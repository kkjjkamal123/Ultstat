import Foundation
import UltstatCore

/// Human text for battery time remaining.
public enum BatteryTime {
    /// Minutes until empty (on battery) or full (charging). Uses macOS's estimate when it has one,
    /// otherwise derives one from the gauge: remaining (or missing) mAh ÷ current draw.
    public static func minutes(_ b: BatterySnapshot) -> (minutes: Int, toFull: Bool)? {
        // Discharging is decided by current flow, not the plug: a bypassed adapter (charge limiter
        // discharging to its limit) drains the battery while ExternalConnected stays true.
        if !b.externalConnected || b.amperage < -10 {
            if let m = b.minutesToEmpty, !b.externalConnected { return (m, false) }
            // Very light loads (tens of mA) are exactly when time remaining is longest; still estimate.
            guard b.amperage < -10, let remaining = b.remainingCapacity else { return nil }
            return (Int(Double(remaining) / Double(-b.amperage) * 60), false)
        }
        guard b.isCharging else { return nil }
        if let m = b.minutesToFull { return (m, true) }
        guard b.amperage > 10, let full = b.fullChargeCapacity, let remaining = b.remainingCapacity, full > remaining else { return nil }
        return (Int(Double(full - remaining) / Double(b.amperage) * 60), true)
    }

    /// Longest estimate shown (~41 days); beyond that the gauge's current reading is noise.
    static let maxMinutes = 60 * 999

    public static func format(minutes m: Int) -> String {
        let h = m / 60, mm = m % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", mm))m" : "\(mm)m"
    }

    /// On the adapter but not charging (held at a limit, or full): how long the battery would last
    /// at the current system load, like AlDente's "Time Remaining". `systemWatts` is the whole-Mac
    /// draw (SMC); without it the gauge's own system-load telemetry is used.
    public static func minutesAtCurrentLoad(_ b: BatterySnapshot, systemWatts: Double?) -> Int? {
        guard b.externalConnected, !b.isCharging, let remaining = b.remainingCapacity, remaining > 0, b.voltage > 0 else { return nil }
        guard let w = systemWatts ?? b.flow.map({ Double($0.systemLoad) / 1000 }), w > 0.3 else { return nil }
        let wattHours = Double(remaining) * Double(b.voltage) / 1_000_000
        let m = Int(wattHours / w * 60)
        return m > 0 && m <= maxMinutes ? m : nil
    }

    /// Menu-bar form, like AlDente: "3:05", or "--" without an estimate. While plugged in and not
    /// charging it shows the time the battery would last at the current load.
    public static func compact(_ b: BatterySnapshot, systemWatts: Double? = nil) -> String {
        let m = minutes(b).map(\.minutes) ?? minutesAtCurrentLoad(b, systemWatts: systemWatts)
        guard let m, m > 0, m <= maxMinutes else { return "--" }
        return "\(m / 60):\(String(format: "%02d", m % 60))"
    }

    /// Short line for the summary tile: "3h 05m left", "Full in 42m", "Plugged in".
    public static func short(_ b: BatterySnapshot) -> String {
        if let (m, toFull) = minutes(b), m > 0, m <= maxMinutes {
            return toFull ? "Full in \(format(minutes: m))" : "\(format(minutes: m)) left"
        }
        if !b.externalConnected { return "On battery" }
        if b.amperage < -10 { return "Discharging" }
        if b.isCharging { return "Charging" }
        return b.fullyCharged ? "Charged" : "Plugged in"
    }
}

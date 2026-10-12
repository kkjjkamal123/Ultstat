import Foundation
import UltstatCore

/// Human text for battery time remaining.
public enum BatteryTime {
    /// Minutes until empty (on battery) or full (charging). Uses macOS's estimate when it has one,
    /// otherwise derives one from the gauge: remaining (or missing) mAh ÷ current draw.
    public static func minutes(_ b: BatterySnapshot) -> (minutes: Int, toFull: Bool)? {
        // Discharging is decided by current flow, not the plug: a bypassed adapter (charge limiter
        // discharging to its limit) drains the battery while ExternalConnected stays true.
        if !b.externalConnected || b.amperage < -50 {
            if let m = b.minutesToEmpty, !b.externalConnected { return (m, false) }
            guard b.amperage < -50, let remaining = b.remainingCapacity else { return nil }
            return (Int(Double(remaining) / Double(-b.amperage) * 60), false)
        }
        guard b.isCharging else { return nil }
        if let m = b.minutesToFull { return (m, true) }
        guard b.amperage > 50, let full = b.fullChargeCapacity, let remaining = b.remainingCapacity, full > remaining else { return nil }
        return (Int(Double(full - remaining) / Double(b.amperage) * 60), true)
    }

    public static func format(minutes m: Int) -> String {
        let h = m / 60, mm = m % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", mm))m" : "\(mm)m"
    }

    /// Menu-bar form, like AlDente: "3:05", or "--" without an estimate.
    public static func compact(_ b: BatterySnapshot) -> String {
        guard let (m, _) = minutes(b), m > 0, m < 60 * 48 else { return "--" }
        return "\(m / 60):\(String(format: "%02d", m % 60))"
    }

    /// Short line for the summary tile: "3h 05m left", "Full in 42m", "Plugged in".
    public static func short(_ b: BatterySnapshot) -> String {
        if let (m, toFull) = minutes(b), m > 0, m < 60 * 48 {
            return toFull ? "Full in \(format(minutes: m))" : "\(format(minutes: m)) left"
        }
        if !b.externalConnected { return "On battery" }
        if b.amperage < -50 { return "Discharging" }
        if b.isCharging { return "Charging" }
        return b.fullyCharged ? "Charged" : "Plugged in"
    }
}

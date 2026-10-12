import Foundation
import UltstatCore

public struct AlertRule: Codable, Equatable, Identifiable, Sendable {
    public enum Metric: String, Codable, CaseIterable, Sendable {
        case cpuAbove, memoryAbove, temperatureAbove, batteryBelow, batteryAtLeast, diskFreeBelowGB

        public var title: String {
            switch self {
            case .cpuAbove: "CPU usage above"
            case .memoryAbove: "Memory usage above"
            case .temperatureAbove: "CPU temperature above"
            case .batteryBelow: "Battery below"
            case .batteryAtLeast: "Battery charged to"
            case .diskFreeBelowGB: "Free disk space below"
            }
        }

        public var unit: String {
            switch self {
            case .cpuAbove, .memoryAbove, .batteryBelow, .batteryAtLeast: "%"
            case .temperatureAbove: "°C"
            case .diskFreeBelowGB: "GB"
            }
        }

        /// How far the value must recover before the rule can fire again.
        var hysteresis: Double {
            switch self {
            case .cpuAbove, .memoryAbove: 10
            case .temperatureAbove: 5
            case .batteryBelow, .batteryAtLeast: 3
            case .diskFreeBelowGB: 2
            }
        }

        /// The menu-bar item whose sampler must run for this rule (nil: event-driven, always available).
        public var requiredItem: MenuBarItem? {
            switch self {
            case .cpuAbove: .cpu
            case .memoryAbove: .memory
            case .temperatureAbove: .temperature
            case .diskFreeBelowGB: .disk
            case .batteryBelow, .batteryAtLeast: nil
            }
        }
    }

    public var id: UUID
    public var metric: Metric
    public var threshold: Double
    /// Seconds the condition must hold before firing (0 = immediately).
    public var sustain: TimeInterval
    public var enabled: Bool

    public init(id: UUID = UUID(), metric: Metric, threshold: Double, sustain: TimeInterval = 0, enabled: Bool = true) {
        self.id = id
        self.metric = metric
        self.threshold = threshold
        self.sustain = sustain
        self.enabled = enabled
    }
}

public struct AlertFiring: Equatable, Sendable {
    public var rule: AlertRule
    public var value: Double

    public var title: String { "\(rule.metric.title) \(Int(rule.threshold))\(rule.metric.unit)" }
    public var body: String {
        let v = rule.metric == .diskFreeBelowGB ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return "Now \(v)\(rule.metric.unit)."
    }
}

/// Decides when rules fire. Pure: time is passed in, no I/O.
public struct AlertEngine: Sendable {
    private struct RuleState: Sendable {
        var conditionSince: Date?
        var armed = true
    }

    private var states: [UUID: RuleState] = [:]

    public init() {}

    public static func value(of metric: AlertRule.Metric, in r: Readings) -> Double? {
        switch metric {
        case .cpuAbove: r.cpu.map { Double($0.total) * 100 }
        case .memoryAbove: r.memory.map { Double($0.usedFraction) * 100 }
        case .temperatureAbove: (r.sensors[.cpuPerformance]?.max ?? r.sensors[.cpuEfficiency]?.max).map(Double.init)
        case .batteryBelow, .batteryAtLeast: r.battery.map { Double($0.percent) }
        case .diskFreeBelowGB: r.disk.map { Double($0.available) / 1e9 }
        }
    }

    static func isTriggered(_ m: AlertRule.Metric, value v: Double, threshold t: Double) -> Bool {
        switch m {
        case .cpuAbove, .memoryAbove, .temperatureAbove: v > t
        case .batteryAtLeast: v >= t
        case .batteryBelow, .diskFreeBelowGB: v < t
        }
    }

    static func hasRecovered(_ m: AlertRule.Metric, value v: Double, threshold t: Double) -> Bool {
        switch m {
        case .cpuAbove, .memoryAbove, .temperatureAbove, .batteryAtLeast: v <= t - m.hysteresis
        case .batteryBelow, .diskFreeBelowGB: v >= t + m.hysteresis
        }
    }

    /// Returns the rules that fire now. Each rule fires once per excursion.
    public mutating func evaluate(_ rules: [AlertRule], readings: Readings, now: Date) -> [AlertFiring] {
        var fired: [AlertFiring] = []
        let live = Set(rules.map(\.id))
        states = states.filter { live.contains($0.key) }
        for rule in rules where rule.enabled {
            guard let v = Self.value(of: rule.metric, in: readings) else { continue }
            var s = states[rule.id] ?? RuleState()
            if Self.isTriggered(rule.metric, value: v, threshold: rule.threshold) {
                if s.conditionSince == nil { s.conditionSince = now }
                if s.armed, let since = s.conditionSince, now.timeIntervalSince(since) >= rule.sustain {
                    fired.append(AlertFiring(rule: rule, value: v))
                    s.armed = false
                }
            } else {
                s.conditionSince = nil
                if !s.armed, Self.hasRecovered(rule.metric, value: v, threshold: rule.threshold) { s.armed = true }
            }
            states[rule.id] = s
        }
        return fired
    }
}

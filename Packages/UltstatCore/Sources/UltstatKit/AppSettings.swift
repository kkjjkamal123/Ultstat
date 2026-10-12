import Foundation
import Observation
import UltstatCore

public enum MenuBarItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, network, disk, temperature, power, battery

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .temperature: "Temperature"
        case .power: "Power"
        case .battery: "Battery"
        }
    }

    /// Plain name shown before the value in the menu bar ("CPU 8%").
    public var shortName: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "RAM"
        case .network: "NET"
        case .disk: "DISK"
        case .temperature: "TEMP"
        case .power: "POWER"
        case .battery: "BAT"
        }
    }

    public var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .temperature: "thermometer.medium"
        case .power: "bolt"
        case .battery: "battery.75percent"
        }
    }
}

public enum WidgetStyle: String, Codable, CaseIterable, Sendable {
    /// Caption above the value ("CPU" over "7%"), the compact default.
    case labeled
    case text, bar, sparkline
}

/// What precedes each value in the menu bar.
public enum ItemLabel: String, Codable, CaseIterable, Sendable {
    case name, icon, none
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit

    public func format(_ c: Float) -> String {
        switch self {
        case .celsius: String(format: "%.0f°", c)
        case .fahrenheit: String(format: "%.0f°", c * 9 / 5 + 32)
        }
    }
}

/// User preferences, persisted to UserDefaults as one property list blob (one write per change).
@MainActor @Observable
public final class AppSettings {
    public struct Stored: Codable, Equatable, Sendable {
        public init() {}

        public init(items: [MenuBarItem]) {
            self.items = items
        }

        public var items: [MenuBarItem] = [.cpu, .gpu, .memory, .temperature, .power, .battery]
        public var styles: [MenuBarItem: WidgetStyle] = [:]   // every item defaults to plain text ("CPU 8%")
        /// Refresh interval in seconds (fractional: 0.6 = 600 ms).
        public var interval: Double = 0.6
        public var temperatureUnit: TemperatureUnit = .celsius
        public var itemLabel: ItemLabel = .name
        public var chargePolicy = ChargePolicy(limit: 80, sailingRange: 5)
        public var chargeControlEnabled = false
        /// Refresh no faster than every 2 s while macOS Low Power Mode is on.
        public var slowInLowPowerMode = false
        public var bluetoothAccessories = false
        /// One macOS status item per metric. Off (default): every metric is drawn in a single item with
        /// `itemSpacing` between them, because macOS puts a wide fixed gap between separate items.
        public var separateItems = false
        /// Gap between metrics in the single item, in points.
        public var itemSpacing: Double = 4   // Stats: 2 pt padding each side of a module
        public static let itemSpacingRange = 0.0...20.0
        public var alerts: [AlertRule] = [
            // Fixed IDs: defaults must be identical every time they are created.
            AlertRule(id: UUID(uuidString: "6D7C3A10-0001-4C6E-9B1D-000000000001")!,
                      metric: .batteryBelow, threshold: 15, enabled: false),
            AlertRule(id: UUID(uuidString: "6D7C3A10-0002-4C6E-9B1D-000000000002")!,
                      metric: .temperatureAbove, threshold: 95, sustain: 30, enabled: false),
            AlertRule(id: UUID(uuidString: "6D7C3A10-0003-4C6E-9B1D-000000000003")!,
                      metric: .cpuAbove, threshold: 90, sustain: 60, enabled: false),
        ]

        private enum CodingKeys: String, CodingKey {
            case items, styles, interval, temperatureUnit, itemLabel, chargePolicy, chargeControlEnabled,
                 slowInLowPowerMode, bluetoothAccessories, alerts, separateItems, itemSpacing
        }

        /// Every field falls back to its default, so adding a setting never discards a user's saved ones
        /// (the synthesized decoder throws on any missing key).
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Stored()
            items = (try? c.decodeIfPresent([MenuBarItem].self, forKey: .items)) ?? d.items
            styles = (try? c.decodeIfPresent([MenuBarItem: WidgetStyle].self, forKey: .styles)) ?? d.styles
            // Older versions stored whole seconds as Int; Double decoding accepts both.
            interval = (try? c.decodeIfPresent(Double.self, forKey: .interval)).flatMap { $0 }.map { min(max($0, 0.5), 10) } ?? d.interval
            temperatureUnit = (try? c.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit)) ?? d.temperatureUnit
            itemLabel = (try? c.decodeIfPresent(ItemLabel.self, forKey: .itemLabel)) ?? d.itemLabel
            chargePolicy = (try? c.decodeIfPresent(ChargePolicy.self, forKey: .chargePolicy)) ?? d.chargePolicy
            chargeControlEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .chargeControlEnabled)) ?? d.chargeControlEnabled
            slowInLowPowerMode = (try? c.decodeIfPresent(Bool.self, forKey: .slowInLowPowerMode)) ?? d.slowInLowPowerMode
            bluetoothAccessories = (try? c.decodeIfPresent(Bool.self, forKey: .bluetoothAccessories)) ?? d.bluetoothAccessories
            alerts = (try? c.decodeIfPresent([AlertRule].self, forKey: .alerts)) ?? d.alerts
            separateItems = (try? c.decodeIfPresent(Bool.self, forKey: .separateItems)) ?? d.separateItems
            itemSpacing = (try? c.decodeIfPresent(Double.self, forKey: .itemSpacing))
                .flatMap { $0 }.map { min(max($0, Self.itemSpacingRange.lowerBound), Self.itemSpacingRange.upperBound) } ?? d.itemSpacing
        }
    }

    private static let key = "settings.v1"
    private let defaults: UserDefaults

    public var stored: Stored {
        didSet { if stored != oldValue { save() } }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let s = try? PropertyListDecoder().decode(Stored.self, from: data) {
            stored = s
        } else {
            stored = Stored()
        }
        // `-UltstatItems cpu,memory` (or `none`) overrides the menu-bar items for this launch only.
        // Used by UI tests and power measurements; never written back.
        if let override = defaults.string(forKey: "UltstatItems") {
            overrideItems = override == "none" ? [] : override.split(separator: ",").compactMap { MenuBarItem(rawValue: String($0)) }
            stored.items = overrideItems!
        }
        // `-UltstatStyles cpu:sparkline,memory:bar` overrides widget styles for this launch only.
        if let styles = defaults.string(forKey: "UltstatStyles") {
            overrideItems = overrideItems ?? stored.items
            for pair in styles.split(separator: ",") {
                let kv = pair.split(separator: ":").map(String.init)
                if kv.count == 2, let item = MenuBarItem(rawValue: kv[0]), let style = WidgetStyle(rawValue: kv[1]) {
                    stored.styles[item] = style
                }
            }
        }
    }

    @ObservationIgnored private var overrideItems: [MenuBarItem]?

    public func style(for item: MenuBarItem) -> WidgetStyle { stored.styles[item] ?? .text }

    public func isEnabled(_ item: MenuBarItem) -> Bool { stored.items.contains(item) }

    public func toggle(_ item: MenuBarItem) {
        if let i = stored.items.firstIndex(of: item) {
            stored.items.remove(at: i)
        } else {
            let order = MenuBarItem.allCases
            let insertAt = stored.items.firstIndex { order.firstIndex(of: $0)! > order.firstIndex(of: item)! } ?? stored.items.endIndex
            stored.items.insert(item, at: insertAt)
        }
    }

    public func resetToDefaults() { stored = Stored() }

    /// The sampling interval to use now: the chosen one, or at least 2 s in Low Power Mode when asked.
    public func effectiveInterval(lowPowerMode: Bool) -> Double {
        stored.slowInLowPowerMode && lowPowerMode ? max(stored.interval, 2) : stored.interval
    }

    private func save() {
        guard overrideItems == nil else { return }
        if let data = try? PropertyListEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}

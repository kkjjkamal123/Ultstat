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

    public var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
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
    case text, bar, sparkline
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

        public var items: [MenuBarItem] = [.cpu, .memory, .temperature, .battery]
        public var styles: [MenuBarItem: WidgetStyle] = [.cpu: .text, .memory: .text]
        public var interval: Int = 2
        public var temperatureUnit: TemperatureUnit = .celsius
        public var showIcons: Bool = true
        public var chargePolicy = ChargePolicy(limit: 80, sailingRange: 5)
        public var chargeControlEnabled = false
        public var lowPowerSampling = true
        public var bluetoothAccessories = false
        public var alerts: [AlertRule] = [
            // Fixed IDs: defaults must be identical every time they are created.
            AlertRule(id: UUID(uuidString: "6D7C3A10-0001-4C6E-9B1D-000000000001")!,
                      metric: .batteryBelow, threshold: 15, enabled: false),
            AlertRule(id: UUID(uuidString: "6D7C3A10-0002-4C6E-9B1D-000000000002")!,
                      metric: .temperatureAbove, threshold: 95, sustain: 30, enabled: false),
            AlertRule(id: UUID(uuidString: "6D7C3A10-0003-4C6E-9B1D-000000000003")!,
                      metric: .cpuAbove, threshold: 90, sustain: 60, enabled: false),
        ]
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

    private func save() {
        guard overrideItems == nil else { return }
        if let data = try? PropertyListEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}

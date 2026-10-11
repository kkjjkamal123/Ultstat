import Foundation
import Observation
import UltstatCore

enum MenuBarItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, network, disk, temperature, power, battery

    var id: String { rawValue }

    var title: String {
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

    var symbol: String {
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

enum WidgetStyle: String, Codable, CaseIterable, Sendable {
    case text, bar, sparkline
}

enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit

    func format(_ c: Float) -> String {
        switch self {
        case .celsius: String(format: "%.0f°", c)
        case .fahrenheit: String(format: "%.0f°", c * 9 / 5 + 32)
        }
    }
}

/// User preferences, persisted to UserDefaults as one property list blob (one write per change).
@MainActor @Observable
final class AppSettings {
    struct Stored: Codable, Equatable {
        var items: [MenuBarItem] = [.cpu, .memory, .temperature, .battery]
        var styles: [MenuBarItem: WidgetStyle] = [.cpu: .text, .memory: .text]
        var interval: Int = 2
        var temperatureUnit: TemperatureUnit = .celsius
        var showIcons: Bool = true
        var chargePolicy = ChargePolicy(limit: 80, sailingRange: 5)
        var chargeControlEnabled = false
        var lowPowerSampling = true
    }

    private static let key = "settings.v1"
    private let defaults: UserDefaults

    var stored: Stored {
        didSet { if stored != oldValue { save() } }
    }

    init(defaults: UserDefaults = .standard) {
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
    }

    @ObservationIgnored private var overrideItems: [MenuBarItem]?

    func style(for item: MenuBarItem) -> WidgetStyle { stored.styles[item] ?? .text }

    func isEnabled(_ item: MenuBarItem) -> Bool { stored.items.contains(item) }

    func toggle(_ item: MenuBarItem) {
        if let i = stored.items.firstIndex(of: item) {
            stored.items.remove(at: i)
        } else {
            let order = MenuBarItem.allCases
            let insertAt = stored.items.firstIndex { order.firstIndex(of: $0)! > order.firstIndex(of: item)! } ?? stored.items.endIndex
            stored.items.insert(item, at: insertAt)
        }
    }

    func resetToDefaults() { stored = Stored() }

    private func save() {
        guard overrideItems == nil else { return }
        if let data = try? PropertyListEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}

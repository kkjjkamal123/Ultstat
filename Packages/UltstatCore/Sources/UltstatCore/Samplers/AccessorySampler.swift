import Foundation
import IOBluetooth
import IOKit
import Synchronization

public struct AccessoryBattery: Sendable, Equatable, Identifiable {
    public var id: String { name + (component ?? "") }
    public var name: String
    /// "Left", "Right", "Case" for earbuds; nil for single-battery devices.
    public var component: String?
    public var percent: Int
    public var kind: Kind

    public enum Kind: String, Sendable {
        case keyboard, mouse, trackpad, headphones, gamepad, other
    }
}

/// Battery levels of connected accessories.
///
/// HID accessories (Magic Keyboard/Mouse/Trackpad, game controllers) publish `BatteryPercent` in the
/// IORegistry, which needs no permission. Earbuds report per-bud levels through IOBluetoothDevice;
/// that path triggers the Bluetooth privacy prompt, so it only runs when `includeBluetooth` is set.
/// Battery levels change slowly: default cadence is one read every 30 ticks.
public final class AccessorySampler: Sampler {
    public let cadence: Int
    public let includeBluetooth: Bool
    private let state = Mutex<[AccessoryBattery]>([])
    private let onUpdate: @Sendable ([AccessoryBattery]) -> Void

    public init(cadence: Int = 30, includeBluetooth: Bool, onUpdate: @escaping @Sendable ([AccessoryBattery]) -> Void = { _ in }) {
        self.cadence = cadence
        self.includeBluetooth = includeBluetooth
        self.onUpdate = onUpdate
    }

    public var latest: [AccessoryBattery] { state.withLock { $0 } }

    public func sample(tick: UInt64) {
        var found = Self.hidBatteries()
        if includeBluetooth { found += Self.bluetoothBatteries(excluding: Set(found.map(\.name))) }
        found.sort { ($0.name, $0.component ?? "") < ($1.name, $1.component ?? "") }
        let changed = state.withLock { s -> Bool in
            defer { s = found }
            return s != found
        }
        if changed { onUpdate(found) }
    }

    static func hidBatteries() -> [AccessoryBattery] {
        guard let match = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return [] }
        match["IOPropertyMatch"] = ["Transport": "Bluetooth"]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [AccessoryBattery] = []
        var seen = Set<String>()
        while case let svc = IOIteratorNext(it), svc != IO_OBJECT_NULL {
            defer { IOObjectRelease(svc) }
            func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let pct = (prop("BatteryPercent") as? NSNumber)?.intValue, (0...100).contains(pct),
                  let name = prop("Product") as? String, seen.insert(name).inserted else { continue }
            out.append(AccessoryBattery(name: name, component: nil, percent: pct, kind: kind(for: name)))
        }
        return out
    }

    /// Earbuds expose battery through private IOBluetoothDevice properties; each is checked with
    /// `responds(to:)` first so a future OS that removes them degrades to "not shown", not a crash.
    static func bluetoothBatteries(excluding: Set<String>) -> [AccessoryBattery] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        var out: [AccessoryBattery] = []
        for d in devices where d.isConnected() {
            let name = d.name ?? "Bluetooth device"
            guard !excluding.contains(name) else { continue }
            let parts: [(String, String?)] = [
                ("batteryPercentLeft", "Left"), ("batteryPercentRight", "Right"),
                ("batteryPercentCase", "Case"), ("batteryPercentSingle", nil),
            ]
            for (selector, component) in parts {
                let sel = NSSelectorFromString(selector)
                guard d.responds(to: sel), let v = (d.value(forKey: selector) as? NSNumber)?.intValue, v > 0, v <= 100 else { continue }
                out.append(AccessoryBattery(name: name, component: component, percent: v, kind: component == nil ? kind(for: name) : .headphones))
            }
        }
        return out
    }

    static func kind(for name: String) -> AccessoryBattery.Kind {
        let n = name.lowercased()
        if n.contains("keyboard") { return .keyboard }
        if n.contains("trackpad") { return .trackpad }
        if n.contains("mouse") { return .mouse }
        if n.contains("airpods") || n.contains("beats") || n.contains("headphone") || n.contains("buds") { return .headphones }
        if n.contains("controller") || n.contains("dualshock") || n.contains("dualsense") || n.contains("xbox") { return .gamepad }
        return .other
    }
}

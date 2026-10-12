import AppKit
import Testing
import UltstatCore
@testable import UltstatKit

@MainActor
@Suite struct MetricFormatTests {
    @Test func menuBarRatesStayWithinFourCharacters() {
        let cases: [(Double, String)] = [(0, "0K"), (999, "0K"), (1_000, "1K"), (12_345, "12K"), (999_400, "999K"),
                                         (999_600, "1.0M"), (1_234_567, "1.2M"), (12_000_000, "12M"), (1_200_000_000, "1.2G"), (-5, "0K")]
        for (v, expected) in cases {
            #expect(MetricFormat.rate(v) == expected, "rate(\(v))")
            #expect(MetricFormat.rate(v).count <= 4)
        }
    }

    @Test func percentAndWatts() {
        #expect(MetricFormat.percent(0) == "0%")
        #expect(MetricFormat.percent(0.456) == "46%")
        #expect(MetricFormat.percent(1) == "100%")
        #expect(MetricFormat.watts(2.14) == "2.1W")
        #expect(MetricFormat.watts(12.6) == "13W")
    }

    @Test func popoverRates() {
        #expect(ByteFormat.rate(0) == "0 B/s")
        #expect(ByteFormat.rate(260) == "260 B/s")
        #expect(ByteFormat.rate(4_500) == "4.5 KB/s")
        #expect(ByteFormat.rate(450_000) == "450 KB/s")
        #expect(ByteFormat.rate(2_500_000) == "2.5 MB/s")
        #expect(ByteFormat.rate(45_000_000) == "45 MB/s")
        #expect(ByteFormat.rate(1_500_000_000) == "1.5 GB/s")
    }

    @Test func temperatureUnits() {
        #expect(TemperatureUnit.celsius.format(47.4) == "47°")
        #expect(TemperatureUnit.fahrenheit.format(100) == "212°")
    }
}

@MainActor
@Suite struct MenuBarRendererTests {
    private func readings(cpu: Float) -> Readings {
        var r = Readings()
        r.cpu = CPULoad(total: cpu, user: cpu, system: 0, perCore: [], performance: nil, efficiency: nil)
        return r
    }

    @Test func widthIsStableAcrossValues() {
        let s = AppSettings.Stored(items: [.cpu])
        let widths = [0.0, 0.05, 0.42, 0.99].map { v -> CGFloat in
            MenuBarRenderer.image(for: MenuBarRenderer.segments(for: [.cpu], readings: readings(cpu: Float(v)), settings: s), scale: 2).size.width
        }
        #expect(Set(widths).count == 1, "single- and double-digit values must not resize the item: \(widths)")
    }

    @Test func missingDataStillRenders() {
        let segs = MenuBarRenderer.segments(for: MenuBarItem.allCases, readings: Readings(), settings: .init())
        #expect(segs.contains { $0.content == .text("–") })
        #expect(MenuBarRenderer.cgImage(for: segs, scale: 2, tint: NSColor.white.cgColor) != nil)
    }

    @Test func identicalReadingsProduceIdenticalSegments() {
        let s = AppSettings.Stored()
        #expect(MenuBarRenderer.segments(for: s.items, readings: readings(cpu: 0.123), settings: s)
                == MenuBarRenderer.segments(for: s.items, readings: readings(cpu: 0.1249), settings: s),
                "values that round the same must not trigger a redraw")
    }

    @Test func batterySymbolStates() {
        func snap(_ pct: Int, charging: Bool, plugged: Bool) -> BatterySnapshot {
            BatterySnapshot(percent: pct, hardwarePercent: nil, isCharging: charging, externalConnected: plugged, fullyCharged: false,
                            amperage: 0, voltage: 12_000, cycleCount: 1, designCapacity: 5000, fullChargeCapacity: nil,
                            nominalChargeCapacity: nil, remainingCapacity: nil, minutesToEmpty: nil, minutesToFull: nil,
                            notChargingReason: nil, adapter: nil, flow: nil)
        }
        #expect(MenuBarRenderer.batterySymbol(snap(50, charging: true, plugged: true)) == "battery.100percent.bolt")
        #expect(MenuBarRenderer.batterySymbol(snap(80, charging: false, plugged: true)) == "powerplug")
        #expect(MenuBarRenderer.batterySymbol(snap(5, charging: false, plugged: false)) == "battery.0percent")
        #expect(MenuBarRenderer.batterySymbol(snap(100, charging: false, plugged: false)) == "battery.100percent")
    }
}

@MainActor
@Suite struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "ultstat.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func persistsAndReloads() {
        let d = freshDefaults()
        let a = AppSettings(defaults: d)
        a.stored.interval = 5
        a.toggle(.network)
        let b = AppSettings(defaults: d)
        #expect(b.stored.interval == 5)
        #expect(b.isEnabled(.network))
    }

    @Test func toggleKeepsCanonicalOrder() {
        let a = AppSettings(defaults: freshDefaults())
        a.stored.items = [.cpu, .battery]
        a.toggle(.memory)
        #expect(a.stored.items == [.cpu, .memory, .battery])
        a.toggle(.cpu)
        #expect(a.stored.items == [.memory, .battery])
    }

    @Test func launchOverrideIsNeverPersisted() {
        let d = freshDefaults()
        d.set("cpu,network", forKey: "UltstatItems")
        let a = AppSettings(defaults: d)
        #expect(a.stored.items == [.cpu, .network])
        a.stored.interval = 3
        d.removeObject(forKey: "UltstatItems")
        let b = AppSettings(defaults: d)
        #expect(b.stored.items == AppSettings.Stored().items, "override must not leak into saved settings")
    }

    @Test func resetRestoresDefaults() {
        let a = AppSettings(defaults: freshDefaults())
        a.stored.interval = 10
        a.resetToDefaults()
        #expect(a.stored == AppSettings.Stored())
    }
}

@MainActor
@Suite struct ReadingsBusTests {
    @Test func coalescesBurstIntoOneDelivery() async {
        var deliveries = 0
        var last = Readings()
        let bus = ReadingsBus { r in
            deliveries += 1
            last = r
        }
        DispatchQueue.global().sync {
            bus.update { $0.systemPower = 1 }
            bus.update { $0.systemPower = 2 }
            bus.update { $0.systemPower = 3 }
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(deliveries == 1)
        #expect(last.systemPower == 3)
    }
}

@MainActor
@Suite struct SparklineWidgetTests {
    @Test func sparklineUsesHistoryAndFixedWidth() throws {
        var s = AppSettings.Stored(items: [.cpu])
        s.styles[.cpu] = .sparkline
        var r = Readings()
        r.cpu = CPULoad(total: 0.5, user: 0.5, system: 0, perCore: [], performance: nil, efficiency: nil)
        let short = MenuBarRenderer.segments(for: [.cpu], readings: r, settings: s, histories: [.cpu: [0.1, 0.9]])
        let long = MenuBarRenderer.segments(for: [.cpu], readings: r, settings: s, histories: [.cpu: Array(repeating: 0.3, count: 100)])
        #expect(short.first?.content == .sparkline([0.1, 0.9]))
        let w1 = MenuBarRenderer.image(for: short, scale: 2).size.width
        let w2 = MenuBarRenderer.image(for: long, scale: 2).size.width
        #expect(w1 == w2, "graph width must not depend on history length")
        #expect(MenuBarRenderer.cgImage(for: long, scale: 2, tint: NSColor.white.cgColor) != nil)
    }
}

@MainActor
@Suite struct SparklineEdgeTests {
    /// A single point must still draw (flat line), never an empty slot.
    @Test func singlePointDraws() throws {
        let seg = Segment(symbol: nil, content: .sparkline([0.5]))
        let (img, _) = try #require(MenuBarRenderer.cgImage(for: [seg], scale: 2, tint: NSColor.white.cgColor))
        let data = try #require(img.dataProvider?.data as Data?)
        #expect(data.contains { $0 != 0 }, "image must not be fully transparent")
    }
}

@MainActor
@Suite struct SettingsMigrationTests {
    /// A blob saved before newer fields existed must keep every field it does contain.
    @Test func oldBlobKeepsItsValues() throws {
        let old: [String: Any] = [
            "items": ["cpu", "network"],
            "interval": 5,
            "chargeControlEnabled": true,
            "chargePolicy": ["limit": 70, "sailingRange": 3, "dischargeAboveLimit": false, "topUp": false,
                             "useHardwarePercent": false, "magSafeLED": 0],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: old, format: .binary, options: 0)
        let s = try PropertyListDecoder().decode(AppSettings.Stored.self, from: data)
        #expect(s.items == [.cpu, .network])
        #expect(s.interval == 5)
        #expect(s.chargeControlEnabled)
        #expect(s.chargePolicy.limit == 70)
        #expect(s.alerts == AppSettings.Stored().alerts, "missing new field takes its default")
    }

    @Test func corruptFieldFallsBackAlone() throws {
        let blob: [String: Any] = ["items": ["cpu"], "interval": "not a number"]
        let data = try PropertyListSerialization.data(fromPropertyList: blob, format: .binary, options: 0)
        let s = try PropertyListDecoder().decode(AppSettings.Stored.self, from: data)
        #expect(s.items == [.cpu])
        #expect(s.interval == AppSettings.Stored().interval)
    }

    @Test func roundTrip() throws {
        var s = AppSettings.Stored(items: [.gpu])
        s.interval = 3
        s.alerts[0].enabled = true
        let data = try PropertyListEncoder().encode(s)
        #expect(try PropertyListDecoder().decode(AppSettings.Stored.self, from: data) == s)
    }
}

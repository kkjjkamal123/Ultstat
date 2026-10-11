import Foundation
import Synchronization
import Testing
@testable import UltstatCore

@Suite struct BatteryMonitorTests {
    @Test func snapshotIsPlausible() throws {
        guard let m = BatteryMonitor() else { return } // desktop Mac: nothing to test
        let s = try #require(m.read())
        #expect((0...100).contains(s.percent))
        #expect(s.designCapacity > 0)
        #expect(s.voltage > 5_000 && s.voltage < 20_000)
        if let hw = s.hardwarePercent { #expect((0...105).contains(hw)) }
        if let h = s.health { #expect(h > 0.3 && h < 1.3) }
        if !s.externalConnected { #expect(s.amperage <= 0, "on battery the pack cannot be charging") }
    }

    @Test func startPublishesAndStopIsIdempotent() async throws {
        let got = Atomic<Int>(0)
        guard let m = BatteryMonitor(onUpdate: { _ in got.add(1, ordering: .relaxed) }) else { return }
        m.start()
        m.start() // second start must not double-register
        try await Task.sleep(for: .milliseconds(300))
        #expect(got.load(ordering: .relaxed) >= 1)
        m.stop()
        m.stop()
    }

    @Test func flowTickUpdatesHistory() {
        guard let m = BatteryMonitor() else { return }
        m.refresh()
        m.sample(tick: 1)
        #expect(m.flowHistory.count == 1)
    }
}

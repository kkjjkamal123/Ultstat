import Foundation
import Testing
@testable import UltstatCore

@Suite(.serialized) struct CPUSamplerTests {
    @Test func topologyMatchesSysctl() {
        let t = CPUTopology.current()
        #expect(t.kinds.count == ProcessInfo.processInfo.processorCount)
        #expect(t.performanceCount > 0)
    }

    @Test func totalsAreBoundedAndSkipFirstTick() async throws {
        let s = CPUSampler()
        s.sample(tick: 0)
        #expect(s.history.isEmpty, "first tick only establishes a baseline")
        try await Task.sleep(for: .milliseconds(1100)) // outlive xnu's host_statistics cache window
        s.sample(tick: 1)
        let l = s.latest
        #expect((0...1).contains(l.total))
        #expect(abs(l.user + l.system - l.total) < 0.001)
        #expect(l.perCore.isEmpty, "cheap path must not produce per-core data")
    }

    @Test func perCoreTotalsAgreeWithCores() async throws {
        let s = CPUSampler()
        s.setPerCore(true)
        s.sample(tick: 0)
        try await Task.sleep(for: .milliseconds(300))
        s.sample(tick: 1)
        let l = s.latest
        #expect(l.perCore.count == s.topology.kinds.count)
        #expect(l.perCore.allSatisfy { (0...1).contains($0) })
        #expect(l.performance != nil)
        // Virtual Macs (CI runners) expose only one core type.
        if s.topology.efficiencyCount > 0 { #expect(l.efficiency != nil) }
    }

    @Test func zeroDeltaTicksAreDropped() {
        let s = CPUSampler()
        // Back-to-back calls land inside xnu's rate-limit window and see identical counters.
        for t in 0..<20 { s.sample(tick: UInt64(t)) }
        #expect(s.history.values.allSatisfy { $0 > 0 }, "no fabricated 0 % samples")
    }
}

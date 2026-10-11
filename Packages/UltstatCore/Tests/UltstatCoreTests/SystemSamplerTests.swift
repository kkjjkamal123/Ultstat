import Foundation
import Testing
@testable import UltstatCore

@Suite struct MemorySamplerTests {
    @Test func usageIsConsistent() throws {
        let m = try #require(MemorySampler().read())
        #expect(m.total == ProcessInfo.processInfo.physicalMemory)
        #expect(m.used == m.app + m.wired + m.compressed || m.used == m.total)
        #expect(m.used <= m.total)
        #expect((0...1).contains(m.usedFraction))
        #expect(m.swapUsed <= max(m.swapTotal, m.swapUsed))
    }
}

@Suite struct NetworkSamplerTests {
    private func counted(_ name: String) -> Bool {
        Array(name.utf8).withUnsafeBytes { NetworkSampler.isCounted($0) }
    }

    @Test func countsOnlyPhysicalInterfaces() {
        #expect(counted("en0"))
        #expect(counted("pdp_ip0"))
        #expect(!counted("lo0"))
        #expect(!counted("utun3"))
        #expect(!counted("awdl0"))
        #expect(!counted("e"))
    }

    @Test func discoveryFindsInterfacesAndRatesAreNonNegative() async throws {
        var buf = [UInt8](repeating: 0, count: 64) // deliberately too small: exercises ENOMEM growth
        let found = try #require(NetworkSampler.discover(&buf))
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.name.hasPrefix("en") || $0.name.hasPrefix("pdp_ip") })

        let s = NetworkSampler()
        s.sample(tick: 0)
        try await Task.sleep(for: .milliseconds(200))
        s.sample(tick: 1)
        let t = try #require(s.latest)
        #expect(t.download >= 0 && t.upload >= 0)
        s.invalidateInterfaces()
        s.sample(tick: 2)
    }
}

@Suite struct DiskAndGPUSamplerTests {
    @Test func diskCapacityAndRates() async throws {
        let s = DiskSampler(capacityEvery: 1)
        s.sample(tick: 0)
        try await Task.sleep(for: .milliseconds(100))
        s.sample(tick: 1)
        let d = try #require(s.latest)
        #expect(d.capacity > 0 && d.available <= d.capacity)
        #expect(d.read >= 0 && d.write >= 0)
        s.invalidateDrivers()
        s.sample(tick: 2)
    }

    @Test func gpuUtilisationBounded() throws {
        let g = try #require(GPUSampler())
        g.sample(tick: 0)
        let l = try #require(g.latest)
        #expect((0...1).contains(l.utilization))
    }
}

@Suite struct ProcessSamplerTests {
    @Test func reportsOwnProcessWithSaneValues() async throws {
        let s = ProcessSampler(limit: 500)
        s.sample(tick: 0)
        #expect(s.topByCPU.isEmpty, "first sample is only a baseline")
        // Burn ~50 ms of CPU so this process has measurable usage.
        let end = ContinuousClock.now + .milliseconds(50)
        var x = 0.0
        while ContinuousClock.now < end { x += sin(x) }
        try await Task.sleep(for: .milliseconds(200))
        s.sample(tick: 1)
        let me = try #require(s.topByMemory.first { $0.pid == getpid() } ?? s.topByCPU.first { $0.pid == getpid() })
        #expect(me.memory > 1_000_000)
        #expect(me.cpu >= 0 && me.cpu < Double(ProcessInfo.processInfo.processorCount) + 0.5)
        #expect(me.watts >= 0 && me.watts < 100)
        #expect(!me.name.isEmpty)
        #expect(s.topByCPU.count <= 500)
        #expect(zip(s.topByCPU, s.topByCPU.dropFirst()).allSatisfy { $0.cpu >= $1.cpu }, "sorted descending")
        _ = x
    }
}

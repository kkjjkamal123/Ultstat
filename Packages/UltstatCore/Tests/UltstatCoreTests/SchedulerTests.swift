import Synchronization
import Testing
@testable import UltstatCore

private final class CountingSampler: Sampler {
    let cadence: Int
    let calls = Atomic<Int>(0)
    init(cadence: Int = 1) { self.cadence = cadence }
    func sample(tick: UInt64) { calls.add(1, ordering: .relaxed) }
}

@Suite struct SchedulerTests {
    @Test func timerRunsOnlyWhileDemanded() {
        let s = Scheduler()
        let a = CountingSampler()
        #expect(!s.isRunning)
        let t1 = s.demand(a)
        #expect(s.isRunning)
        let t2 = s.demand(a)
        t1.cancel()
        #expect(s.isRunning, "second token still holds demand")
        t2.cancel()
        #expect(!s.isRunning, "no demand means no timer at all")
    }

    @Test func suspensionStopsTimerAndResumeRestartsIt() {
        let s = Scheduler()
        let token = s.demand(CountingSampler())
        s.suspend(.displaysAsleep)
        #expect(!s.isRunning)
        s.suspend(.sessionInactive)
        s.resume(.displaysAsleep)
        #expect(!s.isRunning, "still suspended for another reason")
        s.resume(.sessionInactive)
        #expect(s.isRunning)
        token.cancel()
    }

    @Test func cadenceIsRespected() {
        let s = Scheduler()
        let every = CountingSampler(cadence: 1)
        let third = CountingSampler(cadence: 3)
        let tokens = [s.demand(every), s.demand(third)]
        s.suspend(.user) // drive ticks manually
        for _ in 0..<9 { s._tickForTesting() }
        #expect(every.calls.load(ordering: .relaxed) >= 9)
        // 3 cadence hits plus at most one immediate first-demand sample.
        #expect((3...4).contains(third.calls.load(ordering: .relaxed)))
        tokens.forEach { $0.cancel() }
    }

    @Test func droppingTokenReleasesDemand() {
        let s = Scheduler()
        do { _ = s.demand(CountingSampler()) }
        #expect(!s.isRunning, "a discarded token must not leak demand")
    }
}

@Suite struct RingBufferTests {
    @Test func wrapsAndKeepsOrder() {
        var r = RingBuffer(capacity: 3)
        #expect(r.last == nil)
        [1, 2, 3, 4, 5].forEach { r.append($0) }
        #expect(r.values == [3, 4, 5])
        #expect(r.last == 5)
        #expect(r.max == 5)
        #expect(r.count == 3)
    }

    @Test func partialFill() {
        var r = RingBuffer(capacity: 4)
        r.append(7)
        r.append(2)
        #expect(r.values == [7, 2])
        r.removeAll()
        #expect(r.values.isEmpty)
    }
}

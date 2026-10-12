import Dispatch
import Synchronization

/// Something the scheduler can poll. Implementations run on the scheduler's private queue,
/// never concurrently with themselves, so they may keep mutable state without locks.
public protocol Sampler: AnyObject, Sendable {
    /// Run every `cadence` ticks (1 = every tick).
    var cadence: Int { get }
    func sample(tick: UInt64)
}

/// Opaque handle returned by `Scheduler.demand`. Demand lasts until `cancel()` or deinit.
public final class DemandToken: Sendable {
    private let release: @Sendable () -> Void
    private let released = Atomic<Bool>(false)

    init(release: @escaping @Sendable () -> Void) { self.release = release }

    public func cancel() {
        if !released.exchange(true, ordering: .acquiringAndReleasing) { release() }
    }

    deinit { cancel() }
}

/// Drives every sampler from one coalescable timer.
///
/// Power design:
/// - One `DispatchSourceTimer` for the whole app, aligned to wall-clock interval boundaries
///   with generous leeway so the kernel can batch the wakeup with other work.
/// - Samplers run only while demanded. With zero demand the timer is cancelled, not idled.
/// - `suspend(reason:)` (displays asleep, session inactive) stops the timer regardless of demand.
public final class Scheduler: Sendable {
    public struct Configuration: Sendable {
        public var interval: Duration
        /// Fraction of `interval` the kernel may delay a tick to coalesce wakeups.
        public var leewayFraction: Double

        public init(interval: Duration = .seconds(1), leewayFraction: Double = 0.2) {
            self.interval = interval
            self.leewayFraction = leewayFraction
        }
    }

    public enum SuspendReason: Hashable, Sendable {
        case displaysAsleep, sessionInactive, systemSleep, user
    }

    private struct Entry {
        let sampler: any Sampler
        var demand: Int
    }

    private struct State {
        var config: Configuration
        var entries: [ObjectIdentifier: Entry] = [:]
        var suspendReasons: Set<SuspendReason> = []
        var timer: (any DispatchSourceTimer)?
        var tick: UInt64 = 0
    }

    private let queue: DispatchQueue
    private let state: Mutex<State>

    public init(configuration: Configuration = .init(), qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: "ultstat.scheduler", qos: qos, autoreleaseFrequency: .workItem)
        state = Mutex(State(config: configuration))
    }

    deinit {
        state.withLock { $0.timer?.cancel() }
    }

    /// Registers demand for `sampler`. The sampler is polled until every token is released.
    /// The first demand also triggers an immediate sample so UI never shows an empty value.
    public func demand(_ sampler: any Sampler) -> DemandToken {
        let id = ObjectIdentifier(sampler)
        let isFirst = state.withLock { s -> Bool in
            if var e = s.entries[id] {
                e.demand += 1
                s.entries[id] = e
                return false
            }
            s.entries[id] = Entry(sampler: sampler, demand: 1)
            return true
        }
        if isFirst {
            queue.async { [weak self] in
                guard let self else { return }
                sampler.sample(tick: self.state.withLock { $0.tick })
            }
        }
        reconcileTimer()
        return DemandToken { [weak self] in self?.release(id) }
    }

    /// Samples `sampler` once, right away, on the scheduler queue (e.g. when a panel opens and
    /// should not wait for the next tick).
    public func sampleSoon(_ sampler: any Sampler, then done: (@Sendable @MainActor () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            sampler.sample(tick: self.state.withLock { $0.tick })
            // Published readings are queued to the main thread from inside sample(), so this runs after them.
            if let done { DispatchQueue.main.async { done() } }
        }
    }

    public func suspend(_ reason: SuspendReason) {
        state.withLock { _ = $0.suspendReasons.insert(reason) }
        reconcileTimer()
    }

    public func resume(_ reason: SuspendReason) {
        state.withLock { _ = $0.suspendReasons.remove(reason) }
        reconcileTimer()
    }

    public func setInterval(_ interval: Duration) {
        state.withLock {
            $0.config.interval = interval
            $0.timer?.cancel()
            $0.timer = nil
        }
        reconcileTimer()
    }

    /// True while a timer is armed. Exposed for tests and diagnostics.
    public var isRunning: Bool { state.withLock { $0.timer != nil } }

    /// Runs one tick synchronously on the caller's thread. For tests only.
    public func _tickForTesting() { fire() }

    // MARK: - Private

    private func release(_ id: ObjectIdentifier) {
        state.withLock { s in
            guard var e = s.entries[id] else { return }
            e.demand -= 1
            if e.demand <= 0 { s.entries[id] = nil } else { s.entries[id] = e }
        }
        reconcileTimer()
    }

    private func reconcileTimer() {
        state.withLock { s in
            let shouldRun = !s.entries.isEmpty && s.suspendReasons.isEmpty
            if shouldRun, s.timer == nil {
                s.timer = makeTimer(s.config)
            } else if !shouldRun, let t = s.timer {
                t.cancel()
                s.timer = nil
            }
        }
    }

    private func makeTimer(_ config: Configuration) -> any DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(flags: [], queue: queue)
        let intervalNs = UInt64(config.interval.components.seconds) * 1_000_000_000
            + UInt64(config.interval.components.attoseconds / 1_000_000_000)
        let leewayNs = Int(Double(intervalNs) * config.leewayFraction)
        // Align the first fire to the next wall-clock interval boundary, so the app wakes once
        // per interval at a predictable phase the kernel can coalesce with other timers.
        let now = DispatchTime.now().uptimeNanoseconds
        let delay = intervalNs - (now % intervalNs)
        t.schedule(
            deadline: .now() + .nanoseconds(Int(delay)),
            repeating: .nanoseconds(Int(intervalNs)),
            leeway: .nanoseconds(leewayNs)
        )
        t.setEventHandler { [weak self] in self?.fire() }
        t.resume()
        return t
    }

    private func fire() {
        let (tick, due) = state.withLock { s -> (UInt64, [any Sampler]) in
            s.tick &+= 1
            let tick = s.tick
            return (tick, s.entries.values.compactMap { tick % UInt64(max(1, $0.sampler.cadence)) == 0 ? $0.sampler : nil })
        }
        for sampler in due { sampler.sample(tick: tick) }
    }
}

import CPrivate
import Synchronization

public struct ComponentPower: Sendable, Equatable {
    /// Average watts over the last interval. nil where the OS hides the counter from this process.
    public var cpu: Double?
    public var gpu: Double?
    public var ane: Double?
    public var dram: Double?
}

/// Per-component power from IOReport's "Energy Model" (what `powermetrics` reads).
///
/// On macOS 27 the CPU, ANE and DRAM counters read 0 for non-root processes, so the app uses
/// `privileged: false` (GPU only, ~0.16 ms per sample) and the root helper uses `privileged: true`.
public final class EnergySampler: Sampler, @unchecked Sendable {
    public let cadence: Int
    private let privileged: Bool
    private let reader: OpaquePointer?
    private let state = Mutex<ComponentPower?>(nil)
    private let lock = Mutex(())
    private let onUpdate: @Sendable (ComponentPower) -> Void

    public init?(privileged: Bool, cadence: Int = 2, onUpdate: @escaping @Sendable (ComponentPower) -> Void = { _ in }) {
        guard let r = ult_energy_open(!privileged) else { return nil }
        reader = r
        self.privileged = privileged
        self.cadence = cadence
        self.onUpdate = onUpdate
    }

    deinit { ult_energy_close(reader) }

    public var latest: ComponentPower? { state.withLock { $0 } }

    public func sample(tick: UInt64) {
        var s = ult_energy_sample()
        let ok = lock.withLock { _ in ult_energy_read(reader, &s) }
        guard ok, s.nanos > 0 else { return }
        let secs = Double(s.nanos) / 1e9
        let p = ComponentPower(
            cpu: privileged ? s.cpu_mj / 1000 / secs : nil,
            gpu: s.gpu_mj / 1000 / secs,
            ane: privileged ? s.ane_mj / 1000 / secs : nil,
            dram: privileged ? s.dram_mj / 1000 / secs : nil
        )
        state.withLock { $0 = p }
        onUpdate(p)
    }
}

import Foundation
import IOKit
import Synchronization

public struct GPULoad: Sendable, Equatable {
    /// 0...1 device utilisation.
    public var utilization: Float
    public var renderer: Float?
    public var tiler: Float?
    /// Bytes of GPU memory in use (unified memory on Apple Silicon).
    public var memoryInUse: UInt64?
}

/// GPU utilisation from the accelerator's `PerformanceStatistics` registry property.
/// The service handle is resolved once and cached.
public final class GPUSampler: Sampler {
    public let cadence: Int
    private let service: io_registry_entry_t

    private struct State {
        var latest: GPULoad?
        var history = RingBuffer(capacity: 180)
    }

    private let state = Mutex(State())
    private let onUpdate: @Sendable (GPULoad) -> Void

    public init?(cadence: Int = 1, onUpdate: @escaping @Sendable (GPULoad) -> Void = { _ in }) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard svc != IO_OBJECT_NULL else { return nil }
        service = svc
        self.cadence = cadence
        self.onUpdate = onUpdate
    }

    deinit { IOObjectRelease(service) }

    public var latest: GPULoad? { state.withLock { $0.latest } }
    public var history: RingBuffer { state.withLock { $0.history } }

    public func sample(tick: UInt64) {
        guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return }
        func pct(_ key: String) -> Float? { (stats[key] as? NSNumber).map { Float($0.doubleValue) / 100 } }
        guard let device = pct("Device Utilization %") else { return }
        let load = GPULoad(
            utilization: min(max(device, 0), 1),
            renderer: pct("Renderer Utilization %"),
            tiler: pct("Tiler Utilization %"),
            memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value
        )
        state.withLock {
            $0.latest = load
            $0.history.append(load.utilization)
        }
        onUpdate(load)
    }
}

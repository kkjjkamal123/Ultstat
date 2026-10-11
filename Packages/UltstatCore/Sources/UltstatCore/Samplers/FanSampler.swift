import Synchronization

public struct FanReading: Sendable, Equatable, Identifiable {
    public var id: Int
    public var rpm: Double
    public var min: Double?
    public var max: Double?

    /// 0...1 between the fan's minimum and maximum speed.
    public var fraction: Double? {
        guard let lo = min, let hi = max, hi > lo else { return nil }
        return Swift.min(1, Swift.max(0, (rpm - lo) / (hi - lo)))
    }
}

/// Fan speeds from the SMC (`FNum`, `F<n>Ac`, `F<n>Mn`, `F<n>Mx`). Fanless Macs report no fans and
/// the sampler is never scheduled. Min/max are read once; each tick reads one key per fan.
public final class FanSampler: Sampler {
    public let cadence: Int
    private let smc: any SMCAccess
    private let fans: [(id: Int, actual: SMCKey, min: Double?, max: Double?)]
    private let state = Mutex<[FanReading]>([])
    private let onUpdate: @Sendable ([FanReading]) -> Void

    public init?(smc: any SMCAccess, cadence: Int = 2, onUpdate: @escaping @Sendable ([FanReading]) -> Void = { _ in }) {
        func num(_ k: String) -> Double? { (try? smc.read(SMCKey(k)))?.double }
        let count = Int(num("FNum") ?? 0)
        guard count > 0, count < 10 else { return nil }
        fans = (0..<count).map { i in (i, SMCKey("F\(i)Ac"), num("F\(i)Mn"), num("F\(i)Mx")) }
        self.smc = smc
        self.cadence = cadence
        self.onUpdate = onUpdate
    }

    public var latest: [FanReading] { state.withLock { $0 } }

    public func sample(tick: UInt64) {
        let readings = fans.compactMap { f -> FanReading? in
            guard let rpm = (try? smc.read(f.actual))?.double, rpm >= 0, rpm < 20_000 else { return nil }
            return FanReading(id: f.id, rpm: rpm, min: f.min, max: f.max)
        }
        state.withLock { $0 = readings }
        onUpdate(readings)
    }
}

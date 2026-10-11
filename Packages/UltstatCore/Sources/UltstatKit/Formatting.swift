import Foundation

public enum ByteFormat {
    public static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// "0 B/s", "260 B/s", "12 KB/s", "1.2 MB/s", "34 MB/s", "1.1 GB/s".
    public static func rate(_ bps: Double) -> String {
        let v = max(0, bps)
        switch v {
        case ..<1_000: return "\(Int(v.rounded())) B/s"
        case ..<10_000: return String(format: "%.1f KB/s", v / 1_000)
        case ..<1_000_000: return "\(Int((v / 1_000).rounded())) KB/s"
        case ..<10_000_000: return String(format: "%.1f MB/s", v / 1_000_000)
        case ..<1_000_000_000: return "\(Int((v / 1_000_000).rounded())) MB/s"
        default: return String(format: "%.1f GB/s", v / 1_000_000_000)
        }
    }
}

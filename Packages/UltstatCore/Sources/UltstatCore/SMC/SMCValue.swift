/// Raw bytes read from one SMC key plus its type, with decoding helpers.
///
/// Apple Silicon SMC firmware stores multi-byte integers and floats little-endian
/// (verified on M5: `B0CT` cycle count `0b 00` = 11, `B0DC` design capacity `80 16` = 5760 mAh,
/// `B0AC` current `89 fd` = -631 mA). The `spXY`/`fpXY` fixed-point types and the `#KEY` count
/// are big-endian.
public struct SMCValue: Sendable, Equatable {
    public let info: SMCKeyInfo
    /// Exactly `info.size` bytes, in firmware order.
    public let bytes: [UInt8]

    public init(info: SMCKeyInfo, bytes: [UInt8]) {
        self.info = info
        self.bytes = bytes
    }

    /// Numeric interpretation for every numeric SMC type, or `nil` for opaque types.
    public var double: Double? {
        Self.decode(type: info.type, bytes: bytes)
    }

    static func decode(type: SMCDataType, bytes b: [UInt8]) -> Double? {
        switch type {
        case .flt where b.count == 4:
            // Apple Silicon SMC floats are little-endian IEEE-754.
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case .ioft where b.count == 8:
            // 48.16 fixed point, little-endian.
            let v = (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) }
            return Double(v) / 65536.0
        case .ui8 where b.count >= 1, .flag where b.count >= 1:
            return Double(b[0])
        case .si8 where b.count >= 1:
            return Double(Int8(bitPattern: b[0]))
        case .ui16 where b.count == 2:
            return Double(le16(b))
        case .si16 where b.count == 2:
            return Double(Int16(bitPattern: le16(b)))
        case .ui32 where b.count == 4:
            return Double(le32(b))
        case .si32 where b.count == 4:
            return Double(Int32(bitPattern: le32(b)))
        case .ui64 where b.count == 8:
            return Double((0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) })
        case .fpe2 where b.count == 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case .fp88 where b.count == 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 256.0
        default:
            return signedFixedPoint(type: type, bytes: b)
        }
    }

    /// `spXY` types: signed 16-bit with Y fractional bits (hex digit).
    private static func signedFixedPoint(type: SMCDataType, bytes b: [UInt8]) -> Double? {
        guard b.count == 2, type.raw >> 16 == 0x7370 /* "sp" */ else { return nil }
        let fracDigit = UInt8(type.raw & 0xFF)
        let frac: Int
        switch fracDigit {
        case 0x30...0x39: frac = Int(fracDigit - 0x30)
        case 0x61...0x66: frac = Int(fracDigit - 0x61 + 10)
        default: return nil
        }
        let v = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
        return Double(v) / Double(1 << frac)
    }

    private static func le16(_ b: [UInt8]) -> UInt16 {
        UInt16(b[0]) | UInt16(b[1]) << 8
    }

    private static func le32(_ b: [UInt8]) -> UInt32 {
        UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}

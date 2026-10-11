import CSMC

/// A four-character SMC key such as `CHTE` or `Tp01`, packed big-endian into a `UInt32`.
public struct SMCKey: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public init(_ string: String) {
        var value: UInt32 = 0
        var count = 0
        for byte in string.utf8.prefix(4) {
            value = value << 8 | UInt32(byte)
            count += 1
        }
        // Pad short keys with spaces, as the firmware does for types like "ui8 ".
        while count < 4 {
            value = value << 8 | 0x20
            count += 1
        }
        raw = value
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var description: String { Self.fourCC(raw) }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        return String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : 0x3F }, as: UTF8.self)
    }
}

/// Size and data type of an SMC key, as reported by the firmware.
public struct SMCKeyInfo: Hashable, Sendable {
    public let size: Int
    public let type: SMCDataType
    public let attributes: UInt8

    public init(size: Int, type: SMCDataType, attributes: UInt8) {
        self.size = size
        self.type = type
        self.attributes = attributes
    }

    init(_ c: smc_key_info_t) {
        size = Int(c.size)
        type = SMCDataType(raw: c.type)
        attributes = c.attributes
    }

    var c: smc_key_info_t { smc_key_info_t(size: UInt32(size), type: type.raw, attributes: attributes) }
}

/// The firmware's FourCC data type tag ("flt ", "sp78", "ui8 ", ...).
public struct SMCDataType: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
    public init(_ s: String) { raw = SMCKey(s).raw }
    public var description: String { SMCKey.fourCC(raw) }

    public static let flt: SMCDataType = .init("flt ")
    public static let ui8: SMCDataType = .init("ui8 ")
    public static let ui16: SMCDataType = .init("ui16")
    public static let ui32: SMCDataType = .init("ui32")
    public static let ui64: SMCDataType = .init("ui64")
    public static let si8: SMCDataType = .init("si8 ")
    public static let si16: SMCDataType = .init("si16")
    public static let si32: SMCDataType = .init("si32")
    public static let flag: SMCDataType = .init("flag")
    public static let hex: SMCDataType = .init("hex_")
    public static let ioft: SMCDataType = .init("ioft")
    public static let sp78: SMCDataType = .init("sp78")
    public static let sp87: SMCDataType = .init("sp87")
    public static let sp96: SMCDataType = .init("sp96")
    public static let sp5a: SMCDataType = .init("sp5a")
    public static let sp4b: SMCDataType = .init("sp4b")
    public static let sp3c: SMCDataType = .init("sp3c")
    public static let sp2d: SMCDataType = .init("sp2d")
    public static let sp1e: SMCDataType = .init("sp1e")
    public static let fpe2: SMCDataType = .init("fpe2")
    public static let fp88: SMCDataType = .init("fp88")
}

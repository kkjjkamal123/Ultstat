import CSMC
import IOKit
import os

public enum SMCError: Error, Equatable, Sendable {
    case unavailable(kern_return_t)
    case keyNotFound(SMCKey)
    case readFailed(SMCKey, kern_return_t, firmwareResult: UInt8)
    case writeFailed(SMCKey, kern_return_t, firmwareResult: UInt8)
    case sizeMismatch(SMCKey, expected: Int, got: Int)
}

/// Thread-safe AppleSMC connection.
///
/// Key metadata is cached after the first lookup, so steady-state reads cost exactly one
/// `IOConnectCallStructMethod` (Stats issues a key-info call before every read).
public final class SMC: @unchecked Sendable {
    private var conn = smc_conn_t(conn: IO_OBJECT_NULL)
    private let lock = OSAllocatedUnfairLock()
    private var infoCache: [UInt32: smc_key_info_t] = [:]
    private var missing: Set<UInt32> = []

    public init() throws(SMCError) {
        let kr = smc_open(&conn)
        guard kr == KERN_SUCCESS else { throw .unavailable(kr) }
    }

    deinit { smc_close(&conn) }

    /// Metadata for `key`, or `nil` if this machine's firmware does not expose it.
    public func info(_ key: SMCKey) -> SMCKeyInfo? {
        lock.withLock { cachedInfo(key).map(SMCKeyInfo.init) }
    }

    public func read(_ key: SMCKey) throws(SMCError) -> SMCValue {
        lock.lock()
        defer { lock.unlock() }
        guard let info = cachedInfo(key) else { throw .keyNotFound(key) }
        do {
            var buf: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
            var result: UInt8 = 0
            let kr = withUnsafeMutableBytes(of: &buf) { p in
                withUnsafePointer(to: info) { ip in
                    smc_read(&conn, key.raw, ip, p.baseAddress!.assumingMemoryBound(to: UInt8.self), &result)
                }
            }
            guard kr == KERN_SUCCESS else { throw .readFailed(key, kr, firmwareResult: result) }
            let bytes = withUnsafeBytes(of: buf) { Array($0.prefix(Int(info.size))) }
            return SMCValue(info: SMCKeyInfo(info), bytes: bytes)
        }
    }

    /// Convenience numeric read; `nil` when the key is absent or not numeric.
    public func double(_ key: SMCKey) -> Double? {
        try? read(key).double
    }

    /// Writes raw bytes. The byte count must match the key's size. Requires root.
    public func write(_ key: SMCKey, bytes: [UInt8]) throws(SMCError) {
        lock.lock()
        defer { lock.unlock() }
        guard let info = cachedInfo(key) else { throw .keyNotFound(key) }
        do {
            guard bytes.count == Int(info.size) else {
                throw .sizeMismatch(key, expected: Int(info.size), got: bytes.count)
            }
            var result: UInt8 = 0
            let kr = withUnsafePointer(to: info) { ip in
                bytes.withUnsafeBufferPointer { smc_write(&conn, key.raw, ip, $0.baseAddress!, &result) }
            }
            guard kr == KERN_SUCCESS else { throw .writeFailed(key, kr, firmwareResult: result) }
        }
    }

    /// Number of keys in the firmware key table (`#KEY` is big-endian, unlike most keys).
    public func keyCount() -> Int {
        guard let v = try? read("#KEY"), v.bytes.count == 4 else { return 0 }
        return Int(UInt32(v.bytes[0]) << 24 | UInt32(v.bytes[1]) << 16 | UInt32(v.bytes[2]) << 8 | UInt32(v.bytes[3]))
    }

    /// Every key the firmware exposes, in table order.
    public func allKeys() -> [SMCKey] {
        let count = keyCount()
        return lock.withLock {
            var keys: [SMCKey] = []
            keys.reserveCapacity(count)
            for i in 0..<count {
                var raw: UInt32 = 0
                var result: UInt8 = 0
                if smc_key_at_index(&conn, UInt32(i), &raw, &result) == KERN_SUCCESS {
                    keys.append(SMCKey(raw: raw))
                }
            }
            return keys
        }
    }

    /// Must be called with `lock` held.
    private func cachedInfo(_ key: SMCKey) -> smc_key_info_t? {
        if let hit = infoCache[key.raw] { return hit }
        if missing.contains(key.raw) { return nil }
        var info = smc_key_info_t()
        var result: UInt8 = 0
        guard smc_key_info(&conn, key.raw, &info, &result) == KERN_SUCCESS else {
            missing.insert(key.raw)
            return nil
        }
        infoCache[key.raw] = info
        return info
    }
}

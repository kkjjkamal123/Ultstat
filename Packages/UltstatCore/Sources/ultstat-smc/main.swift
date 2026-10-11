// Read-only SMC inspector.
//   ultstat-smc list            every key with type, size, raw bytes and decoded value
//   ultstat-smc read KEY...     specific keys
import Foundation
import UltstatCore

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

func line(_ smc: SMC, _ key: SMCKey) -> String {
    guard let info = smc.info(key) else { return "\(key)  <absent>" }
    guard let v = try? smc.read(key) else {
        return "\(key)  [\(info.type)] size=\(info.size) attr=0x\(String(info.attributes, radix: 16))  <unreadable>"
    }
    let decoded = v.double.map { String(format: "%.4f", $0) } ?? "-"
    return "\(key)  [\(info.type)] size=\(info.size) attr=0x\(String(info.attributes, radix: 16))  \(hex(v.bytes))  = \(decoded)"
}

let args = CommandLine.arguments.dropFirst()
do {
    let smc = try SMC()
    switch args.first {
    case "list":
        for key in smc.allKeys() { print(line(smc, key)) }
    case "read":
        for k in args.dropFirst() { print(line(smc, SMCKey(k))) }
    default:
        print("usage: ultstat-smc list | read KEY...")
    }
} catch {
    FileHandle.standardError.write(Data("SMC unavailable: \(error)\n".utf8))
    exit(1)
}

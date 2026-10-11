// Micro-benchmarks for the sampling hot path.
import Foundation
import UltstatCore

func measure(_ name: String, iterations: Int, _ body: () -> Void) {
    body() // warm caches
    let clock = ContinuousClock()
    let d = clock.measure { for _ in 0..<iterations { body() } }
    let ns = Double(d.components.attoseconds) / 1e9 + Double(d.components.seconds) * 1e9
    print(String(format: "%-34@ %9.2f µs/op", name as NSString, ns / Double(iterations) / 1000))
}

let smc = try SMC()
let tp = smc.allKeys().filter { $0.description.hasPrefix("Tp") }
print("P-core temperature keys: \(tp.count)")
measure("SMC read 1 key (cached info)", iterations: 2000) { _ = smc.double("Tp00") }
measure("SMC read all Tp* keys", iterations: 200) { for k in tp { _ = smc.double(k) } }
measure("SMC read PSTR", iterations: 2000) { _ = smc.double("PSTR") }

// MARK: IOHID thermal path
import CPrivate

let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)!
_ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
let services = (IOHIDEventSystemClientCopyServices(client) as? [AnyObject]) ?? []
print("IOHID temperature services: \(services.count)")
var names: [String] = []
for s in services {
    let svc = unsafeBitCast(s, to: IOHIDServiceClientRef.self)
    names.append((IOHIDServiceClientCopyProperty(svc, "Product" as CFString) as? String) ?? "?")
}
print("  e.g.", names.prefix(12).joined(separator: ", "))
func hidTemp(_ s: AnyObject) -> Double {
    let svc = unsafeBitCast(s, to: IOHIDServiceClientRef.self)
    guard let ev = IOHIDServiceClientCopyEvent(svc, Int64(kUltIOHIDEventTypeTemperature), 0, 0) else { return .nan }
    return IOHIDEventGetFloatValue(ev, Int32(kUltIOHIDEventTypeTemperature << 16))
}
measure("IOHID read 1 sensor", iterations: 2000) { _ = hidTemp(services[0]) }
measure("IOHID read all sensors", iterations: 100) { for s in services { _ = hidTemp(s) } }

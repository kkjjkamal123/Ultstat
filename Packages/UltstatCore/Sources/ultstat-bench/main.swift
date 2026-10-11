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

// MARK: CPU
let topo = CPUTopology.current()
print("Topology: \(topo.performanceCount)P + \(topo.efficiencyCount)E  \(topo.kinds.map { String($0.rawValue) }.joined())")
let cpuTotal = CPUSampler(topology: topo)
measure("CPU totals (HOST_CPU_LOAD_INFO)", iterations: 5000) { cpuTotal.sample(tick: 0) }
let cpuCores = CPUSampler(topology: topo)
cpuCores.setPerCore(true)
measure("CPU per-core (host_processor_info)", iterations: 5000) { cpuCores.sample(tick: 0) }
Thread.sleep(forTimeInterval: 0.5)
cpuCores.sample(tick: 0)
let l = cpuCores.latest
print(String(format: "  live: total %.1f%%  P %.1f%%  E %.1f%%", l.total * 100, (l.performance ?? 0) * 100, (l.efficiency ?? 0) * 100))
let probe = CPUSampler(topology: topo)
probe.sample(tick: 0)
Thread.sleep(forTimeInterval: 0.5)
probe.sample(tick: 0)
print(String(format: "  probe totals-only after 0.5s: total %.1f%% user %.1f%% sys %.1f%%", probe.latest.total * 100, probe.latest.user * 100, probe.latest.system * 100))
let probe2 = CPUSampler(topology: topo)
probe2.setPerCore(true)
probe2.sample(tick: 0)
Thread.sleep(forTimeInterval: 0.5)
probe2.sample(tick: 0)
let p2 = probe2.latest
print(String(format: "  probe2 per-core after 0.5s: total %.1f%% user %.1f%% cores %d P %.1f%%", p2.total * 100, p2.user * 100, p2.perCore.count, (p2.performance ?? -1) * 100))

// MARK: Memory / network / disk / GPU
let mem = MemorySampler()
measure("Memory (HOST_VM_INFO64 + 2 sysctl)", iterations: 2000) { mem.sample(tick: 0) }
if let m = mem.latest {
    print(String(format: "  live: used %.2f GB of %.0f GB (app %.2f, wired %.2f, compressed %.2f), pressure %d",
                 Double(m.used) / 1e9, Double(m.total) / 1e9, Double(m.app) / 1e9, Double(m.wired) / 1e9, Double(m.compressed) / 1e9, m.pressure.rawValue))
}
let net = NetworkSampler()
measure("Network (IFMIB per counted iface)", iterations: 2000) { net.sample(tick: 0) }
print("  interfaces:", net.latest?.interfaces ?? [])
let disk = DiskSampler()
measure("Disk (IOBlockStorageDriver stats)", iterations: 2000) { disk.sample(tick: 0) }
if let d = disk.latest { print(String(format: "  boot volume: %.1f GB free of %.1f GB", Double(d.available) / 1e9, Double(d.capacity) / 1e9)) }
if let gpu = GPUSampler() {
    measure("GPU (PerformanceStatistics)", iterations: 2000) { gpu.sample(tick: 0) }
    if let g = gpu.latest { print(String(format: "  live: device %.1f%% renderer %.1f%%", g.utilization * 100, (g.renderer ?? 0) * 100)) }
}

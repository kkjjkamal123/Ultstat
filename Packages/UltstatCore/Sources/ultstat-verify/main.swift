// Prints Ultstat's readings next to macOS's own tools for an accuracy cross-check.
import Foundation
import UltstatCore

func shell(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

// Battery vs pmset.
if let b = BatteryMonitor()?.read() {
    let pm = shell("pmset -g batt | grep -oE '[0-9]+%' | head -1")
    print("Battery   ultstat \(b.percent)%   pmset \(pm.trimmingCharacters(in: .whitespacesAndNewlines))")
}

// Memory vs vm_stat with Activity Monitor's formula.
let mem = MemorySampler()
if let m = mem.read() {
    let vm = shell("vm_stat")
    func pages(_ key: String) -> Double {
        let line = vm.split(separator: "\n").first { $0.contains(key) } ?? ""
        return Double(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "") ?? "0") ?? 0
    }
    let page = Double(shell("pagesize").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 16384
    let anon = pages("Anonymous pages"), purge = pages("Pages purgeable"), wired = pages("Pages wired down"), comp = pages("Pages occupied by compressor")
    let used = (anon - purge + wired + comp) * page
    print(String(format: "Memory    ultstat %.2f GB   vm_stat %.2f GB", Double(m.used) / 1e9, used / 1e9))
}

// CPU vs top over the same ~2 s window.
let cpu = CPUSampler()
cpu.sample(tick: 0)
let top = shell("top -l 2 -s 2 -n 0 | grep 'CPU usage' | tail -1")
cpu.sample(tick: 1)
print(String(format: "CPU       ultstat %.1f%%   top: %@", cpu.latest.total * 100, top.trimmingCharacters(in: .whitespacesAndNewlines)))

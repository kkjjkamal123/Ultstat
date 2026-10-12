import AppKit
import os

/// `-UltstatStressPopover N` opens and closes the real popover N times, then logs memory.
/// Used with `leaks` and `footprint` to prove the popover tears down completely.
@MainActor
enum StressTester {
    private static let log = Logger(subsystem: "io.github.kkjjkamal23.Ultstat", category: "stress")

    static func runIfRequested(statusItem: StatusItemController, model: AppModel) {
        let hold = UserDefaults.standard.integer(forKey: "UltstatHoldPopover")
        if hold > 0 {
            // Opens the popover once and keeps it open for `hold` seconds (measures steady open cost).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                statusItem.togglePopover()
                try? await Task.sleep(for: .seconds(hold))
                statusItem.togglePopover()
            }
        }
        let settingsCycles = UserDefaults.standard.integer(forKey: "UltstatStressSettings")
        if settingsCycles > 0 { stressSettings(settingsCycles, model: model) }
        let n = UserDefaults.standard.integer(forKey: "UltstatStressPopover")
        guard n > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            log.notice("stress: start footprint=\(footprintMB(), privacy: .public) MB")
            for i in 1...n {
                statusItem.togglePopover()                     // open
                try? await Task.sleep(for: .milliseconds(350))
                statusItem.togglePopover()                     // close
                try? await Task.sleep(for: .milliseconds(150))
                if i % 10 == 0 { log.notice("stress: \(i)/\(n) footprint=\(footprintMB(), privacy: .public) MB") }
            }
            log.notice("stress: done footprint=\(footprintMB(), privacy: .public) MB")
        }
    }

    /// Opens Settings, walks every tab via the toolbar, closes the window; repeats.
    private static func stressSettings(_ n: Int, model: AppModel) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            log.notice("stress-settings: start footprint=\(footprintMB(), privacy: .public) MB")
            var opened = 0
            for i in 1...n {
                model.openSettings()
                try? await Task.sleep(for: .milliseconds(400))
                if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "ultstat.settings" }) {
                    opened += 1
                    SettingsTabDriver.cycle()
                    try? await Task.sleep(for: .milliseconds(600))
                    w.performClose(nil)
                }
                try? await Task.sleep(for: .milliseconds(200))
                if i % 10 == 0 { log.notice("stress-settings: \(i)/\(n) footprint=\(footprintMB(), privacy: .public) MB windows=\(NSApp.windows.count)") }
            }
            log.notice("stress-settings: done opened=\(opened)/\(n) footprint=\(footprintMB(), privacy: .public) MB windows=\(NSApp.windows.count)")
        }
    }

    static func footprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? String(format: "%.1f", Double(info.phys_footprint) / 1_048_576) : "?"
    }
}

/// Lets the stress test walk Settings tabs without accessibility automation.
@MainActor
enum SettingsTabDriver {
    static var select: ((Int) -> Void)?
    static func cycle() {
        Task { @MainActor in
            for i in [1, 2, 3, 4, 0] {
                select?(i)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }
}

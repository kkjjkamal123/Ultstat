import AppKit
import os

/// `-UltstatSelfTest YES -UltstatEphemeralSettings YES`: opens Settings, and on every tab presses
/// every switch through the accessibility API (as VoiceOver would), checking that its value changes,
/// then presses it again to restore. Logs a pass/fail line per control. Destructive actions are skipped.
@MainActor
enum SelfTest {
    private static let log = Logger(subsystem: "io.github.kkjjkamal23.Ultstat", category: "selftest")
    private static let skip = ["install", "uninstall", "reset", "quit", "remove", "top up", "calibrate"]

    static func runIfRequested(model: AppModel, openSettings: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "UltstatSelfTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            openSettings()
            try? await Task.sleep(for: .milliseconds(800))
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "ultstat.settings" }) else {
                log.error("SELFTEST FAIL settings window did not open")
                return
            }
            log.notice("SELFTEST settings window opened key=\(window.isKeyWindow) appActive=\(NSApp.isActive)")
            let all = elements(in: window)
            let roles = Dictionary(grouping: all.compactMap { role($0)?.rawValue }, by: { $0 }).mapValues(\.count)
            log.notice("SELFTEST tree elements=\(all.count) roles=\(roles.description, privacy: .public)")
            var passed = 0, failed = 0
            for tab in 0..<5 {
                SettingsTabDriver.select?(tab)
                try? await Task.sleep(for: .milliseconds(500))
                for el in elements(in: window) where role(el) == .checkBox {
                    let label = name(el)
                    if skip.contains(where: { label.lowercased().contains($0) }) { continue }
                    let before = String(describing: el.accessibilityValue() ?? "nil")
                    let enabled = el.isAccessibilityEnabled()
                    _ = el.accessibilityPerformPress()
                    try? await Task.sleep(for: .milliseconds(250))
                    let after = String(describing: el.accessibilityValue() ?? "nil")
                    if before != after {
                        passed += 1
                        log.notice("SELFTEST PASS tab=\(tab) switch '\(label, privacy: .public)' \(before, privacy: .public)->\(after, privacy: .public)")
                        _ = el.accessibilityPerformPress()
                        try? await Task.sleep(for: .milliseconds(150))
                    } else {
                        failed += 1
                        log.error("SELFTEST FAIL tab=\(tab) switch '\(label, privacy: .public)' enabled=\(enabled) value stayed \(before, privacy: .public)")
                    }
                }
            }
            log.notice("SELFTEST DONE passed=\(passed) failed=\(failed)")
        }
    }

    // SwiftUI's accessibility nodes are private NSObject subclasses; reach them through dynamic
    // Objective-C dispatch (as assistive technology does) rather than Swift protocol casts.
    private static func elements(in window: NSWindow) -> [NSObject] {
        var out: [NSObject] = []
        func walk(_ obj: NSObject, depth: Int) {
            guard depth < 60 else { return }
            out.append(obj)
            let children = (obj as AnyObject).accessibilityChildren?() as? [Any] ?? []
            for case let c as NSObject in children { walk(c, depth: depth + 1) }
        }
        if let content = window.contentView { walk(content, depth: 0) }
        return out
    }

    private static func role(_ el: NSObject) -> NSAccessibility.Role? { (el as AnyObject).accessibilityRole?() }

    private static func name(_ el: NSObject) -> String {
        let a = el as AnyObject
        let label = a.accessibilityLabel?().flatMap { $0 }
        let title = a.accessibilityTitle?().flatMap { $0 }
        let ident = a.accessibilityIdentifier?()
        return [label, title, ident].compactMap { $0 }.first { !$0.isEmpty } ?? "?"
    }
}

extension NSObject {
    fileprivate func accessibilityValue() -> Any? { (self as AnyObject).accessibilityValue?().flatMap { $0 } }
    fileprivate func accessibilityPerformPress() -> Bool { (self as AnyObject).accessibilityPerformPress?() ?? false }
    fileprivate func isAccessibilityEnabled() -> Bool { (self as AnyObject).isAccessibilityEnabled?() ?? false }
}

import UltstatKit
import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "io.github.kkjjkamal23.Ultstat", category: "snapshot")

/// Writes PNGs of the menu-bar image and the dashboard for visual review and regression checks.
/// Enabled only by launching with `-UltstatSnapshotDir /some/dir`.
@MainActor
enum SnapshotExporter {
    static var directory: URL? {
        UserDefaults.standard.string(forKey: "UltstatSnapshotDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func scheduleIfRequested(model: AppModel) {
        guard let dir = directory else { return }
        model.hub.setDetailVisible(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            export(model: model, to: dir)
            model.hub.setDetailVisible(false)
        }
    }

    static func export(model: AppModel, to dir: URL) {
        log.notice("snapshot export start \(dir.path, privacy: .public)")
        defer { log.notice("snapshot export done") }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("snapshot dir failed: \(error.localizedDescription, privacy: .public)")
        }
        let segs = MenuBarRenderer.segments(for: model.settings.stored.items, readings: model.readings,
                                            settings: model.settings.stored, histories: model.menuBarHistories())
        for (name, appearance) in [("menubar-dark", NSAppearance.Name.darkAqua), ("menubar-light", .aqua)] {
            writeMenuBar(segments: segs, appearance: appearance, to: dir.appendingPathComponent("\(name).png"))
        }
        for (name, appearance) in [("dashboard-dark", NSAppearance.Name.darkAqua), ("dashboard-light", .aqua)] {
            writeView(DashboardView().environment(model), size: DashboardPanel.size, appearance: appearance,
                      to: dir.appendingPathComponent("\(name).png"))
        }
        model.popoverOpened()   // module views read panel readings, which only flow while a panel is open
        defer { model.popoverClosed() }
        for item in [MenuBarItem.memory, .cpu, .gpu, .disk, .battery, .power, .network, .temperature] {
            writeView(ModuleView(item: item).environment(model), size: NSSize(width: ModulePanelSize.width, height: 900), appearance: .darkAqua,
                      to: dir.appendingPathComponent("module-\(item.rawValue).png"))
        }
        for (name, dark) in [("battery-dark", true), ("battery-light", false)] {
            let tint = (dark ? NSColor.white : NSColor.black).cgColor
            let pct = model.readings.battery?.percent ?? 82
            for (suffix, charging, low) in [("", false, false), ("-lowpower", false, true), ("-charging", true, false)] {
                if let (img, _) = MenuBarRenderer.coloredBattery(percent: pct, charging: charging, lowPower: low, time: "2:15", textColor: tint, scale: 2) {
                    writeComposite(img, dark: dark, to: dir.appendingPathComponent("\(name)\(suffix).png"))
                }
            }
        }
        for (tab, name) in ["general", "menubar", "battery", "alerts", "about"].enumerated() {
            writeView(SettingsView(initialTab: tab).environment(model), size: NSSize(width: 520, height: 460), appearance: .darkAqua,
                      to: dir.appendingPathComponent("settings-\(name).png"))
        }
    }

    /// Uses the exact layer-contents path the live status item uses, on a menu-bar-like background.
    private static func writeMenuBar(segments: [Segment], appearance: NSAppearance.Name, to url: URL) {
        let dark = appearance == .darkAqua
        let tint = (dark ? NSColor.white : NSColor.black).cgColor
        guard let (img, size) = MenuBarRenderer.cgImage(for: segments, scale: 2, tint: tint) else { return }
        let pad: CGFloat = 8
        let w = Int((size.width + pad * 2) * 2), h = Int(size.height * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: Int(pad * 2), y: 0, width: img.width, height: img.height))
        guard let out = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func writeComposite(_ img: CGImage, dark: Bool, to url: URL) {
        let pad = 16
        guard let ctx = CGContext(data: nil, width: img.width + pad * 2, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width + pad * 2, height: img.height))
        ctx.draw(img, in: CGRect(x: pad, y: 0, width: img.width, height: img.height))
        if let out = ctx.makeImage() { try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: url) }
    }

    private static func writeView<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let dark = appearance == .darkAqua
        let backdrop = dark ? Color(white: 0.14) : Color(white: 0.94)   // approximates the popover material
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(backdrop))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
    }
}

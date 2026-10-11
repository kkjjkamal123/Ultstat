import AppKit
import SwiftUI

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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let segs = MenuBarRenderer.segments(for: model.settings.stored.items, readings: model.readings, settings: model.settings.stored)
        for (name, appearance) in [("menubar-dark", NSAppearance.Name.darkAqua), ("menubar-light", .aqua)] {
            writeMenuBar(segments: segs, appearance: appearance, to: dir.appendingPathComponent("\(name).png"))
        }
        for (name, appearance) in [("dashboard-dark", NSAppearance.Name.darkAqua), ("dashboard-light", .aqua)] {
            writeView(DashboardView().environment(model), size: NSSize(width: 340, height: 600), appearance: appearance,
                      to: dir.appendingPathComponent("\(name).png"))
        }
        for (name, appearance) in [("settings-dark", NSAppearance.Name.darkAqua)] {
            writeView(SettingsView().environment(model), size: NSSize(width: 520, height: 460), appearance: appearance,
                      to: dir.appendingPathComponent("\(name).png"))
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

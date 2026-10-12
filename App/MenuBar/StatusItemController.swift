import UltstatKit
import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "io.github.kkjjkamal23.Ultstat", category: "statusitem")

/// The single status item: draws the widgets and owns the popover.
///
/// Rendering bypasses `NSStatusBarButton.image`. Setting an image makes AppKit re-rasterise it into
/// the button's extended-range layer on every change (measured ~6 ms and ~7 wakeups per update).
/// Instead we rasterise once, tinted for the current appearance, and hand the bitmap to a
/// `CALayer` as `contents`; Core Animation only composites it.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    /// The metric this item shows, or nil for the combined item (all metrics, full dashboard).
    let metric: MenuBarItem?
    private let contentLayer = CALayer()
    private var panel: DashboardPanel?
    private var lastSegments: [Segment]?
    private var lastAppearance: NSAppearance.Name?
    private var appearanceObservation: NSKeyValueObservation?
    private var lastWidth: CGFloat = 0
    private var powerStateObserver: (any NSObjectProtocol)?

    init(model: AppModel, metric: MenuBarItem? = nil) {
        self.model = model
        self.metric = metric
        super.init()
        item.autosaveName = "io.github.kkjjkamal23.Ultstat.\(metric?.rawValue ?? "main")"
        item.behavior = []
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityIdentifier("ultstat.statusItem.\(metric?.rawValue ?? "main")")
            button.wantsLayer = true
            contentLayer.contentsGravity = .center
            contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            button.layer?.addSublayer(contentLayer)
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.render(force: true) }
            }
        }
        render()
        if metric == .battery {
            // The pill turns yellow in Low Power Mode, which no battery reading reflects.
            powerStateObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render(force: true) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.logVisibility() }
    }

    private func logVisibility() {
        let w = item.button?.window
        let frame = w.map { NSStringFromRect($0.frame) } ?? "nil"
        let visible = w?.occlusionState.contains(.visible) ?? false
        log.notice("status item visible=\(self.item.isVisible) windowVisible=\(visible) frame=\(frame, privacy: .public)")
    }

    /// Redraws only when the formatted output or the menu-bar appearance changed.
    func render(force: Bool = false) {
        guard let button = item.button else { return }
        var segs = MenuBarRenderer.segments(for: metric.map { [$0] } ?? model.settings.stored.items, readings: model.readings,
                                            settings: model.settings.stored, histories: model.menuBarHistories())
        if segs.isEmpty { segs = [Segment(symbol: "gauge.with.dots.needle.33percent", content: .text(""), slot: "")] }
        let appearance = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
        guard force || segs != lastSegments || appearance != lastAppearance else { return }
        lastSegments = segs
        lastAppearance = appearance

        var tint = NSColor.labelColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance { tint = NSColor.labelColor.cgColor }
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let rendered: (image: CGImage, size: CGSize)?
        if metric == .battery, segs.count == 1, case .battery(let pct, let charging, let time) = segs[0].content {
            rendered = MenuBarRenderer.coloredBattery(percent: pct, charging: charging, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                      time: time, textColor: tint, scale: scale)
        } else {
            rendered = MenuBarRenderer.cgImage(for: segs, scale: scale, tint: tint)
        }
        guard let (image, size) = rendered else { return }

        // macOS already spaces adjacent status items; only a hair of padding of our own.
        let width = ceil(size.width) + (metric == nil ? 8 : 2)
        if width != lastWidth {
            item.length = width
            lastWidth = width
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = button.bounds
        contentLayer.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                    width: size.width, height: size.height)
        contentLayer.contentsScale = scale
        contentLayer.contents = image
        CATransaction.commit()
        button.setAccessibilityLabel(segs.map { seg -> String in
            switch seg.content {
            case .text(let t): t
            case .stacked(let a, let b): "\(a) \(b)"
            case .bar(let v): MetricFormat.percent(v)
            case .sparkline(let v): v.last.map(MetricFormat.percent) ?? ""
            case .labeled(let c, let v): "\(c) \(v)"
            case .battery(let p, _, let t): "Battery \(p)% \(t)"
            }
        }.joined(separator: ", "))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    var isDashboardOpen: Bool { panel?.isVisible ?? false }

    func closeDashboard() { panel?.dismiss() }

    /// The item's frame in screen coordinates (nil when hidden by a menu-bar manager).
    var anchorRect: NSRect? {
        item.button.flatMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } }
    }

    func togglePopover() {
        if let panel, panel.isVisible {
            panel.dismiss()
            return
        }
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // Built once and kept: it reads `panelReadings`, which only change while it is visible.
        model.closeAllPanels()   // one panel at a time
        let p = panel ?? makePanel()
        p.onClose = { [weak self] in self?.dashboardClosed() }
        panel = p
        model.popoverOpened()
        item.button?.highlight(true)
        let anchor = item.button.flatMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } }
        p.show(below: anchor)
        log.notice("dashboard open took \(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, format: .fixed(precision: 1)) ms")
    }

    private func makePanel() -> DashboardPanel {
        if let metric {
            return DashboardPanel(rootView: ModuleView(item: metric).environment(model), width: ModulePanelSize.width, fitsContent: true)
        }
        return DashboardPanel(rootView: DashboardView().environment(model))
    }

    /// Removes the item from the menu bar (settings changed).
    func remove() {
        if let o = powerStateObserver { NotificationCenter.default.removeObserver(o) }
        panel?.dismiss()
        NSStatusBar.system.removeStatusItem(item)
    }

    private func dashboardClosed() {
        item.button?.highlight(false)
        model.popoverClosed()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Ultstat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func openSettings() {
        model.openSettings()
    }
}

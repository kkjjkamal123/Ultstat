import UltstatKit
import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "io.github.kkjjkamal23.Ultstat", category: "statusitem")

/// One status item. It draws one or more metrics side by side and opens the panel of the metric
/// that was clicked. By default every metric lives in a single item, because macOS separates
/// status items by a wide fixed gap that apps can't change; inside one item the gap is ours.
///
/// Rendering bypasses `NSStatusBarButton.image`. Setting an image makes AppKit re-rasterise it into
/// the button's extended-range layer on every change (measured ~6 ms and ~7 wakeups per update).
/// Instead we rasterise once, tinted for the current appearance, and hand the bitmap to a
/// `CALayer` as `contents`; Core Animation only composites it.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    /// Metrics drawn in this item, left to right. Empty: a placeholder icon that opens the full dashboard.
    private(set) var metrics: [MenuBarItem]
    /// True for the one item that holds every metric (as opposed to one item per metric).
    let isSingleItem: Bool
    private let contentLayer = CALayer()
    /// One panel per metric ("all" for the full dashboard), built on first open and kept.
    private var panels: [String: DashboardPanel] = [:]
    /// Last rendered image per metric, so an unchanged metric is never re-rasterised.
    private var cache: [String: (segments: [Segment], image: CGImage, size: CGSize)] = [:]
    /// Horizontal extent of each metric inside the drawn image, for click hit-testing.
    private var hitRanges: [(metric: MenuBarItem, range: ClosedRange<CGFloat>)] = []
    private var lastAppearance: NSAppearance.Name?
    private var lastSpacing: Double?
    private var appearanceObservation: NSKeyValueObservation?
    private var lastWidth: CGFloat = 0
    private var powerStateObserver: (any NSObjectProtocol)?
    private var opening = false

    init(model: AppModel, metrics: [MenuBarItem], autosaveName: String) {
        self.model = model
        self.metrics = metrics
        isSingleItem = autosaveName == "main"
        super.init()
        item.autosaveName = "io.github.kkjjkamal23.Ultstat.\(autosaveName)"
        item.behavior = []
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityIdentifier("ultstat.statusItem.\(autosaveName)")
            button.wantsLayer = true
            contentLayer.contentsGravity = .center
            contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            button.layer?.addSublayer(contentLayer)
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.render(force: true) }
            }
        }
        // The battery pill turns yellow in Low Power Mode, which no battery reading reflects.
        powerStateObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                                    queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.metrics.contains(.battery) else { return }
                self.render(force: true)
            }
        }
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.logVisibility() }
    }

    /// Changes which metrics this item draws, keeping its place in the menu bar.
    func setMetrics(_ m: [MenuBarItem]) {
        guard m != metrics else { return }
        for (key, panel) in panels where !m.map(\.rawValue).contains(key) {
            panel.dismiss()
            panels[key] = nil
        }
        metrics = m
        render(force: true)
    }

    private func logVisibility() {
        let w = item.button?.window
        let frame = w.map { NSStringFromRect($0.frame) } ?? "nil"
        let visible = w?.occlusionState.contains(.visible) ?? false
        log.notice("status item visible=\(self.item.isVisible) windowVisible=\(visible) frame=\(frame, privacy: .public)")
    }

    /// What `metric` (nil: the placeholder shown when nothing is selected) draws right now.
    static func segments(metric: MenuBarItem?, model: AppModel) -> [Segment] {
        let segs = MenuBarRenderer.segments(for: metric.map { [$0] } ?? [], readings: model.readings,
                                            settings: model.settings.stored, histories: model.menuBarHistories())
        return segs.isEmpty ? [Segment(symbol: "gauge.with.dots.needle.33percent", content: .text(""), slot: "")] : segs
    }

    /// Rasterises one metric exactly as the menu bar shows it (also used by the Settings preview).
    static func image(metric: MenuBarItem?, segments segs: [Segment], tint: CGColor, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        if metric == .battery, segs.count == 1, case .battery(let pct, let charging, let time, let plugged) = segs[0].content {
            return MenuBarRenderer.coloredBattery(percent: pct, charging: charging, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                  time: time, textColor: tint, scale: scale, pluggedIn: plugged)
        }
        return MenuBarRenderer.cgImage(for: segs, scale: scale, tint: tint)
    }

    /// Lays metric images out left to right with `spacing` points between them. Returns the combined
    /// image and each part's horizontal extent (in points).
    static func compose(_ parts: [(image: CGImage, size: CGSize)], spacing: CGFloat, scale: CGFloat)
        -> (image: CGImage, size: CGSize, ranges: [ClosedRange<CGFloat>])? {
        guard parts.count > 1 else {
            return parts.first.map { ($0.image, $0.size, [0...$0.size.width]) }
        }
        let width = parts.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(parts.count - 1)
        let height = parts.map(\.size.height).max() ?? 0
        guard let ctx = CGContext(data: nil, width: Int(ceil(width * scale)), height: Int(ceil(height * scale)), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        var x: CGFloat = 0
        var ranges: [ClosedRange<CGFloat>] = []
        for p in parts {
            ctx.draw(p.image, in: CGRect(x: x, y: (height - p.size.height) / 2, width: p.size.width, height: p.size.height))
            ranges.append(x...(x + p.size.width))
            x += p.size.width + spacing
        }
        guard let img = ctx.makeImage() else { return nil }
        return (img, CGSize(width: width, height: height), ranges)
    }

    /// Redraws only when a metric's formatted output, the spacing or the menu-bar appearance changed.
    func render(force: Bool = false) {
        guard let button = item.button else { return }
        let appearance = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
        let spacing = model.settings.stored.itemSpacing
        if force || appearance != lastAppearance { cache.removeAll() }
        var tint = NSColor.labelColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance { tint = NSColor.labelColor.cgColor }
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        var changed = force || appearance != lastAppearance || spacing != lastSpacing || cache.count != max(metrics.count, 1)
        var parts: [(image: CGImage, size: CGSize)] = []
        var labels: [String] = []
        for metric in metrics.isEmpty ? [nil] : metrics.map(Optional.some) {
            let key = metric?.rawValue ?? "all"
            let segs = Self.segments(metric: metric, model: model)
            labels.append(Self.accessibilityText(segs))
            if let hit = cache[key], hit.segments == segs {
                parts.append((hit.image, hit.size))
                continue
            }
            guard let r = Self.image(metric: metric, segments: segs, tint: tint, scale: scale) else { continue }
            cache[key] = (segs, r.image, r.size)
            parts.append(r)
            changed = true
        }
        guard changed else { return }
        lastAppearance = appearance
        lastSpacing = spacing
        guard let (image, size, ranges) = Self.compose(parts, spacing: CGFloat(spacing), scale: scale) else { return }
        // Clicks between two metrics go to the nearer one.
        hitRanges = zip(metrics, ranges).map { ($0, $1) }

        // macOS already spaces adjacent status items; only a hair of padding of our own.
        let width = ceil(size.width) + (metrics.isEmpty ? 8 : 2)
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
        button.setAccessibilityLabel(labels.joined(separator: ", "))
    }

    private static func accessibilityText(_ segs: [Segment]) -> String {
        segs.map { seg -> String in
            switch seg.content {
            case .text(let t): t
            case .stacked(let a, let b): "\(a) \(b)"
            case .bar(let v): MetricFormat.percent(v)
            case .sparkline(let v): v.last.map(MetricFormat.percent) ?? ""
            case .labeled(let c, let v): "\(c) \(v)"
            case .battery(let p, _, let t, _): "Battery \(p)% \(t)"
            }
        }.joined(separator: ", ")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
        } else if isSingleItem, metrics.count > 1 {
            // One item for everything: open All metrics, on the tab of the metric that was clicked.
            if let m = metric(at: event) { UserDefaults.standard.set(DashboardTab(m).rawValue, forKey: DashboardView.tabKey) }
            togglePopover(showAll: true)
        } else {
            togglePopover(metric(at: event))
        }
    }

    /// The metric under a click (the nearest one when the click lands in a gap).
    private func metric(at event: NSEvent?) -> MenuBarItem? {
        guard hitRanges.count > 1, let event, let button = item.button else { return metrics.first }
        let x = button.convert(event.locationInWindow, from: nil).x - contentLayer.frame.minX
        return hitRanges.min { distance(x, $0.range) < distance(x, $1.range) }?.metric
    }

    private func distance(_ x: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat {
        r.contains(x) ? 0 : min(abs(x - r.lowerBound), abs(x - r.upperBound))
    }

    var isDashboardOpen: Bool { panels.values.contains(where: \.isVisible) }

    func closeDashboard() { panels.values.forEach { $0.dismiss() } }

    /// The item's frame in screen coordinates (nil when hidden by a menu-bar manager).
    var anchorRect: NSRect? {
        item.button.flatMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } }
    }

    /// Screen rect of one metric inside this item, so its panel opens right under it.
    private func anchorRect(for metric: MenuBarItem?) -> NSRect? {
        guard let whole = anchorRect, let metric, let r = hitRanges.first(where: { $0.metric == metric })?.range else { return anchorRect }
        let minX = whole.minX + contentLayer.frame.minX + r.lowerBound
        return NSRect(x: minX, y: whole.minY, width: r.upperBound - r.lowerBound, height: whole.height)
    }

    /// Opens the panel for `requested` (default: the first metric, or All metrics when `showAll`),
    /// or closes it if it is open.
    func togglePopover(_ requested: MenuBarItem? = nil, showAll: Bool = false) {
        // A panel is waiting for its first readings (a few ms): a second click must not open another
        // one, or detailed sampling would stay on after it closes.
        guard !opening else { return }
        let target = showAll ? nil : requested ?? metrics.first
        let key = target?.rawValue ?? "all"
        if let open = panels.first(where: { $0.value.isVisible }) {
            open.value.dismiss()
            if open.key == key { return }   // clicking the open metric again closes it
        } else if let closed = panels[key]?.lastDismissed, Date().timeIntervalSince(closed) < 0.4 {
            // This click's mouse-down already closed the panel through its "click outside" monitor;
            // its mouse-up must not reopen it.
            return
        }
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // Built once and kept: it reads `panelReadings`, which only change while it is visible.
        model.closeAllPanels()   // one panel at a time
        let p = panels[key] ?? makePanel(target)
        p.onClose = { [weak self] in self?.dashboardClosed() }
        panels[key] = p
        item.button?.highlight(true)
        let anchor = anchorRect(for: target)
        // Shown once every sensor has been read (a few ms), so the panel is measured with all its rows.
        opening = true
        model.popoverOpened { [weak self] in
            self?.opening = false
            p.show(below: anchor)
        }
        log.notice("dashboard open took \(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, format: .fixed(precision: 1)) ms")
    }

    private func makePanel(_ metric: MenuBarItem?) -> DashboardPanel {
        if let metric {
            return DashboardPanel(rootView: ModuleView(item: metric).environment(model), width: ModulePanelSize.width, fitsContent: true)
        }
        return DashboardPanel(rootView: DashboardView().environment(model))
    }

    /// Removes the item from the menu bar (settings changed).
    func remove() {
        if let o = powerStateObserver { NotificationCenter.default.removeObserver(o) }
        closeDashboard()
        NSStatusBar.system.removeStatusItem(item)
    }

    private func dashboardClosed() {
        if !isDashboardOpen { item.button?.highlight(false) }
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

import AppKit
import os
import SwiftUI

/// The dashboard window. A borderless panel rather than an `NSPopover`: popovers anchor to the
/// status-item button, and menu-bar managers (Latch, Bartender, Ice) move that button into hidden
/// or off-screen areas, which pushed the popover partly off the top of the screen. This panel is
/// positioned under the item when it's visible and always clamped to the screen's visible frame.
@MainActor
final class DashboardPanel: NSPanel {
    static let size = NSSize(width: 400, height: 640)

    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    var onClose: (() -> Void)?
    /// When the panel last closed (used to tell "click the icon to close" from "click to open").
    private(set) var lastDismissed: Date?

    private let panelWidth: CGFloat
    private let fitsContent: Bool
    private var host = NSView()
    /// Owns the SwiftUI content; asked for the content's natural height when the panel is shown.
    private var controller: NSHostingController<AnyView>?
    static let cornerRadius: CGFloat = 22

    init(rootView: some View, width: CGFloat = DashboardPanel.size.width, fitsContent: Bool = false) {
        panelWidth = width
        self.fitsContent = fitsContent
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: width, height: Self.size.height)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        let controller = NSHostingController(rootView: AnyView(rootView))
        controller.sizingOptions = []
        self.controller = controller
        let host = controller.view
        self.host = host
        // macOS 26 Liquid Glass behind everything the panel shows.
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        // A light tint keeps text readable over bright windows and wallpapers behind the panel.
        glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55)
        glass.contentView = host
        contentView = glass
        // Panels are sized once, when shown (resizing an open one drew the old layout offset);
        // late-arriving rows have reserved space, and content that outgrows the panel scrolls.
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
    }

    override var canBecomeKey: Bool { true }

    /// Places the panel under `anchor` (screen coordinates), clamped fully on screen.
    func show(below anchor: NSRect?) {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        // Module panels size to their content (like Stats); the summary dashboard uses its fixed size.
        // Apply pending SwiftUI updates (the readings that just arrived) before measuring.
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        // The content's natural height at the panel's width (fittingSize is 0 inside the glass view).
        let fitting = controller?.sizeThatFits(in: CGSize(width: panelWidth, height: 10_000)).height ?? 0
        let wanted = fitsContent && fitting > 100 ? fitting : Self.size.height
        Logger(subsystem: "io.github.kkjjkamal23.Ultstat", category: "panel")
            .notice("panel fit content=\(fitting, format: .fixed(precision: 0)) height=\(wanted, format: .fixed(precision: 0))")
        let height = min(wanted, visible.height - margin * 2)
        let width = panelWidth
        // An anchor that is off-screen or zero-sized (item hidden by a menu-bar manager) falls back
        // to the top-right corner, where status items normally live.
        let usable = anchor.flatMap { visible.insetBy(dx: -1, dy: -60).intersects($0) && $0.width > 0 ? $0 : nil }
        let midX = usable?.midX ?? (visible.maxX - width / 2 - margin)
        let top = min(usable.map { $0.minY - 6 } ?? visible.maxY - 4, visible.maxY - 4)
        var x = midX - width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - width - margin)
        let y = max(top - height, visible.minY + margin)
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)

        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(nil)   // don't park focus on the first control
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            animator().alphaValue = 1
        }
        installMonitors()
    }

    func dismiss() {
        guard isVisible else { return }
        lastDismissed = Date()
        removeMonitors()
        orderOut(nil)
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps close the panel, like a menu.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                MainActor.assumeIsolated { self?.dismiss() }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }
}

import AppKit
import SwiftUI

/// The dashboard window. A borderless panel rather than an `NSPopover`: popovers anchor to the
/// status-item button, and menu-bar managers (Latch, Bartender, Ice) move that button into hidden
/// or off-screen areas, which pushed the popover partly off the top of the screen. This panel is
/// positioned under the item when it's visible and always clamped to the screen's visible frame.
@MainActor
final class DashboardPanel: NSPanel {
    static let size = NSSize(width: 384, height: 560)

    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    var onClose: (() -> Void)?

    init(rootView: some View) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
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
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// Places the panel under `anchor` (screen coordinates), clamped fully on screen.
    func show(below anchor: NSRect?) {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        let height = min(Self.size.height, visible.height - margin * 2)
        let width = Self.size.width
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            animator().alphaValue = 1
        }
        installMonitors()
    }

    func dismiss() {
        guard isVisible else { return }
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

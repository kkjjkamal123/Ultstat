import AppKit
import SwiftUI

/// Owns the Settings window. The SwiftUI hierarchy exists only while the window is open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    var isOpen: Bool { window != nil }

    func show() {
        // A menu-bar (accessory) app is often refused activation, so its window opens without focus
        // and clicks only activate it. Become a regular app while Settings is open.
        NSApp.setActivationPolicy(.regular)
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView().environment(model))
        // A non-activating panel becomes key without the app being activated. macOS may refuse to
        // activate a menu-bar app (cooperative activation), and a plain window then never takes
        // focus, so clicks only tried to activate the app and never reached the controls.
        let w = SettingsPanel(contentViewController: host)
        w.title = "Ultstat Settings"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.setContentSize(NSSize(width: 720, height: 540))
        w.becomesKeyOnlyIfNeeded = false
        w.isFloatingPanel = false
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.identifier = NSUserInterfaceItemIdentifier("ultstat.settings")
        w.setFrameAutosaveName("UltstatSettings")
        if !w.setFrameUsingName("UltstatSettings") { w.center() }
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        w.makeKey()
        // Take key again once the window is actually on screen; a launch or another app finishing
        // activation can otherwise leave it visible but unfocused.
        DispatchQueue.main.async { [weak w] in
            w?.makeKey()
            w?.makeFirstResponder(w?.contentView)
        }
    }

    func close() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar only
    }
}

/// Settings window that can always take keyboard focus.
final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

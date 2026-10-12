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
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: SettingsView().environment(model))
        let w = NSWindow(contentViewController: host)
        w.title = "Ultstat Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.identifier = NSUserInterfaceItemIdentifier("ultstat.settings")
        w.setFrameAutosaveName("UltstatSettings")
        if !w.setFrameUsingName("UltstatSettings") { w.center() }
        window = w
        // An accessory app must become active for its window to take focus.
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
    }
}

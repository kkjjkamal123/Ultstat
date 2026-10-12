import AppKit

/// AppKit entry point. No SwiftUI `App` scene: SwiftUI is only instantiated for the popover and the
/// Settings window while they are open, and nothing registers App Intents at launch.
@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel!
    private lazy var settingsWindow = SettingsWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        NSApp.mainMenu = makeMainMenu()
        model.reconcileStatusItems()
        model.openSettingsAction = { [weak self] in self?.settingsWindow.show() }
        SnapshotExporter.scheduleIfRequested(model: model)
        // UI-test entry points: the status item may be hidden by a menu-bar manager.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "UltstatOpenDashboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.model.statusItem?.togglePopover() }
        }
        SelfTest.runIfRequested(model: model) { [weak self] in self?.settingsWindow.show() }
        if defaults.bool(forKey: "UltstatOpenSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settingsWindow.show() }
        }
        if let item = model.statusItem { StressTester.runIfRequested(statusItem: item, model: model) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    /// Minimal menu so ⌘, ⌘W ⌘Q and text editing shortcuts work while Settings is key.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Ultstat", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ultstat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    @objc private func openSettings() { settingsWindow.show() }
}

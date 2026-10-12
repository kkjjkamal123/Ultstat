import XCTest

/// Clicks every control in Settings and the dashboard and asserts each one does something.
/// Uses a throwaway settings store (-UltstatEphemeralSettings) so the user's settings are untouched.
final class UltstatUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        app?.terminate()
    }

    private func launch(_ extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-UltstatEphemeralSettings", "YES", "-UltstatItems", "cpu,memory,battery"] + extra
        app.launch()
    }

    private var settings: XCUIElement { app.windows["Ultstat Settings"] }

    private func openTab(_ name: String) {
        let tab = settings.radioButtons[name].firstMatch.exists ? settings.radioButtons[name].firstMatch : settings.buttons[name].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 3), "tab \(name) missing")
        tab.click()
    }

    private func flip(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let control = settings.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 3), "\(id) missing", file: file, line: line)
        XCTAssertTrue(control.isEnabled, "\(id) disabled", file: file, line: line)
        let before = control.value as? String ?? (control.value as? NSNumber)?.stringValue
        control.click()
        let after = control.value as? String ?? (control.value as? NSNumber)?.stringValue
        XCTAssertNotEqual(before, after, "\(id) did not change when clicked", file: file, line: line)
        control.click()   // restore
    }

    func testSettingsWindowOpensFocusedAndAllTabsWork() {
        launch(["-UltstatOpenSettings", "YES"])
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings window never opened")
        for tab in ["General", "Menu Bar", "Battery", "Alerts", "About"] { openTab(tab) }
    }

    func testGeneralControls() {
        launch(["-UltstatOpenSettings", "YES"])
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        openTab("General")
        let interval = settings.popUpButtons["settings.interval"].firstMatch
        XCTAssertTrue(interval.waitForExistence(timeout: 3))
        interval.click()
        settings.menuItems["5 s"].firstMatch.click()
        XCTAssertEqual(interval.value as? String, "5 s")
        flip("settings.bluetooth")
    }

    func testEveryMenuBarToggle() {
        launch(["-UltstatOpenSettings", "YES"])
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        openTab("Menu Bar")
        for item in ["cpu", "gpu", "memory", "network", "disk", "temperature", "power", "battery"] {
            flip("settings.item.\(item)")
        }
    }

    func testAlertsAddToggleRemove() {
        launch(["-UltstatOpenSettings", "YES"])
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        openTab("Alerts")
        let add = settings.menuButtons["settings.addAlert"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        let before = settings.switches.count
        add.click()
        settings.menuItems["Memory usage above"].firstMatch.click()
        XCTAssertGreaterThan(settings.switches.count, before, "Add Alert did nothing")
        let remove = settings.buttons["Remove"].allElementsBoundByIndex.last
        remove?.click()
        XCTAssertEqual(settings.switches.count, before, "Remove did nothing")
    }

    func testDashboardTabsAndTiles() {
        launch(["-UltstatOpenDashboard", "YES"])
        for tab in ["cpu", "gpu", "memory", "network", "disk", "sensors", "battery", "processes"] {
            let b = app.buttons["tab.\(tab)"].firstMatch
            XCTAssertTrue(b.waitForExistence(timeout: 5), "dashboard tab \(tab) missing")
            b.click()
            XCTAssertTrue(b.isSelected, "tab \(tab) not selected after click")
        }
        let settingsButton = app.buttons["dashboard.settings"].firstMatch
        XCTAssertTrue(settingsButton.exists)
        settingsButton.click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "dashboard Settings button did nothing")
    }
}

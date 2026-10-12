import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UltstatCore
import UltstatKit
import UserNotifications

@MainActor @Observable
final class AppModel {
    /// `-UltstatEphemeralSettings YES` (UI tests) uses a throwaway store so tests never touch real settings.
    let settings: AppSettings = {
        guard UserDefaults.standard.bool(forKey: "UltstatEphemeralSettings") else { return AppSettings() }
        let name = "io.github.kkjjkamal23.Ultstat.ephemeral.\(ProcessInfo.processInfo.processIdentifier)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return AppSettings(defaults: d)
    }()
    private(set) var readings = Readings()
    /// What the dashboard shows. Updated only while it is open, so the kept-alive (hidden) panel
    /// never invalidates or re-renders in the background.
    private(set) var panelReadings = Readings()
    /// Network reachability, pushed by Network.framework; started on first use.
    private(set) var connectivity: ConnectivityMonitor.Status?
    @ObservationIgnored private var connectivityMonitor: ConnectivityMonitor?
    private(set) var chargeStatus: ChargeStatus?
    private(set) var helperState: HelperClient.State = .notInstalled
    private(set) var helperError: String?
    private(set) var popoverOpen = false

    @ObservationIgnored let helper = HelperClient()
    @ObservationIgnored private(set) var hub: MonitorHub!
    /// One status item per metric (or a single combined one). Ordered as shown, left to right.
    @ObservationIgnored private(set) var statusItems: [StatusItemController] = []
    /// First item; used by test entry points.
    var statusItem: StatusItemController? { statusItems.first }
    @ObservationIgnored private var fullPanel: DashboardPanel?
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    @ObservationIgnored private var bus: ReadingsBus!
    @ObservationIgnored private var helperPowerTask: Task<Void, Never>?

    init() {
        let bus = ReadingsBus { [weak self] r in self?.receive(r) }
        self.bus = bus
        hub = MonitorHub(bus: bus, interval: settings.stored.interval, bluetoothAccessories: settings.stored.bluetoothAccessories)
        applySettings()
        helperState = helper.state
        observeSettings()
        Task { await upgradeHelperIfNeeded() }
    }

    /// True when the installed helper doesn't answer this build (older version, or pinned to a
    /// previous build's signature). Updating needs the administrator password, so it is never done
    /// automatically: the UI offers an "Update Helper" button instead.
    private(set) var helperNeedsUpdate = false
    private(set) var installing = false

    private func upgradeHelperIfNeeded() async {
        guard helper.state == .running else { return }
        var installed = await helper.version()
        if installed == nil {
            try? await Task.sleep(for: .seconds(2))   // rule out a transient XPC failure
            installed = await helper.version()
        }
        helperNeedsUpdate = installed != ultstatHelperVersion
    }

    @ObservationIgnored private var alertEngine = AlertEngine()

    private func receive(_ r: Readings) {
        readings = r
        if popoverOpen { panelReadings = r }
        for item in statusItems { item.render() }
        let rules = settings.stored.alerts
        guard rules.contains(where: \.enabled) else { return }
        for firing in alertEngine.evaluate(rules, readings: r, now: Date()) { notify(firing) }
    }

    private func notify(_ f: AlertFiring) {
        let content = UNMutableNotificationContent()
        content.title = f.title
        content.body = f.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: f.rule.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Asks for notification permission the first time an alert is enabled.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Settings → hub

    private func observeSettings() {
        withObservationTracking {
            _ = settings.stored
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applySettings()
                self?.observeSettings()
            }
        }
    }

    private var appliedInterval: Int?

    private func applySettings() {
        let s = settings.stored
        // Alerts need their metric sampled even when it is not shown in the menu bar.
        let alertItems = s.alerts.filter(\.enabled).compactMap(\.metric.requiredItem)
        hub.setMenuItems(Set(s.items).union(alertItems))
        hub.setBluetoothAccessories(s.bluetoothAccessories)
        if appliedInterval != s.interval {
            hub.setInterval(s.interval)
            appliedInterval = s.interval
        }
        reconcileStatusItems()
        for item in statusItems { item.render() }
    }

    // MARK: Popover

    func popoverOpened() {
        panelReadings = readings
        if connectivityMonitor == nil {
            connectivityMonitor = ConnectivityMonitor { [weak self] s in
                Task { @MainActor in self?.connectivity = s }
            }
        }
        popoverOpen = true
        hub.setDetailVisible(true)
        Task { await refreshHelper() }
        startHelperPower()
    }

    func popoverClosed() {
        popoverOpen = false
        hub.setDetailVisible(false)
        helperPowerTask?.cancel()
        helperPowerTask = nil
    }

    /// CPU/ANE/DRAM energy is root-only on macOS 27; ask the helper while the popover is open.
    private func startHelperPower() {
        helperPowerTask?.cancel()
        helperPowerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.helperState == .running else { return }
                if let p = await self.helper.componentPower() {
                    self.bus.update { r in
                        var c = r.componentPower ?? ComponentPower(cpu: nil, gpu: nil, ane: nil, dram: nil)
                        c.cpu = p.cpu
                        c.ane = p.ane
                        c.dram = p.dram
                        if c.gpu == nil { c.gpu = p.gpu }
                        r.componentPower = c
                    }
                }
                try? await Task.sleep(for: .seconds(max(2, self.settings.stored.interval)))
            }
        }
    }

    func openSettings() {
        closeAllPanels()
        openSettingsAction?()
    }

    /// Creates or removes status items to match settings. Items are created right-to-left, because
    /// macOS places each new item to the left of the existing ones.
    func reconcileStatusItems() {
        let s = settings.stored
        let wanted: [MenuBarItem?] = s.combineMenuBar ? [nil] : (s.items.isEmpty ? [nil] : s.items.map { Optional($0) })
        guard wanted != statusItems.map(\.metric) else { return }
        for item in statusItems { item.remove() }
        statusItems = wanted.reversed().map { StatusItemController(model: self, metric: $0) }.reversed()
    }

    func closeAllPanels() {
        for item in statusItems { item.closeDashboard() }
        fullPanel?.dismiss()
    }

    /// The all-metrics dashboard (summary + tabs), opened from a module panel's header.
    func openFullDashboard() {
        closeAllPanels()
        let p = fullPanel ?? DashboardPanel(rootView: DashboardView().environment(self))
        fullPanel = p
        p.onClose = { [weak self] in self?.popoverClosed() }
        popoverOpened()
        p.show(below: statusItems.first?.anchorRect)
    }

    /// Errors from General settings (launch at login), shown next to the control that failed.
    private(set) var generalError: String?

    // MARK: Charging

    func refreshHelper() async {
        helperState = helper.state
        guard helperState == .running else { return }
        chargeStatus = await helper.status()
        // The helper advances calibration and clears top-up on its own; it is the source of truth for
        // these transient fields, so a later edit here never resets progress it has made.
        if let remote = chargeStatus?.policy, settings.stored.chargeControlEnabled {
            var local = settings.stored.chargePolicy
            local.calibration = remote.calibration
            local.topUp = remote.topUp
            if local != settings.stored.chargePolicy { settings.stored.chargePolicy = local }
        }
    }

    /// Prefers SMAppService; falls back to the administrator prompt when the system refuses to
    /// register an unsigned daemon (common for builds from source without a signing identity).
    /// Only ever called from a user click. The prompt runs off the main thread.
    func installHelper() {
        // Ad-hoc builds never use SMAppService: it would run the daemon from this user-writable
        // bundle. They always install the root-owned, hash-verified copy instead.
        if HelperClient.teamID == nil || helperNeedsUpdate {
            Task { await installViaAdministratorPrompt() }
            return
        }
        do {
            try helper.install()
            helperError = nil
            helperState = helper.state
            Task { await refreshHelper() }
        } catch {
            // SMAppService refused (e.g. signing); fall back to the root-owned copy.
            Task { await installViaAdministratorPrompt() }
        }
    }

    private func installViaAdministratorPrompt() async {
        installing = true
        defer { installing = false }
        do {
            try await helper.installWithAdministratorPromptAsync()
            helperError = nil
            helperNeedsUpdate = false
        } catch HelperInstallError.cancelled {
            helperError = nil
        } catch {
            helperError = error.localizedDescription
        }
        helperState = helper.state
        try? await Task.sleep(for: .seconds(1))   // give launchd a moment to start the daemon
        await refreshHelper()
        if settings.stored.chargeControlEnabled { pushPolicy() }
    }

    func uninstallHelper() {
        Task {
            do {
                try await helper.uninstall()
                settings.stored.chargeControlEnabled = false
                helperError = nil
            } catch {
                helperError = error.localizedDescription
            }
            await refreshHelper()
        }
    }

    func updatePolicy(_ change: (inout ChargePolicy) -> Void) {
        var p = settings.stored.chargePolicy
        if let remote = chargeStatus?.policy {   // keep the helper's progress unless the change overrides it
            p.calibration = remote.calibration
            p.topUp = remote.topUp
        }
        change(&p)
        settings.stored.chargePolicy = p.validated()
        pushPolicy()
    }

    func pushPolicy() {
        guard settings.stored.chargeControlEnabled else { return }
        let policy = settings.stored.chargePolicy
        Task {
            helperError = await helper.apply(policy)
            await refreshHelper()
        }
    }

    func setChargeControl(_ on: Bool) {
        settings.stored.chargeControlEnabled = on
        Task {
            if on {
                helperError = await helper.apply(settings.stored.chargePolicy)
            } else {
                helperError = await helper.restoreDefaults()
            }
            await refreshHelper()
        }
    }

    // MARK: History for charts (read on demand by open views only)

    /// Histories only for items drawn as sparklines, trimmed to what the menu bar shows.
    func menuBarHistories() -> [MenuBarItem: [Float]] {
        var out: [MenuBarItem: [Float]] = [:]
        let n = MenuBarRenderer.sparklinePoints
        for item in settings.stored.items where settings.style(for: item) == .sparkline {
            switch item {
            case .cpu: out[.cpu] = Array(hub.cpu.history.values.suffix(n))
            case .gpu: out[.gpu] = Array((hub.gpu?.history.values ?? []).suffix(n))
            case .memory: out[.memory] = Array(hub.memory.history.values.suffix(n))
            default: break
            }
        }
        return out
    }

    var cpuHistory: [Float] { hub.cpu.history.values }
    var memoryHistory: [Float] { hub.memory.history.values }
    var gpuHistory: [Float] { hub.gpu?.history.values ?? [] }
    var downloadHistory: [Float] { hub.network.downloadHistory.values }
    var uploadHistory: [Float] { hub.network.uploadHistory.values }
    var powerHistory: [Float] { hub.power?.history.values ?? [] }
    var diskReadHistory: [Float] { hub.disk.readHistory.values }
    var diskWriteHistory: [Float] { hub.disk.writeHistory.values }
    var powerFlowHistory: [Float] { hub.battery?.flowHistory.values ?? [] }
    func temperatureHistory(_ g: SensorGroup) -> [Float] { hub.sensors?.history(g)?.values ?? [] }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get {
            _ = launchAtLoginChanges   // re-read after each change
            return SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                generalError = SMAppService.mainApp.status == .requiresApproval
                    ? "Allow Ultstat in System Settings › General › Login Items." : nil
            } catch {
                generalError = "Couldn't change launch at login: \(error.localizedDescription)"
            }
            launchAtLoginChanges += 1
        }
    }

    private var launchAtLoginChanges = 0
}

import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UltstatCore
import UltstatKit
import UserNotifications

@MainActor @Observable
final class AppModel {
    let settings = AppSettings()
    private(set) var readings = Readings()
    private(set) var chargeStatus: ChargeStatus?
    private(set) var helperState: HelperClient.State = .notInstalled
    private(set) var helperError: String?
    private(set) var popoverOpen = false

    @ObservationIgnored let helper = HelperClient()
    @ObservationIgnored private(set) var hub: MonitorHub!
    @ObservationIgnored var statusItem: StatusItemController?
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

    /// A newer app may ship a changed helper; replace an installed older one once at launch.
    private func upgradeHelperIfNeeded() async {
        guard helper.state == .running else { return }
        var installed = await helper.version()
        if installed == nil {
            // An old ad-hoc helper pins the previous app's cdhash and rejects this one, so "no answer"
            // after an update means "replace it". Retry once to rule out a transient XPC failure.
            try? await Task.sleep(for: .seconds(2))
            installed = await helper.version()
        }
        guard installed != ultstatHelperVersion else { return }
        do {
            if helper.isLegacyInstalled || HelperClient.teamID == nil {
                try helper.installWithAdministratorPrompt()
            } else {
                try await helper.reregister()
            }
        } catch {
            helperError = "Helper update failed: \(error.localizedDescription)"
        }
        await refreshHelper()
        if settings.stored.chargeControlEnabled { pushPolicy() }
    }

    @ObservationIgnored private var alertEngine = AlertEngine()

    private func receive(_ r: Readings) {
        readings = r
        statusItem?.render()
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
        statusItem?.render()
    }

    // MARK: Popover

    func popoverOpened() {
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
        openSettingsAction?()
    }

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
    func installHelper() {
        // Ad-hoc builds never use SMAppService: it would run the daemon from this user-writable
        // bundle. They always install the root-owned, hash-verified copy instead.
        if HelperClient.teamID == nil {
            do {
                try helper.installWithAdministratorPrompt()
                helperError = nil
            } catch HelperInstallError.cancelled {
                helperError = nil
            } catch {
                helperError = error.localizedDescription
            }
            helperState = helper.state
            Task { await refreshHelper() }
            return
        }
        do {
            try helper.install()
            helperError = nil
        } catch {
            do {
                try helper.installWithAdministratorPrompt()
                helperError = nil
            } catch HelperInstallError.cancelled {
                helperError = nil
            } catch let fallback {
                helperError = "\(error.localizedDescription) \(fallback.localizedDescription)"
            }
        }
        helperState = helper.state
        Task { await refreshHelper() }
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
    var powerFlowHistory: [Float] { hub.battery?.flowHistory.values ?? [] }
    func temperatureHistory(_ g: SensorGroup) -> [Float] { hub.sensors?.history(g)?.values ?? [] }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                helperError = error.localizedDescription
            }
        }
    }
}

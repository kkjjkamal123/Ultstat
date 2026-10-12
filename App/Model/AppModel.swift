import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UltstatCore
import UltstatKit

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

    init() {
        let bus = ReadingsBus { [weak self] r in self?.receive(r) }
        hub = MonitorHub(bus: bus, interval: settings.stored.interval, bluetoothAccessories: settings.stored.bluetoothAccessories)
        applySettings()
        helperState = helper.state
        observeSettings()
    }

    private func receive(_ r: Readings) {
        readings = r
        statusItem?.render()
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
        hub.setMenuItems(Set(s.items))
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
    }

    func popoverClosed() {
        popoverOpen = false
        hub.setDetailVisible(false)
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

    func installHelper() {
        do {
            try helper.install()
            helperError = nil
        } catch {
            helperError = error.localizedDescription
        }
        helperState = helper.state
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

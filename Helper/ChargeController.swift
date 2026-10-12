import Foundation
import IOKit.pwr_mgt
import os
import UltstatCore

private let log = Logger(subsystem: "io.github.kkjjkamal23.Ultstat.Helper", category: "charge")

// IOKit power messages are C macros (iokit_common_msg) that Swift does not import.
private let kIOMessageCanSystemSleep: natural_t = 0xE000_0270
private let kIOMessageSystemWillSleep: natural_t = 0xE000_0280
private let kIOMessageSystemHasPoweredOn: natural_t = 0xE000_0300

/// Owns the charging policy and enforces it. All state lives on `queue`.
final class ChargeController: @unchecked Sendable {
    static let policyURL = URL(fileURLWithPath: "/Library/Application Support/Ultstat/policy.plist")

    let queue = DispatchQueue(label: "ultstat.helper.charge", qos: .utility)
    private let smc: SMC?
    private let actuator: (any ChargeActuator)?
    private var battery: BatteryMonitor?
    private var machine = ChargeStateMachine()
    private(set) var policy: ChargePolicy
    private var lastError: String?
    /// Kept separately so a successful charge write doesn't clear an LED failure.
    private var ledError: String?
    private var lastPercent: Double = 0
    private var sleeping = false
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var rootPowerDomain: io_connect_t = 0
    private let batteryTempKeys: [SMCKey]
    /// Fires when a calibration hold ends, in case no battery event arrives at that moment.
    private var holdTimer: (any DispatchSourceTimer)?

    init() {
        let smc = try? SMC()
        self.smc = smc
        actuator = smc.flatMap {
            makeChargeActuator(smc: $0, originalsURL: Self.policyURL.deletingLastPathComponent().appendingPathComponent("native-originals.plist"))
        }
        policy = Self.loadPolicy()
        batteryTempKeys = ["TB0T", "TB1T", "TB2T"].map { SMCKey($0) }.filter { smc?.info($0) != nil }
        log.info("mechanism=\(self.actuator?.mechanism.rawValue ?? "unsupported", privacy: .public) policy.limit=\(self.policy.limit)")
    }

    var mechanism: ChargeStatus.Mechanism { actuator?.mechanism ?? .unsupported }

    func start() {
        queue.async { [self] in
            battery = BatteryMonitor { [weak self] _ in
                guard let self else { return }
                queue.async { self.evaluate() }
            }
            battery?.start()
            registerForSleep()
            applyLED()
            evaluate()
        }
    }

    // MARK: XPC entry points (called on the XPC queue; hop to `queue`)

    func apply(_ newPolicy: ChargePolicy) -> String? {
        queue.sync {
            policy = newPolicy.validated()
            Self.savePolicy(policy)
            applyLED()
            evaluate()
            return combinedError
        }
    }

    func status() -> ChargeStatus {
        queue.sync { ChargeStatus(mechanism: mechanism, mode: machine.mode, policy: policy, lastError: combinedError) }
    }

    func restoreDefaults() -> String? {
        queue.sync {
            policy = .stock
            try? FileManager.default.removeItem(at: Self.policyURL)
            return restoreStockLocked()
        }
    }

    /// Called on SIGTERM (shutdown, restart, update). Never leaves the adapter bypassed. SMC-based
    /// limits are released because nothing enforces them while the helper is gone; the native
    /// macOS limit is kept because macOS enforces it even while the Mac is off.
    func shutdown() {
        queue.sync {
            do { try actuator?.prepareForExit() } catch { log.error("exit prep failed: \(String(describing: error), privacy: .public)") }
        }
    }

    // MARK: Policy evaluation

    private func evaluate() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let actuator, !sleeping, let snap = battery?.latest else { return }
        let percent = policy.useHardwarePercent ? (snap.hardwarePercent ?? Double(snap.percent)) : Double(snap.percent)
        lastPercent = percent
        // ExternalConnected stays true while the adapter is bypassed for discharge (observed on M5 with
        // CHIE=0x08: IOKit still reported ExternalConnected=Yes, IsCharging=No). If some firmware
        // reported false, the state machine would restore the adapter: the safe failure direction.
        let inputs = ChargeInputs(percent: percent, externalConnected: snap.externalConnected, batteryTemperature: batteryTemperature())
        let out = machine.step(policy: policy, inputs: inputs)
        do {
            try actuator.apply(out, mode: machine.mode, policy: policy, percent: percent)
            lastError = nil
        } catch {
            lastError = "\(error)"
            log.error("apply failed: \(String(describing: error), privacy: .public)")
        }
        if machine.topUpCompleted {
            policy.topUp = false
            Self.savePolicy(policy)
        }
        if machine.calibrationChanged {
            policy.calibration = machine.nextCalibration
            Self.savePolicy(policy)
            log.info("calibration phase -> \(String(describing: self.policy.calibration), privacy: .public)")
        }
        scheduleHoldTimer()
    }

    private func scheduleHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
        guard case .holding(let until) = policy.calibration else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(wallDeadline: .now() + max(1, until.timeIntervalSinceNow), leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.evaluate() }
        t.resume()
        holdTimer = t
    }

    private var combinedError: String? {
        let parts = [lastError, ledError.map { "MagSafe LED: \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private func applyLED() {
        do {
            try actuator?.setMagSafeLED(policy.magSafeLED)
            ledError = nil
        } catch {
            ledError = "\(error)"
            log.error("LED failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func batteryTemperature() -> Double? {
        guard let smc else { return nil }
        return batteryTempKeys.compactMap { smc.double($0) }.filter { $0 > 0 && $0 < 100 }.max()
    }

    private func restoreStockLocked() -> String? {
        do {
            try actuator?.restoreStock()
            machine = ChargeStateMachine()
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: Sleep / wake

    private func registerForSleep() {
        var notifier: io_object_t = 0
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let root = IORegisterForSystemPower(refcon, &powerPort, { refcon, _, message, argument in
            guard let refcon else { return }
            Unmanaged<ChargeController>.fromOpaque(refcon).takeUnretainedValue().handlePower(message, argument)
        }, &notifier)
        guard root != 0, let powerPort else { return }
        rootPowerDomain = root
        powerNotifier = notifier
        IONotificationPortSetDispatchQueue(powerPort, queue)
    }

    private func handlePower(_ message: natural_t, _ argument: UnsafeMutableRawPointer?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let id = Int(bitPattern: argument)
        switch message {
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange(rootPowerDomain, id)
        case kIOMessageSystemWillSleep:
            prepareForSleep()
            sleeping = true
            IOAllowPowerChange(rootPowerDomain, id)
        case kIOMessageSystemHasPoweredOn:
            sleeping = false
            battery?.refresh()
            evaluate()
        default:
            break
        }
    }

    /// The helper is frozen during sleep, so SMC-based control can't react. Stop any discharge and,
    /// when a limit is active, pause charging so the battery can't overshoot. The native limit
    /// (macOS 27+) is enforced by macOS itself, so only the discharge is cancelled there.
    private func prepareForSleep() {
        guard let actuator else { return }
        let plan = ChargeStateMachine.sleepPlan(policy: policy)
        do { try actuator.apply(plan.outputs, mode: plan.mode, policy: policy, percent: lastPercent) } catch {
            log.error("sleep prep failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Persistence

    private static func loadPolicy() -> ChargePolicy {
        guard let data = try? Data(contentsOf: policyURL),
              let p = try? PropertyListDecoder().decode(ChargePolicy.self, from: data) else { return .stock }
        return p.validated()
    }

    private static func savePolicy(_ p: ChargePolicy) {
        do {
            try FileManager.default.createDirectory(at: policyURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try PropertyListEncoder().encode(p).write(to: policyURL, options: .atomic)
        } catch {
            log.error("save policy failed: \(String(describing: error), privacy: .public)")
        }
    }
}

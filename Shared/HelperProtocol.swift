import Foundation
import UltstatCore

/// Mach service name of the privileged helper (root LaunchDaemon).
let ultstatHelperMachService = "io.github.kkjjkamal23.Ultstat.Helper"

/// Bumped whenever the protocol or helper behaviour changes; the app reinstalls on mismatch.
let ultstatHelperVersion = 2

/// The entire privileged surface. Every argument is range-checked by the helper; there is no
/// generic "write SMC key" or "write preference" call.
@objc protocol UltstatHelperProtocol {
    func version(reply: @escaping @Sendable (Int) -> Void)

    /// Applies a complete charging policy (encoded `ChargePolicy`). The helper persists it and
    /// enforces it across app quits, sleep and reboots.
    func apply(policy: Data, reply: @escaping @Sendable (String?) -> Void)

    /// Current controller state (encoded `ChargeStatus`).
    func status(reply: @escaping @Sendable (Data?) -> Void)

    /// Average CPU/GPU/ANE/DRAM power since the previous call (encoded `ComponentPower`).
    /// Read-only; root can see the IOReport energy counters that macOS 27 hides from apps.
    func componentPower(reply: @escaping @Sendable (Data?) -> Void)

    /// Restores stock charging behaviour and forgets the policy. Used on uninstall.
    func restoreDefaults(reply: @escaping @Sendable (String?) -> Void)
}

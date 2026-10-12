import Foundation
import os
import ServiceManagement
import UltstatCore
import UltstatKit

private let log = Logger(subsystem: "io.github.kkjjkamal23.Ultstat", category: "helper")

/// Installs and talks to the privileged helper.
@MainActor
final class HelperClient {
    enum State: Equatable {
        case notInstalled
        case needsApproval
        case running
        case unavailable(String)
    }

    private let service = SMAppService.daemon(plistName: "io.github.kkjjkamal23.Ultstat.Helper.plist")
    private var connection: NSXPCConnection?

    var state: State {
        switch service.status {
        case .enabled: .running
        case .requiresApproval: .needsApproval
        // `.notFound` is also what a daemon that was never registered reports, so it means
        // "not installed" here; a genuinely missing helper surfaces as a register() error.
        case .notRegistered, .notFound: .notInstalled
        @unknown default: .unavailable("Unknown helper state.")
        }
    }

    func install() throws {
        try service.register()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() async throws {
        _ = await restoreDefaults()
        connection?.invalidate()
        connection = nil
        try await service.unregister()
    }

    // MARK: Calls

    func version() async -> Int? {
        await call { proxy, done in proxy.version { done($0) } }
    }

    func apply(_ policy: ChargePolicy) async -> String? {
        guard let data = try? PropertyListEncoder().encode(policy.validated()) else { return "encode failed" }
        return await call { proxy, done in proxy.apply(policy: data) { done($0) } } ?? "helper not reachable"
    }

    func status() async -> ChargeStatus? {
        let data: Data?? = await call { proxy, done in proxy.status { done($0) } }
        guard let d = data ?? nil else { return nil }
        return try? PropertyListDecoder().decode(ChargeStatus.self, from: d)
    }

    func restoreDefaults() async -> String? {
        await call { proxy, done in proxy.restoreDefaults { done($0) } } ?? "helper not reachable"
    }

    // MARK: Plumbing

    private func proxy(onError: @escaping @Sendable (any Error) -> Void) -> (any UltstatHelperProtocol)? {
        let c = connection ?? {
            let c = NSXPCConnection(machServiceName: ultstatHelperMachService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: UltstatHelperProtocol.self)
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.resume()
            connection = c
            return c
        }()
        return c.remoteObjectProxyWithErrorHandler(onError) as? any UltstatHelperProtocol
    }

    /// Bridges one XPC call to async/await; resumes exactly once even if both the reply and the
    /// error handler fire, and returns nil on any transport failure.
    private func call<T: Sendable>(_ body: (any UltstatHelperProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T? {
        guard state == .running else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = OnceFlag()
            guard let p = proxy(onError: { error in
                log.error("XPC error: \(error.localizedDescription, privacy: .public)")
                if once.claim() { cont.resume(returning: nil) }
            }) else {
                if once.claim() { cont.resume(returning: nil) }
                return
            }
            body(p) { value in if once.claim() { cont.resume(returning: value) } }
        }
    }
}

private final class OnceFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    func claim() -> Bool { !flag.exchange(true, ordering: .acquiringAndReleasing) }
}

import Synchronization

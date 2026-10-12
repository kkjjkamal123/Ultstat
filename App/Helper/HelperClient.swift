import CryptoKit
import Foundation
import os
import Security
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

    static let legacyPlist = InstallScript.plistPath

    /// True when installed through the administrator-password fallback (unsigned builds).
    var isLegacyInstalled: Bool { FileManager.default.fileExists(atPath: Self.legacyPlist) }

    var state: State {
        if isLegacyInstalled { return .running }
        return switch service.status {
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

    /// Team ID of this app's signature, or nil for ad-hoc builds.
    static var teamID: String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Runs the administrator-prompt install on a background thread so the prompt never blocks the UI.
    func installWithAdministratorPromptAsync() async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(InstallScript.label)").path
        guard FileManager.default.isExecutableFile(atPath: helper),
              let helperHash = Self.cdhash(of: URL(fileURLWithPath: helper)),
              let appHash = Self.cdhash(of: Bundle.main.bundleURL) else { throw HelperInstallError.missingHelper }
        // Signed with a certificate (tools/install-local.sh, or Developer ID): trust that certificate,
        // so later builds signed the same way keep working without another approval. Ad hoc: pin
        // this exact build.
        let requirement = Self.leafCertificateHash(of: Bundle.main.bundleURL)
            .map { "identifier \"io.github.kkjjkamal23.Ultstat\" and certificate leaf = H\"\($0)\"" }
            ?? "identifier \"io.github.kkjjkamal23.Ultstat\" and cdhash H\"\(appHash)\""
        let shell = InstallScript.installShell(sourceHelper: helper, expectedCDHash: helperHash,
                                               clientRequirement: requirement, plist: try InstallScript.launchdPlist())
        connection?.invalidate()
        connection = nil
        try await Task.detached(priority: .userInitiated) { try Self.runAsAdministrator(shell) }.value
    }

    /// SHA-1 of the leaf signing certificate, or nil for ad-hoc signed code.
    static func leafCertificateHash(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func cdhash(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let data = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Replaces the registered daemon with the one in this app bundle.
    func reregister() async throws {
        connection?.invalidate()
        connection = nil
        try await service.unregister()
        try service.register()
    }

    func uninstall() async throws {
        _ = await restoreDefaults()
        connection?.invalidate()
        connection = nil
        if isLegacyInstalled {
            let shell = InstallScript.uninstallShell
            try await Task.detached(priority: .userInitiated) { try Self.runAsAdministrator(shell) }.value
        } else {
            try await service.unregister()
        }
    }

    // MARK: Administrator prompt

    nonisolated private static func runAsAdministrator(_ shell: String) throws {
        let source = InstallScript.appleScript(shell: shell, prompt: "Ultstat needs to install its charge helper.")
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw HelperInstallError.scriptFailed("could not build script") }
        script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { throw HelperInstallError.cancelled }
            throw HelperInstallError.scriptFailed(error[NSAppleScript.errorMessage] as? String ?? "error \(code)")
        }
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
        guard let d = data.flatMap({ $0 }) else { return nil }
        return try? PropertyListDecoder().decode(ChargeStatus.self, from: d)
    }

    func componentPower() async -> ComponentPower? {
        let data: Data?? = await call { proxy, done in proxy.componentPower { done($0) } }
        guard let d = data.flatMap({ $0 }) else { return nil }
        return try? PropertyListDecoder().decode(ComponentPower.self, from: d)
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

enum HelperInstallError: LocalizedError {
    case missingHelper
    case cancelled
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHelper: "The helper is missing from the app bundle. Reinstall Ultstat."
        case .cancelled: "Installation was cancelled."
        case .scriptFailed(let why): "Installation failed: \(why)"
        }
    }
}

private final class OnceFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    func claim() -> Bool { !flag.exchange(true, ordering: .acquiringAndReleasing) }
}

import Synchronization

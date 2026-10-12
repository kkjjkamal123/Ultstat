import Foundation
import os
import Security
import UltstatCore

private let log = Logger(subsystem: "io.github.kkjjkamal23.Ultstat.Helper", category: "xpc")

final class HelperService: NSObject, NSXPCListenerDelegate, UltstatHelperProtocol, @unchecked Sendable {
    let controller = ChargeController()
    private let requirement: String?

    override init() {
        requirement = Self.clientRequirement()
        super.init()
        log.info("client requirement: \(self.requirement ?? "<none: refusing all clients>", privacy: .public)")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        // Enforced by the XPC runtime for every message, using the peer's audit token (no PID races).
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: UltstatHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(ultstatHelperVersion)
    }

    func apply(policy: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let p = try? PropertyListDecoder().decode(ChargePolicy.self, from: policy) else {
            reply("malformed policy")
            return
        }
        reply(controller.apply(p))
    }

    func status(reply: @escaping @Sendable (Data?) -> Void) {
        reply(try? PropertyListEncoder().encode(controller.status()))
    }

    /// Created on first request so an idle helper never subscribes to IOReport.
    private lazy var energy = EnergySampler(privileged: true)
    private let energyLock = NSLock()

    func componentPower(reply: @escaping @Sendable (Data?) -> Void) {
        energyLock.lock()
        let p = energy?.read()
        energyLock.unlock()
        reply(p.flatMap { try? PropertyListEncoder().encode($0) })
    }

    func restoreDefaults(reply: @escaping @Sendable (String?) -> Void) {
        reply(controller.restoreDefaults())
    }

    /// Who may talk to us:
    /// - Team-signed builds: the Ultstat app signed by the same team as this helper.
    /// - Ad-hoc builds: exactly the app bundle that contains this helper, pinned by cdhash.
    static func clientRequirement() -> String? {
        let appID = "io.github.kkjjkamal23.Ultstat"
        if let team = signingInfo(of: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))?.team {
            return "anchor apple generic and identifier \"\(appID)\" and certificate leaf[subject.OU] = \"\(team)\""
        }
        // Administrator-prompt installs run a root-owned copy and record the allowed app in a
        // root-owned file (see InstallScript). Only trust that file if root owns it and nobody else can write it.
        let reqPath = "/Library/Application Support/Ultstat/client-requirement"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: reqPath),
           (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
           let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue, perms & 0o022 == 0,
           let req = try? String(contentsOfFile: reqPath, encoding: .utf8), !req.isEmpty {
            return req.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // SMAppService installs: helper lives at Ultstat.app/Contents/MacOS/<helper>; the app is three levels up.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", let cdhash = signingInfo(of: app)?.cdhash else { return nil }
        return "identifier \"\(appID)\" and cdhash H\"\(cdhash)\""
    }

    static func signingInfo(of url: URL) -> (team: String?, cdhash: String?)? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let cdhash = (dict[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        return (team, cdhash)
    }
}

// Restore stock charging on termination (launchd sends SIGTERM on bootout, update and shutdown).
let service = HelperService()
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    log.info("SIGTERM: restoring stock charging")
    service.controller.shutdown()
    exit(0)
}
sigterm.resume()

service.controller.start()
let listener = NSXPCListener(machServiceName: ultstatHelperMachService)
listener.delegate = service
listener.resume()
dispatchMain()

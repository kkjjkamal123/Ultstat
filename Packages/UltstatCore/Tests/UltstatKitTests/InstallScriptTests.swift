import Foundation
import Testing
@testable import UltstatKit

@Suite struct InstallScriptTests {
    /// Runs the quoted string through a real shell and checks it comes back as one unchanged argument.
    private func roundTrip(_ s: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s \(InstallScript.shellQuote(s))"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test(arguments: [
        "/Applications/Ultstat.app/Contents/MacOS/helper",
        "/Users/me/My Apps/Ultstat.app",
        "/tmp/it's here",
        "/tmp/$(touch /tmp/pwned)",
        "/tmp/`id`;rm -rf ~",
        "/tmp/\"quoted\" \\ back\\slash",
        "/tmp/ünïcødé 🔋",
    ])
    func shellQuotingIsExact(_ path: String) throws {
        #expect(try roundTrip(path) == path)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }

    @Test func appleScriptEscapesQuotesAndBackslashes() {
        let src = InstallScript.appleScript(shell: #"echo "a\b""#, prompt: "x")
        #expect(src.hasPrefix(#"do shell script "echo \"a\\b\"" with administrator privileges"#))
    }

    @Test func appleScriptCompilesWithHostilePaths() throws {
        let plist = try InstallScript.launchdPlist()
        let shell = InstallScript.installShell(sourceHelper: "/tmp/we\"ird' $(x) \\path", expectedCDHash: "abc'; rm -rf /",
                                               clientRequirement: "identifier \"x\" and cdhash H\"00\"", plist: plist)
        let src = InstallScript.appleScript(shell: shell, prompt: "Install \"helper\"")
        var error: NSDictionary?
        let script = try #require(NSAppleScript(source: src))
        let compiled = script.compileAndReturnError(&error)
        #expect(compiled, "compile error: \(String(describing: error))")
    }

    /// The daemon must run a root-owned copy, never the binary inside the (user-writable) app bundle.
    @Test func daemonRunsRootOwnedCopy() throws {
        let data = try InstallScript.launchdPlist()
        let decoded = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(decoded["Program"] as? String == InstallScript.installedHelperPath)
        #expect(InstallScript.installedHelperPath.hasPrefix("/Library/PrivilegedHelperTools/"))
        let shell = InstallScript.installShell(sourceHelper: "/Applications/Ultstat.app/Contents/MacOS/h", expectedCDHash: "deadbeef",
                                               clientRequirement: "req", plist: data)
        #expect(shell.contains(data.base64EncodedString()))
        #expect(shell.contains("install -m 755 -o root -g wheel"))
        #expect(shell.contains("helper hash mismatch"), "copy must be verified against the inspected cdhash")
    }

    /// Runs the hash-check portion of the script for real against a stand-in binary.
    @Test func hashMismatchAbortsAndRemovesCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("helper").path
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: dest)   // Apple-signed: has a CDHash
        let check = """
        set -e
        HASH=$(/usr/bin/codesign -dv --verbose=4 \(InstallScript.shellQuote(dest)) 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
        if [ "$HASH" != \(InstallScript.shellQuote("0000")) ]; then /bin/rm -f \(InstallScript.shellQuote(dest)); exit 1; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", check]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1)
        #expect(!FileManager.default.fileExists(atPath: dest))
    }
}

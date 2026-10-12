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
        let plist = try InstallScript.launchdPlist(helperPath: "/tmp/we\"ird' $(x) \\path")
        let src = InstallScript.appleScript(shell: InstallScript.installShell(plist: plist), prompt: "Install \"helper\"")
        var error: NSDictionary?
        let script = try #require(NSAppleScript(source: src))
        let compiled = script.compileAndReturnError(&error)
        #expect(compiled, "compile error: \(String(describing: error))")
    }

    @Test func plistRoundTripsAndPointsIntoTheBundle() throws {
        let path = "/Applications/Ultstat.app/Contents/MacOS/\(InstallScript.label)"
        let data = try InstallScript.launchdPlist(helperPath: path)
        let decoded = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(decoded["Program"] as? String == path)
        #expect((decoded["MachServices"] as? [String: Bool])?[InstallScript.label] == true)
        #expect(InstallScript.installShell(plist: data).contains(data.base64EncodedString()))
    }
}

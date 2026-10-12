import Foundation

/// Builds the administrator-prompt install/uninstall commands for the helper (unsigned builds).
/// Pure functions so the quoting, which is security-sensitive, is unit-tested.
public enum InstallScript {
    public static let label = "io.github.kkjjkamal23.Ultstat.Helper"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    /// POSIX single-quote quoting: safe for any byte sequence except NUL.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Root-owned copy of the helper. The daemon must never run a binary the user can modify
    /// (the app bundle is user-writable), or any user-level process could gain root.
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/\(label)"
    /// Root-owned file holding the code requirement XPC clients must satisfy.
    public static let clientRequirementPath = "/Library/Application Support/Ultstat/client-requirement"

    public static func launchdPlist(helperPath: String = installedHelperPath) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "Program": helperPath,
            "MachServices": [label: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "ThrottleInterval": 10,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Copies the helper to a root-owned location, verifies the copy is byte-for-byte the build the
    /// app inspected (by cdhash), records which app may connect, and loads the daemon. The plist and
    /// requirement travel inside the authorised command, so no swappable temp file is involved.
    public static func installShell(sourceHelper: String, expectedCDHash: String, clientRequirement: String, plist: Data) -> String {
        let dest = shellQuote(installedHelperPath)
        let reqFile = shellQuote(clientRequirementPath)
        let reqDir = shellQuote((clientRequirementPath as NSString).deletingLastPathComponent)
        return """
        set -e
        /bin/mkdir -p /Library/PrivilegedHelperTools \(reqDir)
        /usr/bin/install -m 755 -o root -g wheel \(shellQuote(sourceHelper)) \(dest)
        HASH=$(/usr/bin/codesign -dv --verbose=4 \(dest) 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
        if [ "$HASH" != \(shellQuote(expectedCDHash)) ]; then /bin/rm -f \(dest); echo "helper hash mismatch" >&2; exit 1; fi
        echo \(Data(clientRequirement.utf8).base64EncodedString()) | /usr/bin/base64 -D > \(reqFile)
        /usr/sbin/chown root:wheel \(reqFile)
        /bin/chmod 644 \(reqFile)
        echo \(plist.base64EncodedString()) | /usr/bin/base64 -D > \(shellQuote(plistPath))
        /usr/sbin/chown root:wheel \(shellQuote(plistPath))
        /bin/chmod 644 \(shellQuote(plistPath))
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/launchctl bootstrap system \(shellQuote(plistPath))
        """
    }

    public static let uninstallShell = """
    /bin/launchctl bootout system/\(label) 2>/dev/null || true
    /bin/rm -f \(shellQuote(plistPath)) \(shellQuote(installedHelperPath)) \(shellQuote(clientRequirementPath))
    """

    /// Wraps a shell command in an AppleScript `do shell script … with administrator privileges`.
    public static func appleScript(shell: String, prompt: String) -> String {
        "do shell script \(appleScriptString(shell)) with administrator privileges with prompt \(appleScriptString(prompt))"
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

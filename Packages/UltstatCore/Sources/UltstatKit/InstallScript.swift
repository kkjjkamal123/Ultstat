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

    public static func launchdPlist(helperPath: String) throws -> Data {
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

    /// The plist travels inside the command as base64, so no temp file can be swapped.
    public static func installShell(plist: Data) -> String {
        """
        set -e
        echo \(plist.base64EncodedString()) | /usr/bin/base64 -D > \(shellQuote(plistPath))
        /usr/sbin/chown root:wheel \(shellQuote(plistPath))
        /bin/chmod 644 \(shellQuote(plistPath))
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/launchctl bootstrap system \(shellQuote(plistPath))
        """
    }

    public static let uninstallShell = """
    /bin/launchctl bootout system/\(label) 2>/dev/null || true
    /bin/rm -f \(shellQuote(plistPath))
    """

    /// Wraps a shell command in an AppleScript `do shell script … with administrator privileges`.
    public static func appleScript(shell: String, prompt: String) -> String {
        "do shell script \(appleScriptString(shell)) with administrator privileges with prompt \(appleScriptString(prompt))"
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

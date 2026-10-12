import Darwin
import SwiftUI
import UltstatKit

/// Colour dot, label, value.
struct LegendRow: View {
    var color: Color?
    var label: String
    var help: String?
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            if let color { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11) }
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            if let help { HelpBadge(help) }
            Spacer(minLength: 8)
            // One line always: long values shrink a little rather than wrap mid-number.
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .font(.system(size: 12.5))
    }
}

struct ProcessRow: Equatable {
    var pid: Int32
    var name: String
    var value: String
}

/// App icons for process rows, cached per pid (command-line tools get the executable icon).
@MainActor
enum ProcessIcons {
    private static var cache: [Int32: (NSImage, String?)] = [:]
    private static let generic: NSImage = NSWorkspace.shared.icon(for: .unixExecutable)

    private static func entry(_ pid: Int32) -> (NSImage, String?) {
        if let hit = cache[pid] { return hit }
        let app = NSRunningApplication(processIdentifier: pid)
        let e = (app?.icon ?? generic, app?.localizedName)
        if cache.count > 400 { cache.removeAll() }
        cache[pid] = e
        return e
    }

    static func icon(for pid: Int32) -> NSImage { entry(pid).0 }

    /// The app's display name ("Safari Web Content") when it has one, else the executable name.
    static func name(for pid: Int32, fallback: String) -> String { entry(pid).1 ?? fallback }
}

/// Force-quitting a process from a process list.
@MainActor
enum ProcessControl {
    /// Processes the session depends on (quitting them logs out or blanks the screen), and Ultstat itself.
    private static let protected: Set<String> = ["loginwindow", "WindowServer", "launchd", "kernel_task", "Ultstat"]

    /// True when the current user may quit `pid` and it isn't protected.
    static func canQuit(pid: Int32, name: String) -> Bool {
        guard pid > 1, pid != getpid(), !protected.contains(name) else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_uid == getuid()
    }

    /// Force quits: apps through AppKit (like the Force Quit window), other processes with SIGKILL.
    @discardableResult
    static func forceQuit(pid: Int32) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) { return app.forceTerminate() }
        return kill(pid, SIGKILL) == 0
    }
}

/// Top-processes table with app icons. Hovering a row you can quit shows an ×; clicking it force
/// quits the process. The hovered row is pinned in place (its value still updates) while the others
/// keep re-sorting, so the row never moves out from under the pointer.
struct ProcessTable: View {
    static let rowCount = 8
    var rows: [ProcessRow]
    var valueTitle: String

    private struct Pin: Equatable {
        var pid: Int32
        var index: Int
        var row: ProcessRow
    }

    @State private var pin: Pin?
    @State private var failed: Int32?

    /// Fresh rows, with the hovered process held at the position it had when the pointer arrived.
    private var displayed: [ProcessRow] {
        var list = Array(rows.prefix(Self.rowCount))
        guard let pin else { return list }
        let current = rows.first { $0.pid == pin.pid } ?? pin.row
        list.removeAll { $0.pid == pin.pid }
        list.insert(current, at: min(pin.index, list.count))
        return Array(list.prefix(Self.rowCount))
    }

    var body: some View {
        let shown = displayed
        VStack(spacing: 5) {
            HStack {
                Text("Process").foregroundStyle(.tertiary)
                Spacer()
                Text(valueTitle).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                let name = ProcessIcons.name(for: row.pid, fallback: row.name)
                HStack(spacing: 7) {
                    Image(nsImage: ProcessIcons.icon(for: row.pid)).resizable().frame(width: 16, height: 16)
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if failed == row.pid {
                        Text("Not allowed").font(.system(size: 10)).foregroundStyle(Theme.critical)
                    }
                    Text(row.value).monospacedDigit()
                    if pin?.pid == row.pid, ProcessControl.canQuit(pid: row.pid, name: row.name) {
                        Button("Force quit \(name)", systemImage: "xmark.circle.fill") {
                            if ProcessControl.forceQuit(pid: row.pid) {
                                failed = nil
                                pin = nil
                            } else {
                                failed = row.pid
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Force quit \(name)")
                    }
                }
                .font(.system(size: 12))
                .frame(minHeight: 18)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        if pin?.pid != row.pid { pin = Pin(pid: row.pid, index: index, row: row) }
                    } else if pin?.pid == row.pid {
                        pin = nil
                    }
                }
            }
            // Same height before the first measurement (processes need two samples): the panel is
            // sized once when it opens, so the table must not grow afterwards.
            ForEach(shown.count..<max(shown.count, Self.rowCount), id: \.self) { i in
                Text(i == 0 && shown.isEmpty ? "Measuring…" : " ")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            }
        }
    }
}

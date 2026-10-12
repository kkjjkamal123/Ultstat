import SwiftUI
import UltstatKit

/// Colour dot, label, value.
struct LegendRow: View {
    var color: Color?
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            if let color { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11) }
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            // One line always: long values shrink a little rather than wrap mid-number.
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .font(.system(size: 12.5))
    }
}

struct ProcessRow {
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

/// Top-processes table with app icons.
struct ProcessTable: View {
    static let rowCount = 8
    var rows: [ProcessRow]
    var valueTitle: String

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Process").foregroundStyle(.tertiary)
                Spacer()
                Text(valueTitle).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            ForEach(Array(rows.prefix(Self.rowCount).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    Image(nsImage: ProcessIcons.icon(for: row.pid)).resizable().frame(width: 16, height: 16)
                    Text(ProcessIcons.name(for: row.pid, fallback: row.name)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.value).monospacedDigit()
                }
                .font(.system(size: 12))
            }
            // Same height before the first measurement (processes need two samples): the panel is
            // sized once when it opens, so the table must not grow afterwards.
            ForEach(rows.count..<max(rows.count, Self.rowCount), id: \.self) { i in
                Text(i == 0 && rows.isEmpty ? "Measuring…" : " ")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            }
        }
    }
}

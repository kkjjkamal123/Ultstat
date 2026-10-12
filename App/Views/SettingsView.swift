import SwiftUI
import UltstatCore
import UltstatKit

/// Pages of the Ultstat window, grouped in the sidebar like AlDente's. Raw values are stable
/// (tests and debug drivers select pages by number).
enum SettingsSection: Int, CaseIterable, Identifiable, Hashable {
    case dashboard, chargeControl, alerts, cpu, gpu, memory, network, disk, sensors, power, menuBar, general, about

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .chargeControl: "Charge Control"
        case .alerts: "Alerts"
        case .menuBar: "Menu Bar"
        case .general: "General"
        case .about: "About"
        default: module.map { $0 == .temperature ? "Sensors" : $0.title } ?? ""
        }
    }

    /// The monitoring module a page shows, if it is one.
    var module: MenuBarItem? {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .disk: .disk
        case .sensors: .temperature
        case .power: .power
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .chargeControl: "battery.100percent.bolt"
        case .alerts: "bell.badge"
        case .menuBar: "menubar.rectangle"
        case .general: "gearshape"
        case .about: "info.circle"
        default: module?.symbol ?? "circle"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard: .blue
        case .chargeControl: .green
        case .alerts: .red
        case .menuBar: .indigo
        case .general: .gray
        case .about: .secondary
        default: module?.tint ?? .gray
        }
    }

    static let groups: [(String?, [SettingsSection])] = [
        (nil, [.dashboard]),
        ("Battery Care", [.chargeControl, .alerts]),
        ("Monitoring", [.cpu, .gpu, .memory, .network, .disk, .sensors, .power]),
        ("Appearance", [.menuBar]),
        ("App", [.general, .about]),
    ]
}

/// The Ultstat window: grouped sidebar on the left (AlDente style), the selected page on the right.
struct SettingsView: View {
    @State private var section: SettingsSection?

    init(initialTab: Int = 0) {
        _section = State(initialValue: SettingsSection(rawValue: initialTab) ?? .dashboard)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SettingsSection.groups, id: \.1) { title, items in
                    Section {
                        ForEach(items) { s in
                            Label {
                                Text(s.title)
                            } icon: {
                                Image(systemName: s.symbol).foregroundStyle(s.tint)
                            }
                            .tag(s)
                            .accessibilityIdentifier("settings.section.\(s.rawValue)")
                        }
                    } header: {
                        if let title { Text(title) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            page(section ?? .dashboard)
                .navigationTitle((section ?? .dashboard).title)
        }
        .frame(minWidth: 860, idealWidth: 1000, minHeight: 600, idealHeight: 700)
        .onAppear { SettingsTabDriver.select = { section = SettingsSection(rawValue: $0) } }
        .onDisappear { SettingsTabDriver.select = nil }
    }

    @ViewBuilder private func page(_ s: SettingsSection) -> some View {
        switch s {
        case .dashboard: SettingsDashboard()
        case .chargeControl: BatterySettings()
        case .alerts: AlertSettings()
        case .menuBar: MenuBarSettings()
        case .general: GeneralSettings()
        case .about: AboutSettings()
        default: s.module.map { WindowModulePage(item: $0) }
        }
    }

    private var sidebarFooter: some View {
        HStack {
            Button("Quit Ultstat", systemImage: "power") { NSApp.terminate(nil) }
                .help("Quit Ultstat")
                .accessibilityIdentifier("settings.quit")
            Spacer()
            Link(destination: URL(string: "https://github.com/kkjjkamal23/Ultstat")!) {
                Image(systemName: "questionmark")
            }
            .help("Help and source code")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(14)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })) { HelpLabel("Launch at login", help: Help.launchAtLogin) }
                .accessibilityIdentifier("settings.launchAtLogin")
            if let e = model.generalError {
                Text(e).font(.callout).foregroundStyle(Theme.critical)
            }
            Picker(selection: $settings.stored.interval) {
                ForEach(Array(Set([0.5, 0.6, 1.0, 2.0, 3.0, 5.0, settings.stored.interval])).sorted(), id: \.self) { v in
                    Text(v < 1 ? "\(Int((v * 1000).rounded())) ms" : (v == v.rounded() ? "\(Int(v)) s" : String(format: "%.1f s", v))).tag(v)
                }
            } label: { HelpLabel("Refresh every", help: Help.refresh) }
            .accessibilityIdentifier("settings.interval")
            Picker(selection: $settings.stored.temperatureUnit) {
                Text("Celsius").tag(TemperatureUnit.celsius)
                Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
            } label: { HelpLabel("Temperature", help: Help.temperatureUnit) }
            Toggle(isOn: $settings.stored.slowInLowPowerMode) { HelpLabel("Refresh every 2 s or slower in Low Power Mode", help: Help.slowInLowPower) }
                .accessibilityIdentifier("settings.slowInLowPower")
            Toggle(isOn: $settings.stored.bluetoothAccessories) { HelpLabel("Show AirPods and Bluetooth headphone batteries", help: Help.bluetooth) }
                .accessibilityIdentifier("settings.bluetooth")
            Section {
                Text("""
                    Faster refresh costs more power: about 1 ms of CPU per second at 2 s, roughly 3× that at 600 ms. \
                    Ultstat stops sampling entirely while the display is off and only reads metrics that are visible.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                HStack { Button("Reset All Settings…", role: .destructive) { confirmReset = true }; HelpBadge(Help.reset) }
                    .accessibilityIdentifier("settings.reset")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetAllSettings() }
                .accessibilityIdentifier("settings.reset.confirm")
        } message: {
            Text("Menu bar items, refresh rate, alerts and battery choices return to their defaults. Charge limiting is turned off.")
        }
    }
}

private struct MenuBarSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                MenuBarPreview()
            } header: {
                Text("Preview")
            }
            Section("Show in menu bar") {
                ForEach(MenuBarItem.allCases) { item in
                    HStack(spacing: 12) {
                        Label(item.title, systemImage: item.symbol)
                        HelpBadge(Help.menuItem)
                        Spacer()
                        if [.cpu, .gpu, .memory, .temperature, .power].contains(item) {
                            Picker("Style", selection: Binding(get: { model.settings.style(for: item) },
                                                               set: { model.settings.stored.styles[item] = $0 })) {
                                Text("Labeled").tag(WidgetStyle.labeled)
                                Text("Text").tag(WidgetStyle.text)
                                Text("Bar").tag(WidgetStyle.bar)
                                Text("Graph").tag(WidgetStyle.sparkline)
                            }
                            .labelsHidden()
                            .frame(width: 90)
                            .disabled(!model.settings.isEnabled(item))
                        }
                        Toggle(item.title, isOn: Binding(get: { model.settings.isEnabled(item) }, set: { _ in model.settings.toggle(item) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings.item.\(item.rawValue)")
                    }
                }
            }
            Section {
                Picker(selection: $settings.stored.itemLabel) {
                    Text("Name above value").tag(ItemLabel.name)
                    Text("Icon").tag(ItemLabel.icon)
                    Text("Nothing").tag(ItemLabel.none)
                } label: { HelpLabel("Before each value", help: Help.itemLabel) }
                .accessibilityIdentifier("settings.itemLabel")
                LabeledContent {
                    HStack {
                        Slider(value: $settings.stored.itemSpacing, in: AppSettings.Stored.itemSpacingRange, step: 1)
                            .frame(width: 180)
                            .accessibilityIdentifier("settings.spacing")
                        Text("\(Int(settings.stored.itemSpacing)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                } label: { HelpLabel("Spacing between items", help: Help.spacing) }
                .disabled(settings.stored.separateItems)
                Toggle(isOn: $settings.stored.separateItems) { HelpLabel("Use a separate menu bar item for each metric", help: Help.separateItems) }
                    .accessibilityIdentifier("settings.separate")
            } footer: {
                Text(settings.stored.separateItems
                     ? "Separate items can be rearranged individually, but macOS puts a wide fixed gap between them."
                     : "All metrics share one menu bar item, so the spacing is yours to set. Click a metric to open its panel.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BatterySettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmCalibration = false

    /// Two-way binding to one field of the charge policy; writes go through `updatePolicy`.
    private func policy<T>(_ keyPath: WritableKeyPath<ChargePolicy, T>) -> Binding<T> {
        Binding(get: { model.settings.stored.chargePolicy[keyPath: keyPath] },
                set: { v in model.updatePolicy { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        let policy = model.settings.stored.chargePolicy
        let unit = model.settings.stored.temperatureUnit
        Form {
            Section {
                helperRow
            }
            Section {
                Toggle(isOn: Binding(get: { model.settings.stored.chargeControlEnabled }, set: { model.setChargeControl($0) })) {
                    HelpLabel("Limit charging", help: Help.limit)
                }
                    .accessibilityIdentifier("settings.chargeControl")
                LabeledContent {
                    HStack {
                        Slider(value: Binding(get: { Double(policy.limit) }, set: { v in model.updatePolicy { $0.limit = Int(v) } }),
                               in: 20...100, step: 5)
                            .frame(width: 200)
                            .accessibilityIdentifier("settings.limitSlider")
                        Text("\(policy.limit)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                } label: { HelpLabel("Stop charging at", help: Help.limitLevel) }
                Stepper(value: self.policy(\.sailingRange), in: 0...20) { HelpLabel("Sailing range: \(policy.sailingRange)%", help: Help.sailing) }
                    .accessibilityIdentifier("settings.sailing")
                Toggle(isOn: self.policy(\.dischargeAboveLimit)) { HelpLabel("Discharge to the limit when above it", help: Help.discharge) }
                    .accessibilityIdentifier("settings.discharge")
                Toggle(isOn: Binding(get: { policy.heatProtection != nil },
                                     set: { v in model.updatePolicy { $0.heatProtection = v ? 40 : nil } })) { HelpLabel("Heat protection", help: Help.heat) }
                    .accessibilityIdentifier("settings.heat")
                if let h = policy.heatProtection {
                    Stepper("Pause charging above \(unit.format(Float(h)))\(unit == .celsius ? "C" : "F")",
                            value: Binding(get: { Int(h) }, set: { v in model.updatePolicy { $0.heatProtection = Double(v) } }), in: 30...50)
                }
                Toggle(isOn: self.policy(\.useHardwarePercent)) { HelpLabel("Use gauge charge instead of macOS percentage", help: Help.gaugePercent) }
                HStack {
                    Button(policy.topUp ? "Cancel Top Up" : "Top Up to 100% Once") { model.updatePolicy { $0.topUp.toggle() } }
                        .accessibilityIdentifier("settings.topUp")
                    Spacer()
                    Button(policy.calibration == nil ? "Calibrate Battery…" : "Stop Calibration") {
                        if policy.calibration == nil { confirmCalibration = true } else { model.toggleCalibration() }
                    }
                    .confirmationDialog("Start battery calibration?", isPresented: $confirmCalibration) {
                        Button("Start Calibration") { model.toggleCalibration() }
                    } message: {
                        Text(Help.calibrate)
                    }
                    .accessibilityIdentifier("settings.calibrate")
                    .help("Discharges to 15%, charges to 100%, holds for an hour, then returns to your limit. Takes several hours.")
                }
            } header: {
                Text("Charge limit")
            } footer: {
                if !model.helperReady {
                    Text("Your choices are saved and take effect once the helper is installed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker(selection: self.policy(\.magSafeLED)) {
                    Text("System").tag(0)
                    Text("Off").tag(1)
                    Text("Green").tag(3)
                    Text("Amber").tag(4)
                } label: { HelpLabel("LED", help: Help.magSafe) }
                .accessibilityIdentifier("settings.magsafe")
                .disabled(!model.settings.stored.chargeControlEnabled)
            } header: {
                Text("MagSafe LED")
            } footer: {
                Text(model.settings.stored.chargeControlEnabled
                     ? "Turning Limit charging off returns the LED to the system's behaviour."
                     : "Available while Limit charging is on. Normal charging uses the system's LED behaviour.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let e = model.helperError {
                Text(e).font(.callout).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshHelper() }
    }

    @ViewBuilder private var helperRow: some View {
        switch model.helperState {
        case .running where model.helperNeedsUpdate:
            LabeledContent {
                Button(model.installing ? "Updating…" : "Update Helper") { model.installHelper() }.disabled(model.installing)
            } label: { HelpLabel("Charge helper", help: Help.helper) }
            Text("This version of Ultstat needs to update its helper. You'll be asked for your password.")
                .font(.callout).foregroundStyle(.secondary)
        case .running:
            LabeledContent {
                HStack {
                    Label("Running · \(model.chargeStatus?.mechanism.label ?? "…")", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Uninstall") { model.uninstallHelper() }
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.uninstallHelper")
                    HelpBadge(Help.uninstallHelper)
                }
            } label: { HelpLabel("Charge helper", help: Help.helper) }
        case .needsApproval:
            LabeledContent {
                Button("Approve in System Settings") { model.installHelper() }
            } label: { HelpLabel("Charge helper", help: Help.helper) }
            Text("Allow “Ultstat” under System Settings › General › Login Items & Extensions.").font(.callout).foregroundStyle(.secondary)
        case .notInstalled:
            LabeledContent {
                Button("Install") { model.installHelper() }.accessibilityIdentifier("settings.installHelper")
            } label: { HelpLabel("Charge helper", help: Help.helper) }
            Text("""
                Charge limiting needs a small background helper with administrator rights. \
                It only accepts commands from this copy of Ultstat and restores normal charging when removed.
                """)
                .font(.callout).foregroundStyle(.secondary)
        case .unavailable(let why):
            LabeledContent { Text(why).foregroundStyle(.red) } label: { HelpLabel("Charge helper", help: Help.helper) }
        }
    }
}

private struct AlertSettings: View {
    @Environment(AppModel.self) private var model

    private func binding<T>(_ id: UUID, _ keyPath: WritableKeyPath<AlertRule, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { model.settings.stored.alerts.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { v in
                guard let i = model.settings.stored.alerts.firstIndex(where: { $0.id == id }) else { return }
                model.settings.stored.alerts[i][keyPath: keyPath] = v
            })
    }

    var body: some View {
        Form {
            Section {
                ForEach(model.settings.stored.alerts) { rule in
                    HStack(spacing: 10) {
                        Toggle(rule.metric.title, isOn: Binding(
                            get: { rule.enabled },
                            set: { on in
                                if on { model.requestNotificationPermission() }
                                binding(rule.id, \.enabled, fallback: false).wrappedValue = on
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Text(rule.metric.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Int(rule.threshold))\(rule.metric.unit)")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                        Stepper(rule.metric.title, value: binding(rule.id, \.threshold, fallback: rule.threshold),
                                in: range(rule.metric), step: step(rule.metric))
                            .labelsHidden()
                        Picker("For", selection: binding(rule.id, \.sustain, fallback: 0)) {
                            ForEach(sustainOptions(including: rule.sustain), id: \.self) { s in
                                Text(sustainLabel(s)).tag(s)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Button("Remove", systemImage: "minus.circle") {
                            model.settings.stored.alerts.removeAll { $0.id == rule.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text(Help.alerts)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Menu("Add Alert") {
                ForEach(AlertRule.Metric.allCases, id: \.self) { m in
                    Button(m.title) {
                        model.settings.stored.alerts.append(AlertRule(metric: m, threshold: defaultThreshold(m)))
                        model.requestNotificationPermission()
                    }
                }
            }
            .accessibilityIdentifier("settings.addAlert")
        }
        .formStyle(.grouped)
    }

    private func sustainOptions(including current: Double) -> [Double] {
        Array(Set([0, 10, 30, 60, 300, current])).sorted()
    }

    private func sustainLabel(_ s: Double) -> String {
        switch s {
        case 0: "at once"
        case ..<60: "\(Int(s)) s"
        default: "\(Int(s / 60)) min"
        }
    }

    private func range(_ m: AlertRule.Metric) -> ClosedRange<Double> {
        switch m {
        case .temperatureAbove: 50...110
        case .diskFreeBelowGB: 1...500
        default: 1...100
        }
    }

    private func step(_ m: AlertRule.Metric) -> Double { m == .temperatureAbove ? 1 : 5 }

    private func defaultThreshold(_ m: AlertRule.Metric) -> Double {
        switch m {
        case .cpuAbove, .memoryAbove: 90
        case .temperatureAbove: 95
        case .batteryBelow: 20
        case .batteryAtLeast: 80
        case .diskFreeBelowGB: 20
        }
    }
}

extension ChargeStatus.Mechanism {
    var label: String {
        switch self {
        case .nativeLimit: "macOS charge limit"
        case .smcTahoe: "SMC (macOS 26 firmware)"
        case .smcLegacy: "SMC (legacy firmware)"
        case .unsupported: "Unsupported Mac"
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Ultstat").font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                .foregroundStyle(.secondary)
            Text("System monitor and battery charge limiter for Apple Silicon.\nOpen source under the Apache License 2.0.")
                .multilineTextAlignment(.center).font(.callout)
            Link("github.com/kkjjkamal23/Ultstat", destination: URL(string: "https://github.com/kkjjkamal23/Ultstat")!)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Live preview of the menu bar that is also the place to arrange it: drag a reading left or right
/// and the others make room; the real menu bar follows as soon as you drop.
private struct MenuBarPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var dragging: MenuBarItem?

    var body: some View {
        let s = model.settings.stored
        let tint = (scheme == .dark ? NSColor.white : NSColor.black).cgColor
        // Separate items: macOS's own gap (about 16 pt on this bar). Single item: the chosen spacing.
        let spacing: CGFloat = s.separateItems ? 16 : CGFloat(s.itemSpacing)
        VStack(spacing: 6) {
            // Each reading has 3 pt of grab area per side, taken out of the gap so spacing stays true.
            HStack(spacing: max(0, spacing - 6)) {
                if s.items.isEmpty {
                    Text("No readings shown. Turn some on below.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(s.items) { item in
                    if let (img, size) = StatusItemController.image(metric: item, segments: StatusItemController.segments(metric: item, model: model),
                                                                    tint: tint, scale: 2) {
                        Image(decorative: img, scale: 2)
                            .frame(width: size.width, height: size.height)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 2)
                            .background(dragging == item ? Color.accentColor.opacity(0.25) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .opacity(dragging == item ? 0.6 : 1)
                            .contentShape(Rectangle())
                            .onDrag {
                                dragging = item
                                return NSItemProvider(object: item.rawValue as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDrop(target: item, dragging: $dragging, settings: model.settings))
                            .help("Drag to move \(item.title)")
                            .accessibilityLabel(item.title)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.vertical, 8)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onDrop(of: [.text], delegate: EndDrag(dragging: $dragging))
            // A drag dropped outside the preview never reports back; clear it once the button is up.
            .onContinuousHover { _ in if dragging != nil, NSEvent.pressedMouseButtons == 0 { dragging = nil } }
            Text("Drag readings to rearrange them.").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar preview")
    }
}

/// Moves the dragged reading into the hovered one's place as soon as the pointer enters it.
private struct ReorderDrop: DropDelegate {
    let target: MenuBarItem
    @Binding var dragging: MenuBarItem?
    let settings: AppSettings

    @MainActor func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target, let from = settings.stored.items.firstIndex(of: d),
              let to = settings.stored.items.firstIndex(of: target) else { return }
        withAnimation(.smooth(duration: 0.25)) {
            settings.stored.items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    @MainActor func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Clears the drag state when a drop lands on the preview background.
private struct EndDrag: DropDelegate {
    @Binding var dragging: MenuBarItem?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    @MainActor func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

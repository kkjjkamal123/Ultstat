import SwiftUI
import UltstatCore
import UltstatKit

enum SettingsSection: Int, CaseIterable, Identifiable, Hashable {
    case general, menuBar, battery, alerts, about

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .battery: "Battery"
        case .alerts: "Alerts"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .menuBar: "menubar.rectangle"
        case .battery: "battery.75percent"
        case .alerts: "bell.badge.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .menuBar: .blue
        case .battery: .green
        case .alerts: .red
        case .about: .indigo
        }
    }
}

/// System Settings-style window: icon sidebar on the left, the selected page on the right.
struct SettingsView: View {
    @State private var section: SettingsSection?

    init(initialTab: Int = 0) {
        _section = State(initialValue: SettingsSection(rawValue: initialTab) ?? .general)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { s in
                HStack(spacing: 9) {
                    Image(systemName: s.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(s.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(s.title)
                }
                .tag(s)
                .accessibilityIdentifier("settings.section.\(s.rawValue)")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch section ?? .general {
                case .general: GeneralSettings()
                case .menuBar: MenuBarSettings()
                case .battery: BatterySettings()
                case .alerts: AlertSettings()
                case .about: AboutSettings()
                }
            }
            .navigationTitle((section ?? .general).title)
        }
        .frame(minWidth: 700, idealWidth: 720, minHeight: 500, idealHeight: 540)
        .onAppear { SettingsTabDriver.select = { section = SettingsSection(rawValue: $0) } }
        .onDisappear { SettingsTabDriver.select = nil }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                .accessibilityIdentifier("settings.launchAtLogin")
            if let e = model.generalError {
                Text(e).font(.callout).foregroundStyle(Theme.critical)
            }
            Picker("Refresh every", selection: $settings.stored.interval) {
                ForEach(Array(Set([0.5, 0.6, 1.0, 2.0, 3.0, 5.0, settings.stored.interval])).sorted(), id: \.self) { v in
                    Text(v < 1 ? "\(Int((v * 1000).rounded())) ms" : (v == v.rounded() ? "\(Int(v)) s" : String(format: "%.1f s", v))).tag(v)
                }
            }
            .accessibilityIdentifier("settings.interval")
            Picker("Temperature", selection: $settings.stored.temperatureUnit) {
                Text("Celsius").tag(TemperatureUnit.celsius)
                Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
            }
            Toggle("Refresh every 2 s or slower in Low Power Mode", isOn: $settings.stored.slowInLowPowerMode)
                .accessibilityIdentifier("settings.slowInLowPower")
            Toggle("Show AirPods and Bluetooth headphone batteries", isOn: $settings.stored.bluetoothAccessories)
                .accessibilityIdentifier("settings.bluetooth")
            Section {
                Text("""
                    Faster refresh costs more power: about 1 ms of CPU per second at 2 s, roughly 3× that at 600 ms. \
                    Ultstat stops sampling entirely while the display is off and only reads metrics that are visible.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
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
                Picker("Before each value", selection: $settings.stored.itemLabel) {
                    Text("Name above value").tag(ItemLabel.name)
                    Text("Icon").tag(ItemLabel.icon)
                    Text("Nothing").tag(ItemLabel.none)
                }
                .accessibilityIdentifier("settings.itemLabel")
                LabeledContent("Spacing between items") {
                    HStack {
                        Slider(value: $settings.stored.itemSpacing, in: AppSettings.Stored.itemSpacingRange, step: 1)
                            .frame(width: 180)
                            .accessibilityIdentifier("settings.spacing")
                        Text("\(Int(settings.stored.itemSpacing)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(settings.stored.separateItems)
                Toggle("Use a separate menu bar item for each metric", isOn: $settings.stored.separateItems)
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
                Toggle("Limit charging", isOn: Binding(get: { model.settings.stored.chargeControlEnabled }, set: { model.setChargeControl($0) }))
                    .accessibilityIdentifier("settings.chargeControl")
                LabeledContent("Stop charging at") {
                    HStack {
                        Slider(value: Binding(get: { Double(policy.limit) }, set: { v in model.updatePolicy { $0.limit = Int(v) } }),
                               in: 20...100, step: 5)
                            .frame(width: 200)
                            .accessibilityIdentifier("settings.limitSlider")
                        Text("\(policy.limit)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Stepper("Sailing range: \(policy.sailingRange)%", value: self.policy(\.sailingRange), in: 0...20)
                    .accessibilityIdentifier("settings.sailing")
                Toggle("Discharge to the limit when above it", isOn: self.policy(\.dischargeAboveLimit))
                    .accessibilityIdentifier("settings.discharge")
                Toggle("Heat protection", isOn: Binding(get: { policy.heatProtection != nil },
                                                        set: { v in model.updatePolicy { $0.heatProtection = v ? 40 : nil } }))
                    .accessibilityIdentifier("settings.heat")
                if let h = policy.heatProtection {
                    Stepper("Pause charging above \(unit.format(Float(h)))\(unit == .celsius ? "C" : "F")",
                            value: Binding(get: { Int(h) }, set: { v in model.updatePolicy { $0.heatProtection = Double(v) } }), in: 30...50)
                }
                Toggle("Use gauge charge instead of macOS percentage", isOn: self.policy(\.useHardwarePercent))
                HStack {
                    Button(policy.topUp ? "Cancel Top Up" : "Top Up to 100% Once") { model.updatePolicy { $0.topUp.toggle() } }
                        .accessibilityIdentifier("settings.topUp")
                    Spacer()
                    Button(policy.calibration == nil ? "Calibrate Battery…" : "Stop Calibration") {
                        model.updatePolicy { $0.calibration = $0.calibration == nil ? .discharging : nil }
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
                Picker("LED", selection: self.policy(\.magSafeLED)) {
                    Text("System").tag(0)
                    Text("Off").tag(1)
                    Text("Green").tag(3)
                    Text("Amber").tag(4)
                }
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
            LabeledContent("Charge helper") {
                Button(model.installing ? "Updating…" : "Update Helper") { model.installHelper() }.disabled(model.installing)
            }
            Text("This version of Ultstat needs to update its helper. You'll be asked for your password.")
                .font(.callout).foregroundStyle(.secondary)
        case .running:
            LabeledContent("Charge helper") {
                HStack {
                    Label("Running · \(model.chargeStatus?.mechanism.label ?? "…")", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Uninstall") { model.uninstallHelper() }
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.uninstallHelper")
                }
            }
        case .needsApproval:
            LabeledContent("Charge helper") {
                Button("Approve in System Settings") { model.installHelper() }
            }
            Text("Allow “Ultstat” under System Settings › General › Login Items & Extensions.").font(.callout).foregroundStyle(.secondary)
        case .notInstalled:
            LabeledContent("Charge helper") {
                Button("Install") { model.installHelper() }.accessibilityIdentifier("settings.installHelper")
            }
            Text("""
                Charge limiting needs a small background helper with administrator rights. \
                It only accepts commands from this copy of Ultstat and restores normal charging when removed.
                """)
                .font(.callout).foregroundStyle(.secondary)
        case .unavailable(let why):
            LabeledContent("Charge helper") { Text(why).foregroundStyle(.red) }
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
                Text("Alerts notify once, then re-arm after the value has clearly recovered.")
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

/// Live preview of the menu-bar items as currently configured.
private struct MenuBarPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = model.settings.stored
        let metrics: [MenuBarItem?] = s.items.isEmpty ? [nil] : s.items.map(Optional.some)
        let tint = (scheme == .dark ? NSColor.white : NSColor.black).cgColor
        let parts = metrics.compactMap { m in
            StatusItemController.image(metric: m, segments: StatusItemController.segments(metric: m, model: model), tint: tint, scale: 2)
        }
        // Separate items: macOS's own gap (about 16 pt on this bar). Single item: the chosen spacing.
        let spacing: CGFloat = s.separateItems ? 16 : CGFloat(s.itemSpacing)
        HStack {
            Spacer()
            if let (img, size, _) = StatusItemController.compose(parts, spacing: spacing, scale: 2) {
                Image(decorative: img, scale: 2).frame(width: size.width, height: size.height)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Menu bar preview")
    }
}

import SwiftUI
import UltstatCore
import UltstatKit

struct SettingsView: View {
    @State private var tab: Int

    init(initialTab: Int = 0) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: 0) { GeneralSettings() }
            Tab("Menu Bar", systemImage: "menubar.rectangle", value: 1) { MenuBarSettings() }
            Tab("Battery", systemImage: "battery.75percent", value: 2) { BatterySettings() }
            Tab("Alerts", systemImage: "bell.badge", value: 3) { AlertSettings() }
            Tab("About", systemImage: "info.circle", value: 4) { AboutSettings() }
        }
        .frame(width: 520, height: 460)
        .onAppear { SettingsTabDriver.select = { tab = $0 } }
        .onDisappear { SettingsTabDriver.select = nil }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                .accessibilityIdentifier("settings.launchAtLogin")
            Picker("Update every", selection: $settings.stored.interval) {
                ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) s").tag($0) }
            }
            .accessibilityIdentifier("settings.interval")
            Picker("Temperature", selection: $settings.stored.temperatureUnit) {
                Text("Celsius").tag(TemperatureUnit.celsius)
                Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
            }
            Toggle("Show AirPods and Bluetooth headphone batteries", isOn: $settings.stored.bluetoothAccessories)
                .accessibilityIdentifier("settings.bluetooth")
            Section {
                Text("Longer intervals use less power. Ultstat stops sampling entirely while the display is off and only reads metrics that are visible.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset All Settings", role: .destructive) { model.settings.resetToDefaults() }
                    .accessibilityIdentifier("settings.reset")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MenuBarSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Show in menu bar") {
                ForEach(MenuBarItem.allCases) { item in
                    HStack(spacing: 12) {
                        Label(item.title, systemImage: item.symbol)
                        Spacer()
                        if [.cpu, .gpu, .memory].contains(item) {
                            Picker("Style", selection: Binding(get: { model.settings.style(for: item) },
                                                               set: { model.settings.stored.styles[item] = $0 })) {
                                Text("Text").tag(WidgetStyle.text)
                                Text("Bar").tag(WidgetStyle.bar)
                            }
                            .labelsHidden()
                            .frame(width: 80)
                            .disabled(!model.settings.isEnabled(item))
                        }
                        Toggle(item.title, isOn: Binding(get: { model.settings.isEnabled(item) }, set: { _ in model.settings.toggle(item) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings.item.\(item.rawValue)")
                    }
                }
            }
            Toggle("Show icons", isOn: $settings.stored.showIcons)
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
        Form {
            Section {
                helperRow
            }
            Section("Charge limit") {
                Toggle("Limit charging", isOn: Binding(get: { model.settings.stored.chargeControlEnabled }, set: { model.setChargeControl($0) }))
                    .disabled(model.helperState != .running)
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
                Toggle("Discharge to the limit when above it", isOn: self.policy(\.dischargeAboveLimit))
                Toggle("Heat protection", isOn: Binding(get: { policy.heatProtection != nil },
                                                        set: { v in model.updatePolicy { $0.heatProtection = v ? 40 : nil } }))
                if let h = policy.heatProtection {
                    Stepper("Pause charging above \(Int(h))°C",
                            value: Binding(get: { Int(h) }, set: { v in model.updatePolicy { $0.heatProtection = Double(v) } }), in: 30...50)
                }
                Toggle("Use gauge charge instead of macOS percentage", isOn: self.policy(\.useHardwarePercent))
                HStack {
                    Button("Top Up to 100% Once") { model.updatePolicy { $0.topUp = true } }
                        .disabled(!model.settings.stored.chargeControlEnabled || policy.topUp)
                    Spacer()
                    if policy.calibration == nil {
                        Button("Calibrate Battery…") { model.updatePolicy { $0.calibration = .discharging } }
                            .disabled(!model.settings.stored.chargeControlEnabled)
                            .help("Discharges to 15%, charges to 100%, holds for an hour, then returns to your limit. Takes several hours.")
                    } else {
                        Button("Stop Calibration") { model.updatePolicy { $0.calibration = nil } }
                    }
                }
            }
            .disabled(model.helperState != .running)
            Section("MagSafe LED") {
                Picker("LED", selection: self.policy(\.magSafeLED)) {
                    Text("System").tag(0)
                    Text("Off").tag(1)
                    Text("Green").tag(3)
                    Text("Amber").tag(4)
                }
            }
            .disabled(model.helperState != .running)
            if let e = model.helperError {
                Text(e).font(.callout).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshHelper() }
    }

    @ViewBuilder private var helperRow: some View {
        switch model.helperState {
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

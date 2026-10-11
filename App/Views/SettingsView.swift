import SwiftUI
import UltstatCore

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Menu Bar", systemImage: "menubar.rectangle") { MenuBarSettings() }
            Tab("Battery", systemImage: "battery.75percent") { BatterySettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 520, height: 460)
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
                    HStack {
                        Toggle(isOn: Binding(get: { model.settings.isEnabled(item) }, set: { _ in model.settings.toggle(item) })) {
                            Label(item.title, systemImage: item.symbol)
                        }
                        .accessibilityIdentifier("settings.item.\(item.rawValue)")
                        if [.cpu, .gpu, .memory].contains(item) {
                            Spacer()
                            Picker("", selection: Binding(get: { model.settings.style(for: item) },
                                                          set: { model.settings.stored.styles[item] = $0 })) {
                                Text("Text").tag(WidgetStyle.text)
                                Text("Bar").tag(WidgetStyle.bar)
                            }
                            .labelsHidden()
                            .frame(width: 90)
                            .disabled(!model.settings.isEnabled(item))
                        }
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
                Stepper("Sailing range: \(policy.sailingRange)%", value: Binding(get: { policy.sailingRange }, set: { v in model.updatePolicy { $0.sailingRange = v } }), in: 0...20)
                Toggle("Discharge to the limit when above it", isOn: Binding(get: { policy.dischargeAboveLimit }, set: { v in model.updatePolicy { $0.dischargeAboveLimit = v } }))
                Toggle("Heat protection", isOn: Binding(get: { policy.heatProtection != nil }, set: { v in model.updatePolicy { $0.heatProtection = v ? 40 : nil } }))
                if let h = policy.heatProtection {
                    Stepper("Pause charging above \(Int(h))°C", value: Binding(get: { Int(h) }, set: { v in model.updatePolicy { $0.heatProtection = Double(v) } }), in: 30...50)
                }
                Toggle("Use gauge charge instead of macOS percentage", isOn: Binding(get: { policy.useHardwarePercent }, set: { v in model.updatePolicy { $0.useHardwarePercent = v } }))
                Button("Top Up to 100% Once") { model.updatePolicy { $0.topUp = true } }
                    .disabled(!model.settings.stored.chargeControlEnabled || policy.topUp)
            }
            .disabled(model.helperState != .running)
            Section("MagSafe LED") {
                Picker("LED", selection: Binding(get: { policy.magSafeLED }, set: { v in model.updatePolicy { $0.magSafeLED = v } })) {
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
                Label("Running · \(model.chargeStatus?.mechanism.label ?? "…")", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
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
            Text("Charge limiting needs a small background helper with administrator rights. It only accepts commands from this copy of Ultstat and restores normal charging when removed.")
                .font(.callout).foregroundStyle(.secondary)
        case .unavailable(let why):
            LabeledContent("Charge helper") { Text(why).foregroundStyle(.red) }
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

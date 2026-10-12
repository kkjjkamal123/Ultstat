import SwiftUI

/// Small "?" next to a control or reading. Hovering (or clicking) shows what it means and whether
/// it is safe to change.
struct HelpBadge: View {
    var text: String
    @State private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .contentShape(Circle())
            .onHover { shown = $0 }
            .onTapGesture { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 270, alignment: .leading)
                    .padding(12)
            }
            .accessibilityElement()
            .accessibilityLabel("Help")
            .accessibilityValue(text)
            .accessibilityAddTraits(.isButton)
    }
}

/// A label followed by its help badge, for toggles, pickers and rows.
struct HelpLabel: View {
    var title: String
    var help: String

    init(_ title: String, help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            HelpBadge(help)
        }
    }
}

/// Every explanation in one place, so the panel, dashboard and Settings say the same thing.
enum Help {
    // MARK: Charge control

    static let limit = """
        Stops charging at the level you choose and holds the battery there while plugged in. \
        Lithium-ion batteries wear faster when kept full, so this extends battery life. \
        Safe: turning it off returns to normal charging immediately.
        """
    static let limitLevel = """
        The level charging stops at. 80 % is a good choice for a Mac that is mostly plugged in. \
        Lower wears the battery less but leaves less runtime when you unplug. Safe to change any time.
        """
    static let sailing = """
        Lets the level drift this many percent below the limit before charging starts again, \
        instead of topping up in tiny bursts. Fewer micro-charges are gentler on the battery. Safe.
        """
    static let topUp = """
        Charges to 100 % once (for example before a trip), then goes back to your limit by itself. \
        Safe: an occasional full charge does no harm.
        """
    static let discharge = """
        If the battery is above your limit while plugged in, the Mac runs from the battery until it \
        reaches the limit (the adapter is bypassed, it stays connected). Safe and reversible: the \
        adapter is switched back on automatically, also when Ultstat quits or the Mac sleeps.
        """
    static let calibrate = """
        Recalibrates the battery percentage: discharges to 15 % while plugged in, charges to 100 %, \
        holds for an hour, then returns to your limit. Takes many hours; keep the Mac plugged in. \
        Safe, but only worth doing every few months or when the percentage seems wrong. Click again to stop.
        """
    static let heat = """
        Pauses charging while the battery is warmer than this. Heat is the main cause of battery \
        wear, so this is recommended. Safe.
        """
    static let gaugePercent = """
        Uses the battery controller's own, unrounded charge reading instead of the macOS percentage. \
        The limit then stops at a slightly different displayed percentage. Safe.
        """
    static let magSafe = """
        Sets the light on the MagSafe connector. Cosmetic only. Safe.
        """
    static let helper = """
        Charge control needs a small background helper with administrator rights to talk to the \
        battery controller. It only accepts commands from this copy of Ultstat and restores normal \
        charging when removed. You'll be asked for your password once.
        """
    static let uninstallHelper = """
        Removes the helper and restores normal charging and macOS's own charge settings. Monitoring \
        keeps working. Safe.
        """
    static let otherController = """
        Another battery app (AlDente) is installed. Two apps controlling charging at once can undo \
        each other's changes. Use one of them for charge control: quit AlDente, or turn Limit off here.
        """

    // MARK: General

    static let launchAtLogin = "Starts Ultstat automatically when you log in. Safe."
    static let refresh = """
        How often readings update. Faster is smoother but uses more power (600 ms costs about 3× \
        as much as 2 s). 1–2 s is a good balance. Safe.
        """
    static let temperatureUnit = "Shows temperatures in Celsius or Fahrenheit. Safe."
    static let slowInLowPower = """
        While macOS Low Power Mode is on, readings update no faster than every 2 s to save battery. Safe.
        """
    static let bluetooth = """
        Shows battery levels of AirPods and other Bluetooth headphones. macOS asks for Bluetooth \
        permission the first time. Safe.
        """
    static let reset = """
        Returns every setting to its default and turns charge limiting off. This can't be undone.
        """

    // MARK: Menu bar

    static let menuItem = "Shows or hides this reading in the menu bar. Safe."
    static let widgetStyle = """
        How the reading looks in the menu bar: name above value, plain text, a bar, or a small graph. Safe.
        """
    static let itemLabel = """
        What appears with each value: its name above it (like Stats), an icon, or nothing. Safe.
        """
    static let spacing = "Gap between readings in the menu bar, in points. Safe."
    static let separateItems = """
        Gives every reading its own menu bar item, so a menu bar manager can arrange them separately. \
        macOS then puts a wide fixed gap between them. Safe.
        """

    // MARK: Alerts

    static let alerts = """
        Sends a notification when a reading stays past its threshold for the chosen time, once per \
        episode. Safe.
        """

    // MARK: Readings

    static let cpuUsage = "Share of all CPU cores busy. System is macOS itself, User is your apps."
    static let cores = """
        Load of each core. Performance (Super) cores run demanding work; efficiency cores handle \
        light and background work at lower power.
        """
    static let loadAverage = """
        Average number of tasks waiting to run over 1, 5 and 15 minutes. Below the number of cores means \
        the CPU keeps up easily.
        """
    static let gpuUsage = "How busy the graphics processor is. Renderer draws pixels, Tiler prepares geometry."
    static let memoryPressure = """
        How hard macOS is working to find free memory. Normal is fine even when usage looks high; \
        High or Critical means apps are being slowed by compression and swapping.
        """
    static let memoryBreakdown = """
        App: memory your apps use. Wired: locked by macOS, can't be freed. Compressed: squeezed to \
        save space. Cached files can be reclaimed instantly. Swap is memory written to disk.
        """
    static let temperatures = """
        Hottest sensor in each part of the chip and system. Apple Silicon runs comfortably up to \
        about 95 °C under load.
        """
    static let systemPower = "Power the whole Mac draws right now, measured by the system controller."
    static let componentPower = """
        Power of each part of the chip. CPU, Neural Engine and memory need the helper (macOS only \
        shows them to administrators).
        """
    static let powerFlow = """
        Where power goes: from the adapter into the Mac, and into or out of the battery.
        """
    static let batteryHealth = """
        Maximum capacity compared to when new. Cycle count is how many full discharges the battery \
        has had; Apple rates Mac batteries for 1000 cycles.
        """
    static let batteryLevelChart = """
        Battery level over the last 12 hours, one point a minute. The dashed line is your charge limit.
        """
    static let timeRemaining = """
        On battery: how long until empty (macOS's estimate). Charging: how long until full. Plugged in \
        and held at a limit, the battery isn't being used, so its state is shown instead of a time.
        """
    static let processes = """
        Apps using the most of this resource right now. Power is the energy macOS measured for each app.
        """
}

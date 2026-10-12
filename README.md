<p align="center"><img src="docs/assets/icon.png" width="128" alt="Ultstat icon"></p>

<h1 align="center">Ultstat</h1>

<p align="center">A system monitor and battery charge limiter for Apple Silicon Macs, built to cost almost nothing while it runs.</p>

---

Ultstat combines a menu-bar system monitor (CPU, GPU, memory, disk, network, temperatures, power, fans, processes) with full battery care: charge limit, sailing, discharge, heat protection, top-up and calibration. It's designed for the case where it runs all day in the background, so its own power draw is the first feature.

## Measured cost

MacBook Air M5, macOS 27.0.1. Default menu bar (CPU, memory, temperature, battery), popover closed, 30 s of `powermetrics --samplers tasks`:

| | CPU time | Wake-ups | Energy impact | Memory |
|---|---|---|---|---|
| **Ultstat** | **0.85 ms/s** | **0.56 /s** | **0.08** | **15 MB** |
| Stats 3.0.20 | 56.8 ms/s | 9.0 /s | 7.09 | 151 MB |
| AlDente 1.39.4 | 9.6 ms/s | 2.9 /s | 1.27 | 80 MB |

How it gets there:

- **One timer for everything**, aligned and coalescable, cancelled entirely when nothing is visible or the display sleeps.
- **Demand-driven sampling.** A metric is read only while a menu-bar item or open view shows it.
- **No child processes.** Processes come from `libproc`, not `ps`/`top`; network from per-interface `IFMIB` sysctls (3 µs, versus 578 µs for the naive approach).
- **SMC, not IOHID, for temperatures**: about 200 µs per sensor and only 16 µs of CPU, versus about 760 µs. Sensors are read in a rotating window.
- **Event-driven battery.** IOKit notifications, no polling.
- **Menu bar drawn into a `CALayer`.** No AppKit re-rasterisation; the item width is fixed so it never relayouts.
- **SwiftUI exists only while a window is open.**

Every number above, and the method behind it, is in [`PROGRESS.md`](PROGRESS.md).

## Features

**Monitor:** total and per-core CPU (performance/efficiency split), GPU utilisation and power, memory (app/wired/compressed, swap, pressure), disk throughput and capacity, network throughput, temperatures grouped by component, system power, fans, top processes by CPU, memory or measured energy, Bluetooth accessory batteries, thermal state and Low Power Mode.

**Battery:** the macOS percentage alongside the fuel gauge's real charge, health and cycle count, live power flow (adapter → Mac ← battery).

**Charge control** (needs the privileged helper):
- charge limit (20–100 %) with sailing range
- discharge to the limit while plugged in
- heat protection with hysteresis
- one-shot top-up to 100 %
- calibration cycle
- MagSafe LED control

The limit holds while the app is quit, through sleep and across reboots.

## How charge control works

Apple has changed the mechanism several times. Ultstat detects which one your Mac has by probing the SMC rather than checking the OS version:

| Firmware | Mechanism |
|---|---|
| Legacy Apple Silicon | SMC `CH0B`/`CH0C` (inhibit), `CH0I` (adapter) |
| macOS 26 firmware | SMC `CHTE` (inhibit), `CHIE` (adapter) |
| macOS 27 (M5 tested) | macOS's own charge limiter driven through its preferences, plus `CHIE` |

Details, byte layouts and open questions are in [`docs/charging-control.md`](docs/charging-control.md).

### Safety

- The helper accepts XPC connections only from Ultstat, verified by code signature (team ID, or the exact cdhash of the containing app for unsigned builds).
- Its interface is a few range-checked commands. Unlike AlDente's helper, it has no "write any SMC key" or "write any preference" call.
- It restores normal charging on exit and uninstall. It never leaves the adapter disabled while unplugged, a property tested exhaustively across about 50,000 input combinations.

## Requirements

- Apple Silicon Mac
- macOS 26 or later

## Build

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Ultstat.xcodeproj -scheme Ultstat -configuration Release build
```

Tests:

```sh
cd Packages/UltstatCore && swift test
```

The tests use real hardware where they can; the charge controller is tested against a fake SMC.

Useful tools:
- `swift run -c release ultstat-smc list` — every SMC key on this Mac, decoded
- `swift run -c release ultstat-bench` — micro-benchmarks of each sampler
- `tools/stress-popover.sh 60` — opens and closes the popover 60 times, then reports memory and leaks
- Launch with `-UltstatSnapshotDir /tmp/shots` to render the menu bar, dashboard and settings to PNG

## Project layout

```
App/                      AppKit shell, SwiftUI popover and settings
Helper/                   privileged LaunchDaemon (charge control)
Shared/                   XPC protocol
Packages/UltstatCore/
  Sources/CSMC            allocation-free AppleSMC client (C)
  Sources/CPrivate        IOHID/IOReport declarations and shim
  Sources/UltstatCore     samplers, scheduler, charge state machine and actuators
  Sources/UltstatKit      app logic: readings bus, settings, menu-bar renderer
docs/                     charge-control notes, assets
tools/                    icon renderer, stress script
```

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

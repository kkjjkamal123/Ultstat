# Ultstat — build log & plan

Single source of truth for picking work back up across sessions. Update after every iteration.

## Goal
Open-source macOS menu-bar app: everything Stats + AlDente Pro do, and more. Hard targets:
- Idle draw contribution < 2 W total system impact; app itself ~0 % CPU at idle, near-zero wakeups
- No leaks, no hangs, every click path covered by tests, smooth 120 Hz animations
- Distinctive custom icon

Reference material (gitignored): `reference/stats` (MIT, reusable with notice), `reference/aldente-oss` (proprietary eval licence — facts only, never copy), `reference/re` (thinned arm64 binaries of AlDente Pro 1.39.4 and Stats 3.0.20).

Dev box: MacBook Air M5 (Mac17,4, fanless), 4 Super + 6 Efficiency cores, 16 GB, macOS 27.0.1, Xcode 27.0, Swift 6.4.

## Architecture (decided)
- **UltstatCore** (Swift package, no UI): SMC client, IOKit/IOReport/libproc samplers, ring buffers, battery policy state machine. Unit-testable with fakes.
- **Ultstat.app** (AppKit shell + SwiftUI popovers/settings). Menu-bar widgets rendered by one cached-layer renderer; redraw only when the quantized value changes. SwiftUI views exist only while a popover/settings window is open.
- **UltstatHelper** (root LaunchDaemon via `SMAppService.daemon`). Owns SMC writes and the charge-limit state machine, so the limit holds with the app quit, through sleep and wake. Event-driven (IOKit power notifications, IOPM sleep/wake), with no polling loop. XPC limited to Ultstat's code-signing requirement. On SIGTERM, uninstall or crash recovery it restores normal charging.
- **Scheduler**: one `DispatchSourceTimer` (utility QoS, 10–20 % leeway) drives every sampler. Each tick reads only metrics with live demand: visible widget, open popover, or alert rule. Slows down on battery or when locked; stops while displays sleep.
- **Rules**: no subprocess spawning (Stats runs `nettop`/`ps`/`top`, so we use libproc and sysctl); no persistent DB on the hot path (Stats uses LevelDB, so we keep in-memory ring buffers and snapshot on quit); no JSON on the hot path.

## SMC charge-control keys (from AlDente Pro 1.39.4 strings; decision logic pending RE)
CHTE, CHIE (new firmware) · CH0B, CH0C, CH0I (old firmware) · CHWA · ACLC (MagSafe LED) · BCLM, BFCL (Intel) · MSLD (lid) · B0AC, B0AV, B0CM, B0UC, BRSC, PSTR, ACIN, ACGG, ACSg, CHCC, CHDB, CHNC, CHSC, CH9H

## Measured facts (M5, macOS 27.0.1)
- Baseline with Stats 3.0.20 + AlDente 1.39.4 running: 1817 mW combined CPU+GPU+ANE (10×1 s). Stats 46–58 ms/s CPU, ~9 wakeups/s; AlDente 18.6 ms/s, ~6 wakeups/s. Raw: `reference/baseline-stats-aldente.txt`.
- SMC read = 100–175 µs per key (coprocessor round trip). IOHID thermal read = ~757 µs per sensor; all 47 IOHID sensors = 45.6 ms. Stats uses IOHID on Apple Silicon, so Ultstat uses SMC with demand-driven, round-robin subsets.
- M5 SMC: 2429 keys. Integers/floats little-endian (B0CT=11 cycles, B0DC=5760 mAh, B0AC=-631 mA); `#KEY` and sp/fp fixed-point are big-endian. Writable bit = attr & 0x40.
- Temperature families: Tp** Super cores (14), Te** E-cores (4), Tg** GPU (22), Ts** SoC, Ta** ?, TB0T–TB2T battery, TH0x SSD, TW0P Wi-Fi, Tm0B memory. No fans (F*=0). Power: PSTR system total, PDTR DC-in, PPBR battery rail.
- Charge control: see docs/charging-control.md (three generations; macOS 27 uses the native MCL limit).
- Decision: Apple Silicon only (arm64). macOS 26+.

## Needs the user (morning checklist)
1. `sudo DevToolsSecurity -enable` — Developer Mode is off, so hosted/UI XCTest runs hang waiting for admin auth.
2. Make Ultstat visible: ⌘-drag it out of Latch's hidden section (or allow it in System Settings › Menu Bar).
3. Approve the helper: Settings › Battery › Install, then allow it in System Settings › General › Login Items.
   NOTE: no signing identity on this Mac; SMAppService daemons may refuse ad-hoc builds. A free Apple ID in
   Xcode (Settings › Accounts) gives an "Apple Development" certificate. Fallback: installer via admin prompt.
4. Supervised live test of charge control (native MCL path on M5/macOS 27): set limit 75/80, watch it hold;
   verify sub-80 limits, discharge (CHIE), restore on quit/uninstall.
5. Consider changing the macOS password (it was typed into the chat).

## Iteration plan
- [x] 0. Recon: references cloned, skills vetted and installed, tooling (xcodegen, swiftlint, swiftformat, JDK 21, Ghidra)
- [x] 1. RE AlDente charge-control logic → docs/charging-control.md. macOS 27: native MCL limit via root prefs + Darwin notify; discharge via CHIE=0x08. Open: <80 % limits, sailing/heat/calibration logic details.
- [x] 2. Project skeleton (XcodeGen): app, helper, core package, tests (CI lint/format still TODO)
- [x] 3. SMC client + key enumeration + sensor discovery for M5
- [x] 4. Scheduler + demand model + ring buffers; power harness (reference/pm-summary.py)
- [x] 5. CPU, RAM, disk, network samplers
- [~] 6. GPU, system power (PSTR), temperatures done. TODO: IOReport per-component power, fans (none on M5; implement generically)
- [~] 7. Battery info done (event-driven). TODO: Bluetooth device batteries
- [~] 8. Helper + XPC + state machine + actuators done, unit tested with fakes. NOT yet installed or tested live (needs user: approval + supervised SMC test). TODO: calibration mode, schedule
- [~] 9. Menu-bar renderer (text/bar/stacked) + popover dashboard. TODO: sparkline style in menu bar, design polish
- [ ] 10. Settings UI, onboarding, launch at login, permissions (Menu Bar privacy on macOS 26+)
- [ ] 11. Icon + visual polish + animations
- [ ] 12. Notifications/alerts, clock, extras beyond Stats/AlDente
- [ ] 13. Test suites: unit, UI (every click path), leak checks (`leaks`, Memory Graph), stress
- [ ] 14. Power/perf audit vs Stats and AlDente (powermetrics, Instruments Energy)
- [ ] 15+. Audit/fix iterations (≥15 total), release packaging (DMG, notarization when Developer ID is available), README, LICENSE, CONTRIBUTING

## Iteration log
- 2026-10-12 — Iteration 4 (audits + features): popover stress test found unbounded growth from numericText transitions (CG glyph cache, +0.75 MB/open) — fixed, now bounded (44 MB after 120 opens). Settings never opened (deprecated showSettingsWindow:) — replaced SwiftUI App with AppKit main + owned Settings window. Helper status .notFound mis-mapped to "missing" — fixed. Calibration mode, alerts (engine + notifications), CPU/ANE/DRAM power via helper XPC, OSS scaffolding (LICENSE/NOTICE/README/CONTRIBUTING/CI/swiftlint strict clean). Tests: 52 core + 18 kit. Idle: **0.85 ms/s, 0.56 wakeups/s, energy 0.08, 15 MB** (Stats 56.8/9.0/7.09/151 MB; AlDente 9.6/2.9/1.27/80 MB).
- 2026-10-12 — Iteration 3: icon ("the charge is the chart", tools/make-icon.swift); dashboard redesign with palette validated by the dataviz checker; top processes via libproc with per-process watts (ri_energy_nj); GPU power via IOReport (CPU/ANE/DRAM energy read 0 unprivileged on macOS 27, so they move to the helper); fans; accessory batteries (HID without permission, earbuds opt-in); UltstatKit module so app logic tests run with `swift test` (60 tests). Idle: 1.56 ms/s, 0.49 wakeups/s, energy 0.16.
- 2026-10-12 — Iteration 2: app + helper built (Release 2.1 MB). Power iterations on default menu bar (cpu, memory, temp, battery), 20–30 s powermetrics:
  | build | CPU ms/s | wakeups/s | energy |
  |---|---|---|---|
  | first build | 8.38 | 5.36 | 1.01 |
  | cached symbols/attrs, rasterise once, fixed slots | 5.55 | 5.21 | 0.60 |
  | CALayer contents instead of NSStatusBarButton.image | **1.07** | **0.59** | **0.13** |
  | Stats 3.0.20 | 57.15 | 9.17 | 7.37 |
  | AlDente 1.39.4 | 10.97 | 3.51 | 1.63 |
  Per widget alone: none 0.09, battery 0.05, memory 0.11, temperature 0.22, network 0.18 ms/s. Footprint: Ultstat 44 MB, Stats 151 MB, AlDente 80 MB.
  NOTE: the user's menu-bar manager (Latch) hides new items left of its chevron; Ultstat's item is created and visible=true but hidden there. Use `-UltstatSnapshotDir DIR` to render PNGs.
  NOTE: zsh `log` is a builtin; use /usr/bin/log.
- 2026-10-12 — Iteration 1: SMC/IOHID benchmarks, CPU sampler (xnu host_statistics rate-limit found and handled), AlDente charge-control RE complete. 15 tests passing.
- 2026-10-12 — Iteration 0 done. AlDente OSS repo is NOT open source (evaluation licence). Stats is MIT.

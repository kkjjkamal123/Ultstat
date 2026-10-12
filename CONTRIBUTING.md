# Contributing

Thanks for helping. A few ground rules keep Ultstat fast:

1. **Measure, don't guess.** If a change touches sampling, rendering or the scheduler, include before/after numbers from `powermetrics --samplers tasks` (CPU ms/s, wakeups/s) and `ultstat-bench`.
2. **Nothing polls that could be an event.** Prefer IOKit/notify/DispatchSource notifications.
3. **No child processes, no `Process()`.** Use libproc, sysctl, IOKit.
4. **Demand-driven.** New metrics must only be sampled while something displays them.
5. **Charge control is safety-critical.** Every change to `Charging/` needs tests; the invariant test (never discharge while unplugged, never both charge and discharge) must stay green.
6. Run `swift test` in `Packages/UltstatCore` and `swiftlint` before opening a PR.

Reverse-engineering notes go in `docs/` as facts (keys, values, order). Never paste decompiled third-party code.

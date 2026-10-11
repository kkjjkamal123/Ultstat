# How charge control works on Apple Silicon

Interoperability notes for Ultstat's clean-room charge controller. Everything here is either
observed on hardware or recovered as *behaviour* (which keys, which values, in which order) from
shipping software for interoperability. No third-party code is reproduced.

Test machine: MacBook Air M5 (Mac17,4), macOS 27.0.1 (26A434), SMC with 2429 keys.

## Three generations of mechanism

| Firmware / macOS | Stop charging (adapter stays on) | Resume charging | Force discharge (adapter bypassed) |
|---|---|---|---|
| Legacy Apple Silicon (≤ macOS 15) | `CH0B` = `0x02`, `CH0C` = `0x02` | both `0x00` | `CH0I` = `0x01` |
| macOS 26 "Tahoe" firmware | `CHTE` (ui32) = `0x01000000`, bytes `01 00 00 00` | `CHTE` = `00 00 00 00` | `CHIE` (hex_, 1 byte) = `0x08` |
| macOS 27 (M5 tested) | **No SMC inhibit key exists.** Use the native limit (below) | native limit | `CHIE` = `0x08`, restore `0x00` |

On the M5/macOS 27 test machine `CHTE`, `CH0B`, `CH0C`, `CH0I`, `CHWA` and `BCLM` are all absent.
`CHIE` exists (attr `0xd4`, writable), and was observed at `0x08` while the battery discharged at
−631 mA with the charger connected.

Before writing, detect the generation by probing key presence, not by OS version:
`CHTE` present ⇒ Tahoe path; `CH0B`/`CH0C` present ⇒ legacy path; neither ⇒ native-limit path.

## The native charge limit ("MCL", macOS 26+)

macOS ships its own charge limiter (System Settings › Battery › Charge Limit), internally
"Manual Charge Limit". Its public-to-Apple API is `PowerUISmartChargeClient`
(`setMCLLimit:error:`, `getMCLLimitWithError:`, `isMCLSupported`, `enableMCL:`, `disableMCL:`,
`temporarilyOverrideMCLTargetSoC:error:`, `temporarilyDisableMCL:`) talking to the
`com.apple.powerui.smartChargeManager` Mach service in `PowerUIAgent`. That service requires the
Apple-private entitlement `com.apple.powerui.smartcharging`; unentitled callers get silent zeros
(verified: `isMCLSupported` → 0, `getMCLLimit` → 0, no error, no log line).

The settings live in a root-owned preferences domain that the daemon re-reads on a Darwin
notification, so a root helper can drive the limiter without the entitlement:

- Domain: `com.apple.smartcharging.topoffprotection`
- Scope: `kCFPreferencesCurrentUser` as root (i.e. `/var/root/Library/Preferences/…`), `kCFPreferencesAnyHost`
- Reload signal: Darwin notification `com.apple.smartcharging.defaultschanged`

Enable / change the limit, in order:

1. `enabled` = `false` (turns off Optimized Battery Charging so the two don't fight)
2. `mclLimitValue` = limit percent (Int)
3. `MCLFeatureState` = `1`
4. remove `checkpoint` and `currentState` (resets the daemon's state machine so the new limit applies now)
5. `CFPreferencesSynchronize`, then post `com.apple.smartcharging.defaultschanged`

Related keys seen: `MCLTempDisabledUntilDate`, `MCLOverridenUntilDate` (temporary override / top-up),
`savedMCLTargetSoC`. Related notification: `com.apple.system.powersources.chargingtofulloverride`
(observed with `notify_register_check` / `notify_get_state`; indicates a "charge to full" override).

### Open questions (need a supervised test on real hardware)
- Does the daemon honour `mclLimitValue` below 80 (System Settings only offers 80–100)?
- Exact semantics of `MCLFeatureState` values other than 1, and of `MCLTempDisabledUntilDate`.
- Whether a fresh install needs `isMCLSupported` true (it reports 0 to unentitled callers, so it can't be used for detection).

## Other writable keys of interest (M5)

| Key | Type | Observed | Meaning |
|---|---|---|---|
| `ACLC` | ui8 | `0x02` | MagSafe LED: 0 = system, 1 = off, 3 = green, 4 = amber (legacy mapping; verify) |
| `MSLD` | ui8 | `0x00` | Lid state |
| `LPMS` | ui8 | `0x00` | Low Power Mode state |
| `CBSC`/`CBSV`/`CBTC` | ui32/ui32/ui8 | 8 / 4 / 1 | Unknown battery-controller config; do not write |

Writable bit: `attributes & 0x40`.

## Reading power and battery (no root needed)

- `PSTR` (flt): total system power in W. `PDTR` (flt): DC-in power. `PPBR` (flt): battery rail.
- Battery details come from IOKit `AppleSmartBattery` (typed and authoritative), not SMC.
- SMC integers are little-endian on Apple Silicon (`B0CT` `0b 00` = 11 cycles); `#KEY` and the
  `spXY`/`fpXY` fixed-point types are big-endian.

## Cost

One SMC read is 100–175 µs (a coprocessor round trip). IOHID thermal reads are ~757 µs each.
Charge control is event-driven (IOKit power-source notifications), not polled.

## Component power (IOReport "Energy Model")

On macOS 27 (M5) the mJ channels — `CPU Energy`, `ANE`, `DRAM` and friends — read **0 for non-root
processes**, over any interval; `GPU Energy` (nJ) still reports. Ultstat therefore reads GPU power
in the app (subscribed to that one channel: 0.16 ms per sample vs 2.2 ms for the whole group) and
leaves CPU/ANE/DRAM power to the root helper.

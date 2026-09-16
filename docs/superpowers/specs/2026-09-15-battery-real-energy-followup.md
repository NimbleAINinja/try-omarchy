# Follow-up: real energy values so the bar can show time remaining

Status: not started — scoped, not yet approved
Date: 2026-09-15
Follows: `2026-09-15-host-battery-design.md`

## The gap

The host battery mirror delivers a live time-to-empty estimate all the way into
the guest, but nothing that draws the Omarchy bar can read it.

Observed on a MacBook Air running on battery, 2026-09-15:

| Layer | Value |
| --- | --- |
| `/sys/.../try-omarchy-battery/state` | `present=1 status=discharging capacity=23 ac=0 time_to_empty=3180 time_to_full=-1` |
| `/sys/class/power_supply/BAT0/time_to_empty_avg` | `3600` (live, at 22%) |
| `upower -i` on `BAT0` and on `DisplayDevice` | no `time to empty` field at all |
| UPower `energy` / `energy-full` / `energy-rate` | `0 Wh` / `0 Wh` / `0 W` |

UPower never reads `time_to_empty_avg`. It derives time from energy and rate,
and a capacity-only battery gives it neither, so it reports nothing. The
Quickshell bar renders from UPower, so the estimate is queryable from sysfs
(`acpi`, fastfetch, scripts) but invisible in the bar.

This was verified twice: on AC at 100% (where sysfs itself correctly reports
`-1`, so that test proved nothing either way) and then on a genuinely
discharging battery, which is the measurement that settled it.

## Decision to revisit

The original design chose "percentage, charge state, AC presence, and
time-to-empty/time-to-full" as its fidelity level, and separately chose
capacity-only properties with no synthesized `ENERGY_*`. Those two choices are
in conflict, and nobody noticed until the feature ran on real hardware: the
time estimates were specified, plumbed, and tested, but cannot reach the
surface they were specified for.

So this is not a bug to patch. It is a decision to make again with better
information.

## Options considered

**Patch Omarchy's bar to read sysfs directly.** Rejected. The Quattro bar is
upstream Basecamp QML; this would add a patch to `guest/patches/omarchy/`,
which the project treats as debt carried only until upstream lands a fix. Bar
internals churn, and it would fix one bar while every other UPower consumer
stays blind.

**Synthesize `ENERGY_*` / `POWER_NOW` from capacity.** Rejected. Roughly
fifteen lines in code we own, no upstream patch, and UPower would derive an
accurate time — because a real `time_to_empty` is available to work backwards
from. But it requires inventing a capacity scale (a nominal design figure in
Wh), so `upower -d` would report energy values that are fiction. This project
otherwise refuses to state things it does not know.

**Report real energy from IOKit's `AppleSmartBattery`.** Recommended. macOS
knows the true figures; they are simply absent from the simple power-sources
API the design chose. Publishing them makes `upower -d` more honest than it is
today, not less, and needs no upstream patch.

## Recommended approach

Extend the host bridge to read `AppleSmartBattery` from the IO registry
alongside the existing power-sources snapshot, carry the figures over the
existing protocol, and publish them as real `power_supply` properties.

### Host side

`IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))`,
then read from its properties. No entitlement, no permission prompt, no change
to the app's security posture — it is a registry read.

Relevant keys (`ioreg -rc AppleSmartBattery` to inspect on a given machine):

| Key | Unit | Use |
| --- | --- | --- |
| `CurrentCapacity` | mAh | energy now |
| `MaxCapacity` | mAh | energy full |
| `DesignCapacity` | mAh | energy full, design |
| `Voltage` | mV | scaling for all of the above |
| `Amperage` / `InstantAmperage` | mA, signed | power now (negative while discharging) |

The unit arithmetic is exact, which is what makes this clean:

```
mAh × mV = 10⁻³ Ah × 10⁻³ V = 10⁻⁶ Wh = µWh    → POWER_SUPPLY_ENERGY_*  (µWh)
mA  × mV = 10⁻³ A  × 10⁻³ V = 10⁻⁶ W  = µW     → POWER_SUPPLY_POWER_NOW (µW)
```

So `ENERGY_NOW = CurrentCapacity × Voltage`, `ENERGY_FULL = MaxCapacity ×
Voltage`, `ENERGY_FULL_DESIGN = DesignCapacity × Voltage`, and
`POWER_NOW = |Amperage| × Voltage`, all in the units sysfs already expects.

### Protocol

Add `energyNowMicroWh`, `energyFullMicroWh`, `energyFullDesignMicroWh` and
`powerNowMicroW`, each an integer or null. Bump `runtime.battery.protocolVersion`
to 2 in `guest/spec.json` and in the launcher's contract block, keeping both
copies byte-identical. Every field stays nullable: a Mac that does not expose
`AppleSmartBattery` must degrade to exactly today's behaviour rather than fail.

### Guest side

The agent gains four keys in its state line; the kernel module gains
`ENERGY_NOW`, `ENERGY_FULL`, `ENERGY_FULL_DESIGN` and `POWER_NOW` in the
battery property table, returning `-ENODATA` when a value is absent — the same
convention `TIME_TO_EMPTY_AVG` already uses for `-1`.

Keep `CAPACITY` and the existing time properties. Nothing is removed, so a
guest retrofitted with the current module keeps working against a newer host,
and an older host against a newer module simply omits the new keys.

## Acceptance criteria

1. `upower -i` on `BAT0` and on `DisplayDevice` both report a non-zero
   `energy`, `energy-full` and `energy-rate`, and print a `time to empty`
   line while discharging.
2. That time is within a few minutes of what macOS itself reports, and within a
   few minutes of `time_to_empty_avg`.
3. The Omarchy bar shows a time remaining in its battery tooltip or popover.
4. On a Mac with no internal battery, and on a Mac where
   `AppleSmartBattery` is unavailable, behaviour is unchanged from today.
5. `energy-full-design` matches the machine's actual design capacity, verified
   against `ioreg` and System Information.

## Risks and unknowns

- **`AppleSmartBattery` availability on Apple Silicon** is the first thing to
  check; confirm with `ioreg -rc AppleSmartBattery` on both an M-series laptop
  and a desktop Mac before writing any code. If the service or its keys are
  absent or differently named, this whole approach needs rethinking, and the
  synthesize-from-capacity option becomes the fallback.
- **Amperage sign and smoothing.** `Amperage` is signed and noisy right after a
  plug change; `InstantAmperage` is noisier still. Decide which to use and
  whether to report `POWER_NOW` as absent rather than zero while charging
  state is settling, since a zero rate makes UPower compute nothing.
- **Charging direction.** UPower needs rate plus the gap to full to estimate
  time-to-full; confirm both directions produce sane numbers, not just
  discharge.
- **Scope creep into health.** `CycleCount`, `Temperature` and condition are
  right there in the same registry entry. They are still out of scope: nothing
  in Omarchy renders them, and the original design excluded them deliberately.

## Out of scope

- Any change to Omarchy's bar or to upstream Omarchy.
- Battery health, cycle count, temperature, Low Power Mode.
- Guest-initiated changes to Mac power state.

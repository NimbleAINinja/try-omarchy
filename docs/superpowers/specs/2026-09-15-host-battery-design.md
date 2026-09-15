# Host battery in the guest — design

Status: approved for planning
Date: 2026-09-15

## Goal

Show the Mac's battery inside Omarchy as a real battery, so the Quickshell bar,
low-battery warnings, and anything else power-aware work without configuring
them. The guest should behave like the laptop it is running on.

## Background

Omarchy Quattro's bar is Quickshell, not waybar. The factory image carries
Quickshell's `Quickshell.Services.UPower` bindings and the full GNOME
`battery-level-*` icon set, so the bar reads UPower, and UPower reads
`/sys/class/power_supply`. The VM exposes no power supply, so the widget is
absent.

The ARM64 kernel the image uses (`linux-aarch64`) ships no `test_power.ko`; its
`drivers/power/supply` modules are all real hardware gauges. A sysfs battery
therefore requires an out-of-tree module. The image already builds
`v4l2loopback-dkms` into `updates/dkms/v4l2loopback.ko` at image-build time, so
DKMS is a proven path here rather than new machinery.

Alternatives considered and rejected:

- **Vendor upstream `test_power.c`.** No new kernel code to get wrong, but it
  names its devices `test_battery`/`test_ac`, carries a USB supply and a wakeup
  timer we do not want, and its per-parameter writes let a consumer observe a
  torn state (new percentage, old charging flag) on every update.
- **Fake the UPower D-Bus service.** No kernel module, but it means
  reimplementing UPower's API surface and masking the real UPower, which still
  legitimately serves Bluetooth device batteries and lid state. Fragile exactly
  where it is hardest to test.
- **HID battery via `uhid`.** Linux creates those power supplies with
  `POWER_SUPPLY_SCOPE_DEVICE`, so UPower treats them as peripheral batteries and
  never folds them into the display device the bar renders.

## Decisions

| Decision | Choice |
| --- | --- |
| Surface | A real `power_supply` device, via a purpose-built DKMS module |
| Critical battery | Warn only — `CriticalPowerAction=Ignore`; the VM never acts |
| Fidelity | Percentage, charge state, AC presence, time-to-empty/time-to-full |
| Activation | Always on, no start-menu surface, no macOS permission |
| Direction | Host to guest only; the guest can never change Mac power state |
| Supply names | `BAT0` and `ADP0`, the conventional Linux names |

`BAT0`/`ADP0` maximize compatibility with tools that special-case those names
(fastfetch, `acpi`, status scripts). The device is honest in its properties
instead: manufacturer `Apple`, model `Mac Battery`.

## Architecture

One new host-integration channel, built like the existing four. A fifth
virtio-serial port carries newline-delimited JSON one way.

```text
IOKit power sources  ->  NativeBatteryBridge (Swift, in the helper)
                            |  dev.tryomarchy.battery (virtio-serial, JSON lines)
                            v
                         omarchy-native-battery-bridge (root system service)
                            |  write() one line
                            v
                         try_omarchy_battery.ko (DKMS)
                            |
                            v
                         /sys/class/power_supply/{BAT0,ADP0}
                            |
                            v
                         UPower -> Quickshell bar, notifications
```

## Protocol

One message type, a complete snapshot every time. No deltas, so a restarted or
late-joining agent is never half-informed.

```json
{"type":"state","present":true,"percentage":57,"state":"discharging",
 "acConnected":false,"timeToEmptySeconds":8100,"timeToFullSeconds":null}
```

- `state` is one of `charging`, `discharging`, `full`, `not-charging`,
  `unknown`.
- `percentage` is an integer 0-100, absent or null when `present` is false.
- Time fields are integer seconds or null when the host has no estimate.
- A Mac with no internal battery sends `"present":false` with
  `"acConnected":true`.

The host sends a snapshot when a guest attaches to the port, on every coalesced
change, and every 30 seconds as a safety net against a missed notification.

## Host side

`macos/Sources/OmarchyVMHelper/NativeBatteryBridge.swift`, invoked as
`--bridge-native-battery QEMU_PID SOCKET` from `main.swift`, following the
`--bridge-native-camera` entry point verbatim including its signal-source
teardown.

Snapshots come from `IOPSCopyPowerSourcesInfo` and
`IOPSGetPowerSourceDescription`; change notifications from
`IOPSNotificationCreateRunLoopSource`. This is the simple power-sources API: no
entitlement, no permission prompt, and no `AppleSmartBattery` service, which
would only be needed for cycle count and health that nothing in Omarchy renders.

Two guards on send rate: a coalescing floor so an IOKit notification burst
cannot spam the port, and the 30-second periodic resend.

`run-qemu-gpu.sh` gains:

- `battery_bridge_socket="/tmp/${work_dir##*/}/battery.sock"`
- `-chardev socket,id=omarchy-battery-bridge,path=$battery_bridge_socket,server=on,wait=off`
- `-device virtserialport,bus=omarchy-serial.0,nr=5,chardev=omarchy-battery-bridge,name=dev.tryomarchy.battery`
- a `battery` entry in the build-spec dict block beside `clipboard` and
  `authentication`
- `start_battery_bridge`, its restart counter, its `terminate_child` cleanup,
  and its socket in the existing startup readiness gate

## Guest side

### Kernel module

`guest/native-module/try-omarchy-battery/` holds `try-omarchy-battery.c`, a
`Makefile`, and `dkms.conf`. The module creates a platform device parenting two
power supplies:

- `ADP0`, `POWER_SUPPLY_TYPE_MAINS`, property `ONLINE`.
- `BAT0`, `POWER_SUPPLY_TYPE_BATTERY`, properties `STATUS`, `PRESENT`,
  `CAPACITY`, `TIME_TO_EMPTY_AVG`, `TIME_TO_FULL_AVG`, `TECHNOLOGY`,
  `MANUFACTURER`, `MODEL_NAME`. Registered and unregistered as the host reports
  `present`.

Capacity only, with no synthesized `ENERGY_*` properties. UPower handles
capacity-only batteries natively, the same way it does phone batteries.

State arrives through one writable attribute at
`/sys/devices/platform/try-omarchy-battery/state`, mode 0600 root, accepting a
single line:

```text
present=1 status=discharging capacity=57 ac=0 time_to_empty=8100 time_to_full=-1
```

One write is one consistent snapshot and one `power_supply_changed()` per supply
that actually moved. `-1` means no estimate. A malformed line is rejected whole
and the previous state is retained.

`status` accepts exactly the token set the protocol's `state` field uses, so the
agent passes it through unchanged. When the host reports `present:false` the
agent writes `present=0 ac=<0|1>` and omits every battery-only key; the module
unregisters `BAT0` and ignores stale values for it.

### Packaging

`guest/scripts/register-native-battery-module.sh` builds a
`try-omarchy-battery-dkms` package into the guest's local repository, mirroring
`register-patched-hyprland.sh`, and the factory transaction installs it. The
DKMS pacman hook then builds it against the pinned `linux-aarch64` in the build
chroot, producing `updates/dkms/try_omarchy_battery.ko`, and the package appears
in `packages.lock.txt` so the module is provenance-tracked like everything else.

Dropping the source in the native overlay and running `dkms install` from
`finalize-rootfs` would skip the PKGBUILD but leave the files unowned by pacman,
which cuts against how this repo treats the image.

### Agent

`/usr/local/bin/omarchy-native-battery-bridge`, Python, in the house style of the
camera and clipboard agents, but a **system** service running as root: it writes
sysfs and must be up before anyone logs in.

It reads and validates JSON lines and writes the state line. On EOF, meaning the
host bridge is gone, it writes `status=unknown` before exiting non-zero, so a
dead bridge reads as an honest unknown rather than a frozen percentage.

`omarchy-native-battery-bridge.service` carries
`ConditionPathExists=/dev/virtio-ports/dev.tryomarchy.battery`,
`Restart=always`, `RestartSec=1`, and `StartLimitIntervalSec=0`.
`finalize-rootfs.sh` enables it beside `omarchy-native-mac-share.service`.

### Drop-ins

- `/etc/modules-load.d/95-try-omarchy-battery.conf` loads the module at boot,
  mirroring the camera's modules-load.d.
- `/etc/udev/rules.d/95-omarchy-native-battery.rules` sets the port root-only
  (`MODE="0600"`, no `GROUP="users"`) — the authentication rule's posture, since
  no user process needs this port.
- `/etc/UPower/UPower.conf.d/90-try-omarchy.conf` sets
  `CriticalPowerAction=Ignore`.

## Existing guests

App updates retain existing persistent guest disks, so an already-provisioned VM
does not receive the module from an app update. It does receive the virtio port
immediately, because QEMU's command line comes from the host at launch.

A retrofit needs no factory reset. The factory image already contains
`dkms 3.4.3`, `gcc 16.1.1`, `make`, `kmod`, and `linux-aarch64-headers 7.2.6-1`
matching its `linux-aarch64 7.2.6-1` kernel, so the guest can build the module
itself.

`guest/scripts/install-battery-into-existing-guest.sh` runs **inside** the VM
against files staged through the shared Mac folder — no network fetch, so it
stays auditable and matches how this repo treats supply chain. It installs the
six files, runs `dkms install try-omarchy-battery/1.0`, and enables the service.

This script is also how the feature is tested during development, without
rebuilding a 6 GB image per iteration.

Because the module is installed through DKMS, the pacman DKMS hook rebuilds it
when a guest `pacman -Syu` bumps the kernel, so a retrofit survives guest kernel
updates.

## Failure modes

All are non-fatal to the VM, matching the camera bridge's posture.

| Condition | Behavior |
| --- | --- |
| Mac has no internal battery | `present:false`; guest keeps `ADP0` only; bar shows nothing |
| Host bridge dies | Agent writes `status=unknown`, exits; systemd restarts it; launcher restarts the bridge |
| Module absent (un-retrofitted guest) | Agent logs and exits; nothing else notices |
| Malformed JSON line or state line | Rejected; previous state retained |
| Host sleep and wake | Fresh snapshot on the next notification or the 30-second tick |
| Critically low Mac battery | Omarchy warns; the VM does not suspend or power off |

## Testing

- `guest/tests/test_native_battery_bridge.py` — agent JSON validation, state
  line formatting, `status=unknown` on EOF, desktop-Mac case.
- `guest/tests/verify.py` — module packaged and locked, headers locked, unit
  enabled, udev rule root-only, modules-load and UPower drop-ins present.
- `macos/Tests/OmarchyVMHelperTests/BatteryBridgeTests.swift` — snapshot
  encoding, coalescing, no-battery Mac, time-field nulls.
- `macos/Tests/run-qemu-ssh-contract.test.sh` — the `nr=5` port assertion.
- Manual on Apple Silicon: `upower -d` reports `BAT0`; the bar icon and
  percentage track the Mac on unplug and replug; the widget is absent on a Mac
  with no battery.

## Documentation

- A paragraph in `docs/architecture.md` beside the other host-integration
  channels.
- `docs/host-battery.md` covering the protocol, the sysfs contract, and the
  retrofit procedure for existing guests.
- A README highlight line.

## Out of scope

- Guest-initiated changes to Mac power state.
- Battery health, cycle count, temperature, and Low Power Mode.
- Lid state and suspend-on-lid.
- Any start-menu or preference surface.

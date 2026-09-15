# Host Battery Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror the Mac's battery into the Omarchy guest as a real `/sys/class/power_supply` device so the Quickshell bar and every UPower consumer work unconfigured.

**Architecture:** A fifth virtio-serial port (`dev.tryomarchy.battery`, `nr=5`) carries newline-delimited JSON snapshots from a Swift bridge (IOKit power sources) to a root Python agent in the guest, which writes a single consistent state line into a purpose-built DKMS kernel module exposing `BAT0` (Battery) and `ADP0` (Mains). The guest may send only `{"type":"refresh"}`.

**Tech Stack:** Swift 6 (swift-testing `#expect`), Python 3 (`unittest`), Linux kernel module (C, GPL-2.0, DKMS), bash 3.2-compatible launcher script.

**Spec:** `docs/superpowers/specs/2026-09-15-host-battery-design.md`

## Global Constraints

- Port name is exactly `dev.tryomarchy.battery`, virtserialport `nr=5` on bus `omarchy-serial.0`.
- Guest supplies are named exactly `BAT0` and `ADP0`; manufacturer `Apple`, model `Mac Battery`.
- Module/package version is `1.0.0`, pkgrel `1`; DKMS name `try-omarchy-battery/1.0.0`; built module `try_omarchy_battery.ko`.
- Protocol `state` tokens: `charging`, `discharging`, `full`, `not-charging`, `unknown` — identical on the wire and in the sysfs `status=` key.
- Sysfs contract: one writable attribute `/sys/devices/platform/try-omarchy-battery/state`, mode 0600 root; a whole line per write; malformed lines rejected whole; `-1` means no estimate.
- `power_supply_unregister` must never run while the state mutex is held (spec lock-ordering constraint).
- UPower drop-in must set **both** `CriticalPowerAction=Ignore` and `AllowRiskyCriticalPowerAction=true` (upower 1.91.4 treats `Ignore` as risky).
- `macos/run-qemu-gpu.sh` runs under macOS bash 3.2: no `wait -n`, no associative arrays, no `${var,,}`.
- All guest tests run via `guest/test`; all macOS tests via `make test` from the repo root.
- Commit messages end with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01V11NHWxRgQdLPoyjxwVULA`

---

### Task 1: Guest agent `omarchy-native-battery-bridge`

**Files:**
- Create: `guest/native-overlay/usr/local/bin/omarchy-native-battery-bridge`
- Test: `guest/tests/test_native_battery_bridge.py`

**Interfaces:**
- Consumes: nothing from other tasks (the port device path is a constant).
- Produces: the sysfs line grammar consumed by Task 2's kernel module —
  `present=1 status=<token> capacity=<0-100> ac=<0|1> time_to_empty=<int|-1> time_to_full=<int|-1>\n`
  and `present=0 ac=<0|1>\n`. Also module-level functions used by the tests:
  `decode_message(line: bytes) -> dict | None`, `format_state_line(message: dict) -> bytes`,
  `unknown_state_line(last: dict | None) -> bytes`, `REFRESH_LINE: bytes`.

- [ ] **Step 1: Write the failing test**

Create `guest/tests/test_native_battery_bridge.py`:

```python
#!/usr/bin/env python3
"""Behavior tests for the guest side of macOS battery mirroring."""

from __future__ import annotations

import importlib.util
from importlib.machinery import SourceFileLoader
import json
from pathlib import Path
import unittest


BRIDGE_PATH = (
    Path(__file__).resolve().parents[1]
    / "native-overlay/usr/local/bin/omarchy-native-battery-bridge"
)
LOADER = SourceFileLoader("omarchy_native_battery_bridge", str(BRIDGE_PATH))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {BRIDGE_PATH}")
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


def state(**overrides) -> bytes:
    message = {
        "type": "state",
        "present": True,
        "percentage": 57,
        "state": "discharging",
        "acConnected": False,
        "timeToEmptySeconds": 8100,
        "timeToFullSeconds": None,
    }
    message.update(overrides)
    return json.dumps(message).encode()


class DecodeTests(unittest.TestCase):
    def test_accepts_a_complete_snapshot(self) -> None:
        decoded = bridge.decode_message(state())
        self.assertEqual(decoded["percentage"], 57)
        self.assertEqual(decoded["state"], "discharging")

    def test_accepts_a_desktop_mac_snapshot(self) -> None:
        decoded = bridge.decode_message(
            state(present=False, percentage=None, state="unknown",
                  acConnected=True, timeToEmptySeconds=None)
        )
        self.assertFalse(decoded["present"])
        self.assertTrue(decoded["acConnected"])

    def test_rejects_malformed_messages(self) -> None:
        for line in (
            b"[]",
            b'{"type":"refresh"}',
            state(percentage=101),
            state(percentage="57"),
            state(state="melting"),
            state(timeToEmptySeconds=-5),
            json.dumps({"type": "state", "present": True}).encode(),
            state() + b',"extra":1}'[:0] + b"garbage",
        ):
            with self.assertRaises(ValueError):
                bridge.decode_message(line)

    def test_extra_keys_are_rejected(self) -> None:
        message = json.loads(state())
        message["extra"] = 1
        with self.assertRaises(ValueError):
            bridge.decode_message(json.dumps(message).encode())


class StateLineTests(unittest.TestCase):
    def test_full_snapshot_line(self) -> None:
        decoded = bridge.decode_message(state())
        self.assertEqual(
            bridge.format_state_line(decoded),
            b"present=1 status=discharging capacity=57 ac=0 "
            b"time_to_empty=8100 time_to_full=-1\n",
        )

    def test_charging_snapshot_line(self) -> None:
        decoded = bridge.decode_message(
            state(state="charging", acConnected=True,
                  timeToEmptySeconds=None, timeToFullSeconds=2700)
        )
        self.assertEqual(
            bridge.format_state_line(decoded),
            b"present=1 status=charging capacity=57 ac=1 "
            b"time_to_empty=-1 time_to_full=2700\n",
        )

    def test_desktop_mac_omits_battery_keys(self) -> None:
        decoded = bridge.decode_message(
            state(present=False, percentage=None, state="unknown",
                  acConnected=True, timeToEmptySeconds=None)
        )
        self.assertEqual(bridge.format_state_line(decoded), b"present=0 ac=1\n")

    def test_unknown_line_preserves_last_snapshot(self) -> None:
        decoded = bridge.decode_message(state())
        self.assertEqual(
            bridge.unknown_state_line(decoded),
            b"present=1 status=unknown capacity=57 ac=0 "
            b"time_to_empty=-1 time_to_full=-1\n",
        )

    def test_unknown_line_without_history_reports_absent(self) -> None:
        self.assertEqual(bridge.unknown_state_line(None), b"present=0 ac=1\n")


class RefreshTests(unittest.TestCase):
    def test_refresh_request_shape(self) -> None:
        self.assertEqual(bridge.REFRESH_LINE, b'{"type":"refresh"}\n')


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd guest && python3 -m unittest tests.test_native_battery_bridge -v`
Expected: FAIL — cannot import the bridge (file does not exist).

- [ ] **Step 3: Write the agent**

Create `guest/native-overlay/usr/local/bin/omarchy-native-battery-bridge`:

```python
#!/usr/bin/python3
"""Mirror the Mac's battery into the guest power_supply device.

The host sends one JSON object per line on the dev.tryomarchy.battery
virtserialport:

    {"type": "state", "present": true, "percentage": 57,
     "state": "discharging", "acConnected": false,
     "timeToEmptySeconds": 8100, "timeToFullSeconds": null}

Each accepted snapshot is written as one line to the try-omarchy-battery
kernel module, which republishes it as BAT0/ADP0. This agent sends exactly
one request on start ({"type":"refresh"}), because a guest opening the port
is invisible on the host's socket chardev. Nothing else flows guest-to-host.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
from typing import Any


PORT = Path("/dev/virtio-ports/dev.tryomarchy.battery")
STATE_FILE = Path("/sys/devices/platform/try-omarchy-battery/state")
STATES = ("charging", "discharging", "full", "not-charging", "unknown")
MAX_LINE_BYTES = 4096
REFRESH_LINE = b'{"type":"refresh"}\n'
SCHEMA = {
    "type", "present", "percentage", "state",
    "acConnected", "timeToEmptySeconds", "timeToFullSeconds",
}


def log(message: str) -> None:
    print(f"omarchy-native-battery-bridge: {message}", file=sys.stderr, flush=True)


def decode_message(line: bytes) -> dict[str, Any]:
    """Return a validated snapshot dict, or raise ValueError."""
    message = json.loads(line)
    if not isinstance(message, dict) or message.get("type") != "state":
        raise ValueError("host sent an invalid battery message")
    if set(message) != SCHEMA:
        raise ValueError("host battery message has an unexpected schema")
    if not isinstance(message["present"], bool) or not isinstance(message["acConnected"], bool):
        raise ValueError("battery presence flags must be booleans")
    if message["state"] not in STATES:
        raise ValueError("host sent an unknown battery state")
    percentage = message["percentage"]
    if message["present"]:
        if not isinstance(percentage, int) or isinstance(percentage, bool) \
                or not 0 <= percentage <= 100:
            raise ValueError("battery percentage must be an integer 0-100")
    elif percentage is not None:
        raise ValueError("an absent battery cannot carry a percentage")
    for key in ("timeToEmptySeconds", "timeToFullSeconds"):
        value = message[key]
        if value is not None and (
            not isinstance(value, int) or isinstance(value, bool) or value < 0
        ):
            raise ValueError(f"{key} must be null or a non-negative integer")
    return message


def format_state_line(message: dict[str, Any]) -> bytes:
    """Render one whole-snapshot line for the kernel module."""
    ac = 1 if message["acConnected"] else 0
    if not message["present"]:
        return f"present=0 ac={ac}\n".encode()
    empty = message["timeToEmptySeconds"]
    full = message["timeToFullSeconds"]
    return (
        f"present=1 status={message['state']} capacity={message['percentage']} "
        f"ac={ac} time_to_empty={-1 if empty is None else empty} "
        f"time_to_full={-1 if full is None else full}\n"
    ).encode()


def unknown_state_line(last: dict[str, Any] | None) -> bytes:
    """The honest line for a dead host bridge: keep presence, drop claims."""
    if last is None or not last["present"]:
        ac = 1 if last is None or last["acConnected"] else 0
        return f"present=0 ac={ac}\n".encode()
    ac = 1 if last["acConnected"] else 0
    return (
        f"present=1 status=unknown capacity={last['percentage']} "
        f"ac={ac} time_to_empty=-1 time_to_full=-1\n"
    ).encode()


def write_state(line: bytes) -> None:
    STATE_FILE.write_bytes(line)


def run() -> int:
    if not STATE_FILE.exists():
        log("try-omarchy-battery module is not loaded; nothing to feed")
        return 1
    last: dict[str, Any] | None = None
    try:
        with PORT.open("r+b", buffering=0) as port:
            port.write(REFRESH_LINE)
            buffer = b""
            while True:
                chunk = port.read(4096)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line:
                        continue
                    try:
                        message = decode_message(line)
                    except ValueError as error:
                        log(f"rejected host line: {error}")
                        continue
                    write_state(format_state_line(message))
                    last = message
                if len(buffer) > MAX_LINE_BYTES:
                    log("host line exceeds the size limit")
                    break
    except OSError as error:
        log(f"battery channel failed: {error}")
    try:
        write_state(unknown_state_line(last))
    except OSError as error:
        log(f"could not mark the battery unknown: {error}")
    log("host battery bridge disconnected")
    return 1


if __name__ == "__main__":
    sys.exit(run())
```

Make it executable: `chmod 755 guest/native-overlay/usr/local/bin/omarchy-native-battery-bridge`

- [ ] **Step 4: Run test to verify it passes**

Run: `cd guest && python3 -m unittest tests.test_native_battery_bridge -v`
Expected: PASS (all tests).

- [ ] **Step 5: Run the full guest suite to catch regressions**

Run: `./guest/test` — verify.py will pass unchanged (its battery checks arrive in Task 4).
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add guest/native-overlay/usr/local/bin/omarchy-native-battery-bridge \
        guest/tests/test_native_battery_bridge.py
git commit -m "Add the guest battery agent that feeds host snapshots into sysfs"
```

---

### Task 2: Kernel module `try_omarchy_battery`

**Files:**
- Create: `guest/native-module/try-omarchy-battery/try-omarchy-battery.c`
- Create: `guest/native-module/try-omarchy-battery/Makefile`
- Create: `guest/native-module/try-omarchy-battery/dkms.conf`

**Interfaces:**
- Consumes: the state-line grammar produced by Task 1 (`format_state_line`).
- Produces: `/sys/devices/platform/try-omarchy-battery/state` (0600 root, write =
  whole snapshot, read = current snapshot in the same grammar) and
  `/sys/class/power_supply/{BAT0,ADP0}`. `BAT0` exists only while the host
  reports `present=1`.

There is no host-side unit test for kernel C; correctness is enforced by the
image build (Task 3 fails if it does not compile against the pinned kernel),
by `guest/tests/verify.py` source checks (Task 4), and by review. Follow the
lock-ordering constraint exactly: the state mutex is released before any
`power_supply_register`/`power_supply_unregister`/`power_supply_changed` call;
a separate registration mutex serializes concurrent writers.

- [ ] **Step 1: Write the module source**

Create `guest/native-module/try-omarchy-battery/try-omarchy-battery.c`:

```c
// SPDX-License-Identifier: GPL-2.0-only
/*
 * Mirror the host Mac's battery into the guest as BAT0/ADP0.
 *
 * A root-only agent writes one whole snapshot per write() to the `state`
 * attribute:
 *
 *   present=1 status=discharging capacity=57 ac=0 time_to_empty=8100 time_to_full=-1
 *   present=0 ac=1
 *
 * One write is one consistent snapshot: consumers can never observe a new
 * percentage beside a stale charging flag. -1 means no estimate. A malformed
 * line is rejected whole and the previous state is retained.
 *
 * Lock ordering: tob_register_lock -> tob_state_lock. get_property() takes
 * only tob_state_lock; power_supply registration calls take only
 * tob_register_lock, never while tob_state_lock is held, because
 * power_supply_unregister() waits for readers holding tob_state_lock.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/slab.h>
#include <linux/string.h>

struct tob_state {
	bool present;
	int status;
	int capacity;
	bool ac_online;
	int time_to_empty;
	int time_to_full;
};

static struct platform_device *tob_pdev;
static struct power_supply *tob_ac;
static struct power_supply *tob_bat;
static DEFINE_MUTEX(tob_register_lock);	/* serializes writers + registration */
static DEFINE_MUTEX(tob_state_lock);	/* guards tob_state */
static struct tob_state tob_state = {
	.present = false,
	.status = POWER_SUPPLY_STATUS_UNKNOWN,
	.capacity = 0,
	.ac_online = true,
	.time_to_empty = -1,
	.time_to_full = -1,
};

static const struct {
	const char *token;
	int status;
} tob_status_tokens[] = {
	{ "charging", POWER_SUPPLY_STATUS_CHARGING },
	{ "discharging", POWER_SUPPLY_STATUS_DISCHARGING },
	{ "full", POWER_SUPPLY_STATUS_FULL },
	{ "not-charging", POWER_SUPPLY_STATUS_NOT_CHARGING },
	{ "unknown", POWER_SUPPLY_STATUS_UNKNOWN },
};

static const char *tob_status_token(int status)
{
	size_t index;

	for (index = 0; index < ARRAY_SIZE(tob_status_tokens); index++)
		if (tob_status_tokens[index].status == status)
			return tob_status_tokens[index].token;
	return "unknown";
}

static enum power_supply_property tob_bat_properties[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG,
	POWER_SUPPLY_PROP_TIME_TO_FULL_AVG,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_MANUFACTURER,
	POWER_SUPPLY_PROP_MODEL_NAME,
};

static enum power_supply_property tob_ac_properties[] = {
	POWER_SUPPLY_PROP_ONLINE,
};

static int tob_bat_get_property(struct power_supply *psy,
				enum power_supply_property psp,
				union power_supply_propval *val)
{
	int error = 0;

	mutex_lock(&tob_state_lock);
	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
		val->intval = tob_state.status;
		break;
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = tob_state.present ? 1 : 0;
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		val->intval = tob_state.capacity;
		break;
	case POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG:
		if (tob_state.time_to_empty < 0)
			error = -ENODATA;
		else
			val->intval = tob_state.time_to_empty;
		break;
	case POWER_SUPPLY_PROP_TIME_TO_FULL_AVG:
		if (tob_state.time_to_full < 0)
			error = -ENODATA;
		else
			val->intval = tob_state.time_to_full;
		break;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LION;
		break;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "Apple";
		break;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "Mac Battery";
		break;
	default:
		error = -EINVAL;
		break;
	}
	mutex_unlock(&tob_state_lock);
	return error;
}

static int tob_ac_get_property(struct power_supply *psy,
			       enum power_supply_property psp,
			       union power_supply_propval *val)
{
	if (psp != POWER_SUPPLY_PROP_ONLINE)
		return -EINVAL;
	mutex_lock(&tob_state_lock);
	val->intval = tob_state.ac_online ? 1 : 0;
	mutex_unlock(&tob_state_lock);
	return 0;
}

static const struct power_supply_desc tob_bat_desc = {
	.name = "BAT0",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = tob_bat_properties,
	.num_properties = ARRAY_SIZE(tob_bat_properties),
	.get_property = tob_bat_get_property,
};

static const struct power_supply_desc tob_ac_desc = {
	.name = "ADP0",
	.type = POWER_SUPPLY_TYPE_MAINS,
	.properties = tob_ac_properties,
	.num_properties = ARRAY_SIZE(tob_ac_properties),
	.get_property = tob_ac_get_property,
};

static int tob_parse(const char *buf, size_t count, struct tob_state *next)
{
	bool saw_present = false, saw_ac = false;
	bool saw_status = false, saw_capacity = false;
	char *copy, *cursor, *token;
	int error = -EINVAL;

	next->present = false;
	next->status = POWER_SUPPLY_STATUS_UNKNOWN;
	next->capacity = 0;
	next->ac_online = false;
	next->time_to_empty = -1;
	next->time_to_full = -1;

	copy = kstrndup(buf, count, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	cursor = copy;
	while ((token = strsep(&cursor, " \n")) != NULL) {
		char *value;

		if (!*token)
			continue;
		value = strchr(token, '=');
		if (!value)
			goto out;
		*value++ = '\0';
		if (!strcmp(token, "present")) {
			if (kstrtobool(value, &next->present))
				goto out;
			saw_present = true;
		} else if (!strcmp(token, "ac")) {
			if (kstrtobool(value, &next->ac_online))
				goto out;
			saw_ac = true;
		} else if (!strcmp(token, "status")) {
			size_t index;

			for (index = 0; index < ARRAY_SIZE(tob_status_tokens); index++)
				if (!strcmp(value, tob_status_tokens[index].token))
					break;
			if (index == ARRAY_SIZE(tob_status_tokens))
				goto out;
			next->status = tob_status_tokens[index].status;
			saw_status = true;
		} else if (!strcmp(token, "capacity")) {
			if (kstrtoint(value, 10, &next->capacity) ||
			    next->capacity < 0 || next->capacity > 100)
				goto out;
			saw_capacity = true;
		} else if (!strcmp(token, "time_to_empty")) {
			if (kstrtoint(value, 10, &next->time_to_empty) ||
			    next->time_to_empty < -1)
				goto out;
		} else if (!strcmp(token, "time_to_full")) {
			if (kstrtoint(value, 10, &next->time_to_full) ||
			    next->time_to_full < -1)
				goto out;
		} else {
			goto out;
		}
	}
	if (!saw_present || !saw_ac)
		goto out;
	if (next->present && (!saw_status || !saw_capacity))
		goto out;
	error = 0;
out:
	kfree(copy);
	return error;
}

static ssize_t state_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct tob_state snapshot;

	mutex_lock(&tob_state_lock);
	snapshot = tob_state;
	mutex_unlock(&tob_state_lock);
	if (!snapshot.present)
		return sysfs_emit(buf, "present=0 ac=%d\n",
				  snapshot.ac_online ? 1 : 0);
	return sysfs_emit(buf,
			  "present=1 status=%s capacity=%d ac=%d time_to_empty=%d time_to_full=%d\n",
			  tob_status_token(snapshot.status), snapshot.capacity,
			  snapshot.ac_online ? 1 : 0, snapshot.time_to_empty,
			  snapshot.time_to_full);
}

static ssize_t state_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t count)
{
	struct tob_state next;
	bool ac_changed, bat_changed;
	int error;

	error = tob_parse(buf, count, &next);
	if (error)
		return error;

	mutex_lock(&tob_register_lock);
	mutex_lock(&tob_state_lock);
	ac_changed = next.ac_online != tob_state.ac_online;
	bat_changed = next.present != tob_state.present ||
		      next.status != tob_state.status ||
		      next.capacity != tob_state.capacity ||
		      next.time_to_empty != tob_state.time_to_empty ||
		      next.time_to_full != tob_state.time_to_full;
	tob_state = next;
	mutex_unlock(&tob_state_lock);

	/* Registration outside tob_state_lock: unregister waits for readers. */
	if (next.present && !tob_bat) {
		struct power_supply_config config = {};
		struct power_supply *battery;

		battery = power_supply_register(&tob_pdev->dev, &tob_bat_desc,
						&config);
		if (IS_ERR(battery)) {
			mutex_unlock(&tob_register_lock);
			return PTR_ERR(battery);
		}
		tob_bat = battery;
		bat_changed = false; /* registration already notified */
	} else if (!next.present && tob_bat) {
		power_supply_unregister(tob_bat);
		tob_bat = NULL;
		bat_changed = false;
	}
	if (bat_changed && tob_bat)
		power_supply_changed(tob_bat);
	if (ac_changed && tob_ac)
		power_supply_changed(tob_ac);
	mutex_unlock(&tob_register_lock);
	return count;
}

static DEVICE_ATTR_ADMIN_RW(state);

static int __init tob_init(void)
{
	struct power_supply_config config = {};
	int error;

	tob_pdev = platform_device_register_simple("try-omarchy-battery", -1,
						   NULL, 0);
	if (IS_ERR(tob_pdev))
		return PTR_ERR(tob_pdev);

	error = device_create_file(&tob_pdev->dev, &dev_attr_state);
	if (error)
		goto unregister_pdev;

	tob_ac = power_supply_register(&tob_pdev->dev, &tob_ac_desc, &config);
	if (IS_ERR(tob_ac)) {
		error = PTR_ERR(tob_ac);
		tob_ac = NULL;
		goto remove_file;
	}
	/* BAT0 appears on the first present=1 snapshot; a desktop Mac never
	 * creates it, so the guest bar has nothing to render. */
	return 0;

remove_file:
	device_remove_file(&tob_pdev->dev, &dev_attr_state);
unregister_pdev:
	platform_device_unregister(tob_pdev);
	return error;
}

static void __exit tob_exit(void)
{
	mutex_lock(&tob_register_lock);
	if (tob_bat) {
		power_supply_unregister(tob_bat);
		tob_bat = NULL;
	}
	mutex_unlock(&tob_register_lock);
	power_supply_unregister(tob_ac);
	device_remove_file(&tob_pdev->dev, &dev_attr_state);
	platform_device_unregister(tob_pdev);
}

module_init(tob_init);
module_exit(tob_exit);

MODULE_AUTHOR("Try Omarchy");
MODULE_DESCRIPTION("Mirror the host Mac's battery as guest BAT0/ADP0");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0.0");
```

- [ ] **Step 2: Write the Makefile**

Create `guest/native-module/try-omarchy-battery/Makefile`:

```make
# Standard two-phase kbuild Makefile: DKMS invokes the else-branch with an
# explicit KVER so the build never depends on the builder's running kernel.
ifneq ($(KERNELRELEASE),)
obj-m := try_omarchy_battery.o
try_omarchy_battery-y := try-omarchy-battery.o
else
KVER ?= $(shell uname -r)
KDIR ?= /usr/lib/modules/$(KVER)/build

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
endif
```

Note: `obj-m := try_omarchy_battery.o` with `try_omarchy_battery-y :=
try-omarchy-battery.o` maps the hyphenated source file to the underscored
module name.

- [ ] **Step 3: Write dkms.conf**

Create `guest/native-module/try-omarchy-battery/dkms.conf`:

```sh
PACKAGE_NAME="try-omarchy-battery"
PACKAGE_VERSION="1.0.0"
BUILT_MODULE_NAME[0]="try_omarchy_battery"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
MAKE[0]="make KVER=${kernelver} modules"
CLEAN="make KVER=${kernelver} clean"
```

- [ ] **Step 4: Syntax-sanity-check the C locally**

macOS has no kernel headers, so compile only the parser logic mentally and run
a syntax pass with clang's parser (this catches typos, not kernel API misuse):

Run: `clang -fsyntax-only -std=gnu11 -nostdinc -Wno-implicit-function-declaration -Wno-implicit-int guest/native-module/try-omarchy-battery/try-omarchy-battery.c || true`

Expected: only missing-header errors (`linux/kernel.h` not found) — no brace,
quote, or declaration syntax errors *after* the include failures. The real
compile gate is the image build in Task 3.

- [ ] **Step 5: Commit**

```bash
git add guest/native-module/try-omarchy-battery
git commit -m "Add the try-omarchy-battery DKMS module exposing BAT0 and ADP0"
```

---

### Task 3: Package the module into the factory image

**Files:**
- Create: `guest/scripts/register-native-battery-module.sh`
- Modify: `guest/spec.json` (supplyChain gains `tryOmarchyBattery`)
- Modify: `guest/build.sh` (call the new register script)
- Modify: `guest/scripts/register-local-repository.sh` (archive count 6 → 7, name assertion)

**Interfaces:**
- Consumes: Task 2's `guest/native-module/try-omarchy-battery/` sources.
- Produces: pacman package `try-omarchy-battery-dkms 1.0.0-1` installed in the
  staged root, its archive in `/usr/share/try-omarchy/repo/`, and the built
  `try_omarchy_battery.ko` under `updates/dkms/` — Task 4's modules-load and
  Task 7's retrofit rely on the DKMS name `try-omarchy-battery/1.0.0`.

- [ ] **Step 1: Add the supply-chain pin to guest/spec.json**

In `guest/spec.json`, inside the `"supplyChain"` object, add (alphabetical
placement beside its siblings):

```json
"tryOmarchyBattery": {
  "version": "1.0.0",
  "pkgrel": "1",
  "license": "GPL-2.0-only"
},
```

- [ ] **Step 2: Write the register script**

Create `guest/scripts/register-native-battery-module.sh` (mode 0755). It
follows the argument/validation prologue of `register-pinned-voxtype.sh` and
the reproducible-package tail of `register-patched-hyprland.sh`, minus all
downloading — the source is in-repo:

```bash
#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: register-native-battery-module.sh --root ROOT --work WORK --spec SPEC --pacman-config CONFIG

Packages the in-repo try-omarchy-battery DKMS sources as a reproducible pacman
package, installs it into the staged root (the DKMS transaction hook builds the
module against the pinned kernel), and stages the archive for the guest's
immutable local repository.
USAGE
}

fail() {
  echo "register-native-battery-module: $*" >&2
  exit 1
}

root=""
work=""
spec=""
pacman_config=""

while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --work)
      work=${2:-}
      shift 2
      ;;
    --spec)
      spec=${2:-}
      shift 2
      ;;
    --pacman-config)
      pacman_config=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ $root == /* && -d $root ]] || fail "--root must be an absolute staged root"
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing unsafe root: $root"
    ;;
esac
[[ $work == /* && -d $work ]] || fail "--work must be an absolute directory"
[[ -f $spec ]] || fail "spec not found: $spec"
[[ -f $pacman_config ]] || fail "pacman config not found: $pacman_config"
root=$(cd "$root" && pwd -P)
work=$(cd "$work" && pwd -P)
for command in bsdtar find gzip install pacman python3 sha256sum sort tar touch zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

guest_dir=$(cd "$(dirname "$0")/.." && pwd -P)
module_dir="$guest_dir/native-module/try-omarchy-battery"
for file in try-omarchy-battery.c Makefile dkms.conf; do
  [[ -f $module_dir/$file && ! -L $module_dir/$file ]] ||
    fail "module source is missing or unsafe: $file"
done

mapfile -t metadata < <(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
battery = spec["supplyChain"]["tryOmarchyBattery"]
print(battery["version"])
print(battery["pkgrel"])
print(battery["license"])
print(spec["image"]["sourceDateEpoch"])
PY
)
(( ${#metadata[@]} == 4 )) || fail "could not read the battery module contract"
version=${metadata[0]}
pkgrel=${metadata[1]}
license=${metadata[2]}
source_date_epoch=${metadata[3]}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid module version"
[[ $pkgrel =~ ^[1-9][0-9]*$ ]] || fail "invalid module pkgrel"
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"
grep -q "PACKAGE_VERSION=\"$version\"" "$module_dir/dkms.conf" ||
  fail "dkms.conf version does not match the spec pin"

package_name=try-omarchy-battery-dkms
package_version="$version-$pkgrel"
stage=$(mktemp -d "$work/battery-module.XXXXXX")
package_root="$stage/root"
source_target="usr/src/try-omarchy-battery-$version"
install -d -m 0755 "$package_root/$source_target"
for file in try-omarchy-battery.c Makefile dkms.conf; do
  install -m 0644 "$module_dir/$file" "$package_root/$source_target/$file"
done

installed_size=$(find "$package_root" -type f -exec wc -c {} + | awk 'END {print $1}')
cat >"$package_root/.PKGINFO" <<PKGINFO
pkgname = $package_name
pkgbase = $package_name
xdata = pkgtype=pkg
pkgver = $package_version
pkgdesc = Mirror the host Mac battery as guest BAT0/ADP0 (DKMS)
url = https://github.com/NimbleAINinja/try-omarchy
builddate = $source_date_epoch
packager = Try Omarchy reproducible guest builder
size = $installed_size
arch = aarch64
license = $license
depend = dkms
PKGINFO
chmod 0644 "$package_root/.PKGINFO"

find "$package_root" -exec touch -h -d "@$source_date_epoch" {} +
(
  cd "$package_root"
  LC_ALL=C find . -mindepth 1 ! -name .MTREE -print0 |
    LC_ALL=C sort -z |
    bsdtar -cnf - \
      --format=mtree \
      --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
      --no-recursion \
      --null \
      --files-from - |
    gzip -n -9 >.MTREE
)
chmod 0644 "$package_root/.MTREE"

package_archive="$stage/$package_name-$package_version-aarch64.pkg.tar.zst"
tar \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --format=gnu \
  -C "$package_root" \
  -cf - .PKGINFO .MTREE usr |
  zstd --force --quiet -12 --threads=1 -o "$package_archive"

archive_query=$(pacman --config "$pacman_config" -Qp "$package_archive")
[[ $archive_query == "$package_name $package_version" ]] ||
  fail "battery module package identity mismatch: $archive_query"
pacman \
  --noconfirm \
  --config "$pacman_config" \
  --root "$root" \
  --dbpath "$root/var/lib/pacman" \
  --logfile "$root/var/log/pacman.log" \
  -U "$package_archive"

query=$(pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Q "$package_name")
[[ $query == "$package_name $package_version" ]] ||
  fail "battery module package was not installed: $query"

# The DKMS transaction hook must have produced the module for the pinned
# kernel. An empty glob here means the hook did not run or the compile failed.
built_module=$(find "$root/usr/lib/modules" -path '*/updates/dkms/try_omarchy_battery.ko*' -print -quit)
[[ -n $built_module ]] || fail "DKMS did not build try_omarchy_battery.ko"

repo_dir="$root/usr/share/try-omarchy/repo"
install -d -m 0755 "$repo_dir"
repo_archive="$repo_dir/$(basename "$package_archive")"
[[ ! -L $repo_archive ]] || fail "refusing symlinked immutable repository archive"
install -m 0644 "$package_archive" "$repo_archive"

echo "Registered $query and built $(basename "$built_module")"
```

- [ ] **Step 3: Call it from guest/build.sh**

In `guest/build.sh`, after the `register-pinned-voxtype.sh` invocation and
before `register-local-repository.sh`, add:

```bash
"$guest_dir/scripts/register-native-battery-module.sh" \
  --root "$root" \
  --work "$work" \
  --spec "$spec" \
  --pacman-config "$pacman_config"
```

- [ ] **Step 4: Teach register-local-repository.sh the seventh archive**

In `guest/scripts/register-local-repository.sh`:

1. In the metadata Python block, add after the voxtype lines:
   ```python
   battery = spec["supplyChain"]["tryOmarchyBattery"]
   print(f'{battery["version"]}-{battery["pkgrel"]}')
   ```
2. Change `(( ${#metadata[@]} == 4 ))` to `(( ${#metadata[@]} == 5 ))` and add:
   ```bash
   expected_battery_version=${metadata[4]}
   [[ $expected_battery_version =~ ^[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*$ ]] ||
     fail "invalid battery module package version"
   ```
3. Change `expected_archive_count=6` to `expected_archive_count=7`.
4. Add beside the other name assertions:
   ```bash
   [[ ${archives[*]} == *"/try-omarchy-battery-dkms-$expected_battery_version-aarch64.pkg.tar.zst"* ]] ||
     fail "factory repository is missing the battery DKMS module"
   ```

- [ ] **Step 5: Run the guest test suite**

Run: `./guest/test`
Expected: PASS. (verify.py does not yet know about the battery; its checks
come in Task 4. If any existing verify.py check asserts on `spec.json`'s exact
supplyChain key set or the local-repo script text, fix that check in the same
sweep and note it in the commit.)

- [ ] **Step 6: Build the image to prove the module compiles**

Run: `./guest/build-container.sh` (multi-hour on first run; incremental after).
Expected: build completes; the register script prints
`Registered try-omarchy-battery-dkms 1.0.0-1 and built try_omarchy_battery.ko.zst`.
If the compile fails against kernel 7.2.6, fix `try-omarchy-battery.c` and
re-run — this step is the module's real compiler gate.

- [ ] **Step 7: Commit**

```bash
git add guest/scripts/register-native-battery-module.sh guest/spec.json \
        guest/build.sh guest/scripts/register-local-repository.sh
git commit -m "Build and install the battery DKMS module in the factory image"
```

---

### Task 4: Guest system integration (unit, udev, modules-load, UPower, verify.py)

**Files:**
- Create: `guest/native-overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service`
- Create: `guest/native-overlay/etc/udev/rules.d/95-omarchy-native-battery.rules`
- Create: `guest/native-overlay/etc/modules-load.d/95-try-omarchy-battery.conf`
- Create: `guest/native-overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf`
- Modify: `guest/scripts/configure-rootfs.sh` (chmod list)
- Modify: `guest/scripts/finalize-rootfs.sh` (enable the unit)
- Modify: `guest/tests/verify.py` (battery contract checks)

**Interfaces:**
- Consumes: Task 1's agent path `/usr/local/bin/omarchy-native-battery-bridge`;
  Task 2's module name `try_omarchy_battery`.
- Produces: an enabled system service and root-only port that Task 6's host
  wiring talks to.

- [ ] **Step 1: Write the failing verify.py checks**

In `guest/tests/verify.py`, directly after the camera-bridge block that ends
with the `93-omarchy-native-authentication.rules` checks (near line 1296), add:

```python
    battery_bridge = GUEST / "native-overlay/usr/local/bin/omarchy-native-battery-bridge"
    check(battery_bridge.stat().st_mode & stat.S_IXUSR != 0, "native battery bridge is executable")
    with tempfile.TemporaryDirectory() as temporary:
        py_compile.compile(str(battery_bridge), cfile=str(Path(temporary) / "battery.pyc"), doraise=True)
    check(True, "native battery bridge compiles")
    battery_unit = read(
        GUEST / "native-overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service"
    )
    check(
        "ConditionPathExists=/dev/virtio-ports/dev.tryomarchy.battery" in battery_unit
        and "Restart=always" in battery_unit
        and "StartLimitIntervalSec=0" in battery_unit,
        "battery agent follows the virtio port and keeps retrying",
    )
    battery_rule = read(GUEST / "native-overlay/etc/udev/rules.d/95-omarchy-native-battery.rules")
    check(
        'ATTR{name}=="dev.tryomarchy.battery"' in battery_rule
        and 'MODE="0600"' in battery_rule
        and "GROUP=" not in battery_rule,
        "battery port is root-only",
    )
    check(
        read(GUEST / "native-overlay/etc/modules-load.d/95-try-omarchy-battery.conf").strip()
        == "try_omarchy_battery",
        "battery module loads at boot",
    )
    upower_dropin = read(GUEST / "native-overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf")
    check(
        "CriticalPowerAction=Ignore" in upower_dropin
        and "AllowRiskyCriticalPowerAction=true" in upower_dropin,
        "critical Mac battery warns without suspending the guest",
    )
    module_source = read(GUEST / "native-module/try-omarchy-battery/try-omarchy-battery.c")
    check(
        '.name = "BAT0"' in module_source
        and '.name = "ADP0"' in module_source
        and "DEVICE_ATTR_ADMIN_RW(state)" in module_source
        and "power_supply_unregister" in module_source,
        "battery module exposes BAT0/ADP0 behind a root-only state attribute",
    )
    check(
        'PACKAGE_VERSION="1.0.0"' in read(GUEST / "native-module/try-omarchy-battery/dkms.conf"),
        "battery module DKMS version matches the spec pin",
    )
    finalize = read(GUEST / "scripts/finalize-rootfs.sh")
    check(
        "systemctl enable omarchy-native-battery-bridge.service" in finalize,
        "battery agent is enabled in the factory image",
    )
    configure = read(GUEST / "scripts/configure-rootfs.sh")
    check(
        "omarchy-native-battery-bridge" in configure,
        "battery agent is made executable during rootfs configuration",
    )
```

(Match the indentation of the surrounding block — these live inside the same
function as the camera checks.)

- [ ] **Step 2: Run verify.py to see the new checks fail**

Run: `python3 guest/tests/verify.py`
Expected: FAIL at "native battery bridge is executable" — wait, Task 1 created
the agent, so the first failure is the missing service unit file.

- [ ] **Step 3: Create the four drop-in files**

`guest/native-overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service`:

```ini
[Unit]
Description=Mirror the macOS battery into Omarchy
ConditionPathExists=/dev/virtio-ports/dev.tryomarchy.battery
# The agent exits non-zero whenever the host bridge disconnects; keep
# retrying for as long as the launcher keeps restarting that bridge.
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/local/bin/omarchy-native-battery-bridge
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

`guest/native-overlay/etc/udev/rules.d/95-omarchy-native-battery.rules`
(root-only like the authentication rule, not group-shared like the clipboard):

```text
SUBSYSTEM=="virtio-ports", ATTR{name}=="dev.tryomarchy.battery", MODE="0600"
```

`guest/native-overlay/etc/modules-load.d/95-try-omarchy-battery.conf`:

```text
try_omarchy_battery
```

`guest/native-overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf`:

```ini
# The Mac's own low-power handling is the only authority. Omarchy shows the
# low/critical warnings but the VM never suspends or powers off on its own.
# upower 1.91.4 classifies Ignore as risky and requires the explicit allow.
[UPower]
AllowRiskyCriticalPowerAction=true
CriticalPowerAction=Ignore
```

- [ ] **Step 4: Wire configure-rootfs.sh and finalize-rootfs.sh**

In `guest/scripts/configure-rootfs.sh`, add to the `chmod 0755` list beside
the other native bridges:

```bash
  "$root/usr/local/bin/omarchy-native-battery-bridge" \
```

In `guest/scripts/finalize-rootfs.sh`, beside
`systemctl enable omarchy-native-mac-share.service`, add:

```bash
systemctl enable omarchy-native-battery-bridge.service
```

- [ ] **Step 5: Run the full guest suite**

Run: `./guest/test`
Expected: PASS including every new battery check.

- [ ] **Step 6: Commit**

```bash
git add guest/native-overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service \
        guest/native-overlay/etc/udev/rules.d/95-omarchy-native-battery.rules \
        guest/native-overlay/etc/modules-load.d/95-try-omarchy-battery.conf \
        guest/native-overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf \
        guest/scripts/configure-rootfs.sh guest/scripts/finalize-rootfs.sh \
        guest/tests/verify.py
git commit -m "Enable the battery agent, root-only port, and warn-only UPower policy"
```

---

### Task 5: Host Swift bridge `NativeBatteryBridge`

**Files:**
- Create: `macos/Sources/OmarchyVMHelper/NativeBatteryBridge.swift`
- Modify: `macos/Sources/OmarchyVMHelper/main.swift` (usage line + `--bridge-native-battery` arm)
- Test: `macos/Tests/OmarchyVMHelperTests/BatteryBridgeTests.swift`

**Interfaces:**
- Consumes: existing helpers `NativeBridgeSocket.connectSecure(path:label:)`,
  `NativeBridgeSocket.writeAll(_:to:label:)`, `KernelProcessIdentity.capture(processIdentifier:)`,
  `HelperError.io(_:)` — all already in the target.
- Produces: CLI `omarchy-vm-helper --bridge-native-battery QEMU_PID SOCKET`
  used by Task 6. Testable types `HostBatterySnapshot` (non-failable
  `init(descriptions:)` and `encode()`) and `BatterySendPolicy`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/OmarchyVMHelperTests/BatteryBridgeTests.swift`:

```swift
import Foundation
import Testing

@testable import OmarchyVMHelper

@Suite struct HostBatterySnapshotTests {
    private func description(
        percent: Int = 57,
        max: Int = 100,
        state: String = "Battery Power",
        charging: Bool = false,
        charged: Bool = false,
        toEmptyMinutes: Int = 135,
        toFullMinutes: Int = -1
    ) -> [String: Any] {
        [
            "Type": "InternalBattery",
            "Is Present": true,
            "Current Capacity": percent,
            "Max Capacity": max,
            "Power Source State": state,
            "Is Charging": charging,
            "Is Charged": charged,
            "Time to Empty": toEmptyMinutes,
            "Time to Full Charge": toFullMinutes,
        ]
    }

    @Test func dischargingSnapshotEncodesTheWireContract() throws {
        let snapshot = HostBatterySnapshot(descriptions: [description()])
        #expect(snapshot.present)
        #expect(snapshot.percentage == 57)
        #expect(snapshot.state == "discharging")
        #expect(!snapshot.acConnected)
        #expect(snapshot.timeToEmptySeconds == 135 * 60)
        #expect(snapshot.timeToFullSeconds == nil)
        let line = String(data: snapshot.encode(), encoding: .utf8)!
        #expect(line.hasSuffix("\n"))
        let object = try JSONSerialization.jsonObject(
            with: snapshot.encode()) as! [String: Any]
        #expect(object["type"] as? String == "state")
        #expect(object["percentage"] as? Int == 57)
        #expect(object["timeToFullSeconds"] is NSNull)
    }

    @Test func chargingAndChargedMapToTheProtocolTokens() {
        let charging = HostBatterySnapshot(descriptions: [
            description(state: "AC Power", charging: true, toEmptyMinutes: -1, toFullMinutes: 45)
        ])
        #expect(charging.state == "charging")
        #expect(charging.acConnected)
        #expect(charging.timeToFullSeconds == 45 * 60)
        let full = HostBatterySnapshot(descriptions: [
            description(percent: 100, state: "AC Power", charged: true, toEmptyMinutes: -1)
        ])
        #expect(full.state == "full")
        let idle = HostBatterySnapshot(descriptions: [
            description(state: "AC Power", toEmptyMinutes: -1)
        ])
        #expect(idle.state == "not-charging")
    }

    @Test func desktopMacReportsNoBatteryOnMains() {
        let snapshot = HostBatterySnapshot(descriptions: [])
        #expect(!snapshot.present)
        #expect(snapshot.percentage == nil)
        #expect(snapshot.acConnected)
        #expect(snapshot.state == "unknown")
    }

    @Test func percentageIsScaledByMaxCapacity() {
        let snapshot = HostBatterySnapshot(descriptions: [
            description(percent: 40, max: 80)
        ])
        #expect(snapshot.percentage == 50)
    }
}

@Suite struct BatterySendPolicyTests {
    @Test func duplicateSnapshotsAreCoalescedUntilForced() {
        var policy = BatterySendPolicy()
        let snapshot = HostBatterySnapshot(descriptions: [])
        #expect(policy.shouldSend(snapshot, forced: false))
        policy.markSent(snapshot)
        #expect(!policy.shouldSend(snapshot, forced: false))
        #expect(policy.shouldSend(snapshot, forced: true))
    }

    @Test func changedSnapshotAlwaysSends() {
        var policy = BatterySendPolicy()
        let mains = HostBatterySnapshot(descriptions: [])
        policy.markSent(mains)
        let battery = HostBatterySnapshot(descriptions: [[
            "Type": "InternalBattery",
            "Is Present": true,
            "Current Capacity": 12,
            "Max Capacity": 100,
            "Power Source State": "Battery Power",
            "Is Charging": false,
            "Is Charged": false,
            "Time to Empty": -1,
            "Time to Full Charge": -1,
        ]])
        #expect(policy.shouldSend(battery, forced: false))
    }
}

@Suite struct BatteryGuestRequestTests {
    @Test func refreshLineIsRecognizedAndOthersAreIgnored() {
        #expect(NativeBatteryBridge.isRefreshRequest(Data(#"{"type":"refresh"}"#.utf8)))
        #expect(!NativeBatteryBridge.isRefreshRequest(Data(#"{"type":"state"}"#.utf8)))
        #expect(!NativeBatteryBridge.isRefreshRequest(Data("garbage".utf8)))
    }
}
```

- [ ] **Step 2: Run the Swift tests to verify they fail**

Run: `cd macos && swift test --disable-sandbox --filter Battery`
Expected: FAIL — `HostBatterySnapshot` does not exist.

- [ ] **Step 3: Write the bridge**

Create `macos/Sources/OmarchyVMHelper/NativeBatteryBridge.swift`:

```swift
import Darwin
import Foundation
import IOKit.ps

/// One complete host power snapshot, the only message the guest receives.
/// Built from IOPSGetPowerSourceDescription dictionaries so the IOKit-free
/// tests can drive every branch.
struct HostBatterySnapshot: Equatable {
    let present: Bool
    let percentage: Int?
    let state: String
    let acConnected: Bool
    let timeToEmptySeconds: Int?
    let timeToFullSeconds: Int?

    init(descriptions: [[String: Any]]) {
        let internalBattery = descriptions.first { description in
            description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                && description[kIOPSIsPresentKey] as? Bool != false
        }
        guard let battery = internalBattery else {
            present = false
            percentage = nil
            state = "unknown"
            acConnected = true
            timeToEmptySeconds = nil
            timeToFullSeconds = nil
            return
        }
        present = true
        let current = battery[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = battery[kIOPSMaxCapacityKey] as? Int ?? 100
        percentage = maximum > 0 ? min(100, max(0, current * 100 / maximum)) : 0
        let onMains = battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        acConnected = onMains
        if battery[kIOPSIsChargingKey] as? Bool == true {
            state = "charging"
        } else if battery[kIOPSIsChargedKey] as? Bool == true {
            state = "full"
        } else if onMains {
            state = "not-charging"
        } else {
            state = "discharging"
        }
        func seconds(_ key: String) -> Int? {
            guard let minutes = battery[key] as? Int, minutes >= 0 else { return nil }
            return minutes * 60
        }
        timeToEmptySeconds = state == "discharging" ? seconds(kIOPSTimeToEmptyKey) : nil
        timeToFullSeconds = state == "charging" ? seconds(kIOPSTimeToFullChargeKey) : nil
    }

    func encode() -> Data {
        let object: [String: Any] = [
            "type": "state",
            "present": present,
            "percentage": percentage as Any? ?? NSNull(),
            "state": state,
            "acConnected": acConnected,
            "timeToEmptySeconds": timeToEmptySeconds as Any? ?? NSNull(),
            "timeToFullSeconds": timeToFullSeconds as Any? ?? NSNull(),
        ]
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    static func capture() -> HostBatterySnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return HostBatterySnapshot(descriptions: [])
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return HostBatterySnapshot(descriptions: descriptions)
    }
}

/// Dedupe by value so an IOKit notification burst cannot spam the port; a
/// forced send (guest refresh, 30-second heartbeat) always goes through.
struct BatterySendPolicy {
    private var lastSent: HostBatterySnapshot?

    func shouldSend(_ snapshot: HostBatterySnapshot, forced: Bool) -> Bool {
        forced || snapshot != lastSent
    }

    mutating func markSent(_ snapshot: HostBatterySnapshot) {
        lastSent = snapshot
    }
}

final class NativeBatteryBridge: @unchecked Sendable {
    static let heartbeatSeconds = 30.0

    private let descriptor: Int32
    private let stateQueue = DispatchQueue(label: "dev.tryomarchy.native.battery-bridge-state")
    private let stopLock = NSLock()
    private var policy = BatterySendPolicy()
    private var heartbeat: DispatchSourceTimer?
    private var powerSource: CFRunLoopSource?
    private var stopped = false

    init(targetPID: pid_t, socketPath: String) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("native battery bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "battery bridge")
    }

    deinit {
        stop()
    }

    static func isRefreshRequest(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return false
        }
        return object["type"] as? String == "refresh"
    }

    func run() throws {
        startPowerNotifications()
        startHeartbeat()
        send(forced: true)
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                var start = 0
                for index in 0..<count where chunk[index] == 0x0A {
                    line.append(contentsOf: chunk[start..<index])
                    // The refresh request is the only guest input; anything
                    // else is ignored so the guest cannot drive this bridge.
                    if Self.isRefreshRequest(line) {
                        send(forced: true)
                    }
                    line.removeAll(keepingCapacity: true)
                    start = index + 1
                }
                line.append(contentsOf: chunk[start..<count])
                guard line.count <= 4096 else {
                    throw HelperError.io("guest battery request exceeds 4 KiB")
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest battery channel")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()
        heartbeat?.cancel()
        heartbeat = nil
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = nil
        }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func hasStopped() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private func startPowerNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let bridge = Unmanaged<NativeBatteryBridge>.fromOpaque(context).takeUnretainedValue()
            bridge.send(forced: false)
        }, context)?.takeRetainedValue() else {
            fputs("[battery-bridge] IOKit power notifications are unavailable; relying on the heartbeat\n", stderr)
            return
        }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        // run() blocks this thread on the socket; service the notification
        // source on the main run loop from a dedicated thread.
        Thread.detachNewThread {
            while !self.hasStopped() {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(
            deadline: .now() + Self.heartbeatSeconds,
            repeating: Self.heartbeatSeconds,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.send(forced: true)
        }
        timer.resume()
        heartbeat = timer
    }

    private func send(forced: Bool) {
        stateQueue.async { [weak self] in
            guard let self, !self.hasStopped() else { return }
            let snapshot = HostBatterySnapshot.capture()
            guard self.policy.shouldSend(snapshot, forced: forced) else { return }
            do {
                try NativeBridgeSocket.writeAll(snapshot.encode(), to: self.descriptor, label: "battery")
                self.policy.markSent(snapshot)
            } catch {
                fputs("[battery-bridge] \(error.localizedDescription)\n", stderr)
                self.stop()
            }
        }
    }
}
```

Note for the implementer: `send(forced:)` runs on `stateQueue` for every
caller (notification thread, heartbeat, socket thread), so `policy` needs no
extra lock. If `CFRunLoopGetMain()` proves unserviced under `--run-qemu`'s
child-process invocation, run the notification source on the detached thread's
own run loop (`CFRunLoopGetCurrent()` inside the thread, adding the source
there) — the tests do not depend on which loop carries it.

- [ ] **Step 4: Add the CLI arm to main.swift**

In `macos/Sources/OmarchyVMHelper/main.swift`:

1. Extend the usage string: after `--bridge-native-camera QEMU_PID SOCKET`,
   add ` | --bridge-native-battery QEMU_PID SOCKET`.
2. After the `--bridge-native-camera` block, add:

```swift
    if arguments.first == "--bridge-native-battery" {
        guard arguments.count == 3,
              let processIdentifier = Int32(arguments[1]),
              processIdentifier > 1 else { usage() }
        let bridge = try NativeBatteryBridge(
            targetPID: processIdentifier,
            socketPath: arguments[2]
        )
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler { bridge.stop() }
            source.resume()
            terminationSignalSources.append(source)
        }
        fputs("[battery-bridge] The Mac battery is mirrored inside Omarchy.\n", stderr)
        try bridge.run()
        exit(0)
    }
```

- [ ] **Step 5: Run the Swift tests**

Run: `cd macos && swift test --disable-sandbox --filter Battery`
Expected: PASS.

- [ ] **Step 6: Run the whole Swift suite**

Run: `cd macos && swift test --disable-sandbox`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/OmarchyVMHelper/NativeBatteryBridge.swift \
        macos/Sources/OmarchyVMHelper/main.swift \
        macos/Tests/OmarchyVMHelperTests/BatteryBridgeTests.swift
git commit -m "Add the host battery bridge fed by IOKit power notifications"
```

---

### Task 6: Launcher wiring and contract tests

**Files:**
- Modify: `macos/run-qemu-gpu.sh` (socket, chardev/device, contract dict, dry-run line, gate, start/restart/cleanup)
- Modify: `guest/spec.json` (`runtime.battery` contract)
- Modify: `macos/Tests/run-qemu-ssh-contract.test.sh` (stub arm + assertions)
- Modify: `guest/tests/verify.py` (runtime contract + launcher checks)

**Interfaces:**
- Consumes: Task 5's `--bridge-native-battery QEMU_PID SOCKET` CLI.
- Produces: the running channel Task 1's agent reads.

- [ ] **Step 1: Add the failing contract-test assertions**

In `macos/Tests/run-qemu-ssh-contract.test.sh`:

1. In the fake `omarchy-vm-helper` stub (near line 65), extend the bridge list:

```bash
if [[ ${1:-} == --bridge-native-audio \
   || ${1:-} == --bridge-native-authentication \
   || ${1:-} == --bridge-native-clipboard \
   || ${1:-} == --bridge-native-camera \
   || ${1:-} == --bridge-native-battery ]]; then
```

2. Beside the authentication assertions (near line 465), add:

```bash
assert_contains "$disabled_qemu" \
  'socket,id=omarchy-battery-bridge,path='
assert_contains "$disabled_qemu" \
  'virtserialport,bus=omarchy-serial.0,nr=5,chardev=omarchy-battery-bridge,name=dev.tryomarchy.battery'
```

- [ ] **Step 2: Run the contract test to verify it fails**

Run: `./macos/Tests/run-qemu-ssh-contract.test.sh`
Expected: FAIL on the new `assert_contains` (and possibly earlier, hanging on
the readiness gate, once Step 3 is half-applied — apply Step 3 completely
before re-running).

- [ ] **Step 3: Wire run-qemu-gpu.sh**

All additions mirror the camera lines exactly; keep bash 3.2 compatibility.

1. Variable init (near `camera_bridge_pid=""`): add `battery_bridge_pid=""`.
2. Socket paths (near line 1374): add
   `battery_bridge_socket="/tmp/${work_dir##*/}/battery.sock"`.
3. `qemu_args` (after the camera chardev/device pair near line 1565):

```bash
  -chardev "socket,id=omarchy-battery-bridge,path=$battery_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=5,chardev=omarchy-battery-bridge,name=dev.tryomarchy.battery'
```

4. Dry-run block (near line 1600): add

```bash
  printf '\n[qemu-gpu] battery bridge command: %q --bridge-native-battery QEMU_PID %q' \
    "$native_bridge" "$battery_bridge_socket" >&2
```

5. Readiness gate (near line 1631): add `&& -S $battery_bridge_socket` to the
   compound `[[ ... ]]`, and after the camera line add:

```bash
[[ -S $battery_bridge_socket ]] || fail "QEMU did not create its private battery bridge socket"
```

6. Start block (after `start_camera_bridge` near line 1677):

```bash
start_battery_bridge() {
  "$native_bridge" --bridge-native-battery \
    "$qemu_pid" "$battery_bridge_socket" 9>&- &
  battery_bridge_pid=$!
}
start_battery_bridge
battery_bridge_restarts=0
```

7. Supervision loop (after the camera respawn block near line 1772):

```bash
  # Battery mirroring is optional. A failed IOKit backend must not stop the
  # VM; reconnect it so a transient failure can recover in this session.
  if [[ $battery_bridge_pid =~ ^[0-9]+$ ]]; then
    battery_bridge_state=$(ps -p "$battery_bridge_pid" -o state= 2>/dev/null || true)
    if [[ -z $battery_bridge_state || $battery_bridge_state == *Z* ]]; then
      if wait "$battery_bridge_pid"; then
        battery_bridge_status=0
      else
        battery_bridge_status=$?
      fi
      battery_bridge_pid=""
      if (( battery_bridge_restarts < 5 )); then
        battery_bridge_restarts=$((battery_bridge_restarts + 1))
        echo "[qemu-gpu] battery bridge exited (status $battery_bridge_status); restarting ($battery_bridge_restarts/5)" >&2
        sleep 1
        start_battery_bridge
      else
        echo "[qemu-gpu] battery mirroring is unavailable for the rest of this session" >&2
      fi
    fi
  fi
```

8. `cleanup()` (beside the camera entry near line 1113) and the post-QEMU
   teardown (beside `camera_bridge_pid` near the script end): add matching

```bash
  if [[ $battery_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$battery_bridge_pid" 20
  fi
```

(and `battery_bridge_pid=""` after the post-QEMU one).

9. Contract Python block: add `"battery"` to the `exact_keys` runtime set
   (near line 366) and, beside `camera = {`:

```python
battery = {
    "activation": "always-on",
    "device": "virtserialport",
    "direction": "host-to-guest",
    "guestSupplies": ["ADP0", "BAT0"],
    "port": "dev.tryomarchy.battery",
    "protocolVersion": 1,
}
```

then find where `camera` is compared against `runtime["camera"]` in that block
and add the equivalent `runtime.get("battery") == battery` check to the same
condition (`fail(...)` on mismatch).

- [ ] **Step 4: Add the runtime contract to guest/spec.json**

In `guest/spec.json`, inside `"runtime"`, after the `"camera"` object add:

```json
"battery": {
  "activation": "always-on",
  "device": "virtserialport",
  "direction": "host-to-guest",
  "guestSupplies": ["ADP0", "BAT0"],
  "port": "dev.tryomarchy.battery",
  "protocolVersion": 1
},
```

- [ ] **Step 5: Add the failing verify.py contract checks**

In `guest/tests/verify.py`, beside the camera runtime checks (near line 805),
add:

```python
    battery = spec["runtime"]["battery"]
    check(
        battery
        == {
            "activation": "always-on",
            "device": "virtserialport",
            "direction": "host-to-guest",
            "guestSupplies": ["ADP0", "BAT0"],
            "port": "dev.tryomarchy.battery",
            "protocolVersion": 1,
        },
        "battery contract mirrors the Mac battery one way over virtio",
    )
    battery_launcher = read(REPO / "macos/run-qemu-gpu.sh")
    check(
        "virtserialport,bus=omarchy-serial.0,nr=5" in battery_launcher
        and "name=dev.tryomarchy.battery" in battery_launcher
        and "--bridge-native-battery" in battery_launcher
        and "battery_bridge_restarts < 5" in battery_launcher,
        "Mac launcher carries the supervised battery virtio bridge",
    )
```

- [ ] **Step 6: Run everything**

Run: `./macos/Tests/run-qemu-ssh-contract.test.sh && ./guest/test`
Expected: PASS. Then run the full `make test`.
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add macos/run-qemu-gpu.sh guest/spec.json \
        macos/Tests/run-qemu-ssh-contract.test.sh guest/tests/verify.py
git commit -m "Wire the battery bridge into the launcher and build contracts"
```

---

### Task 7: Retrofit script for existing guests

**Files:**
- Create: `guest/scripts/install-battery-into-existing-guest.sh`
- Modify: `guest/tests/verify.py` (retrofit checks)

**Interfaces:**
- Consumes: the eight files from Tasks 1, 2, and 4, staged into one directory.
- Produces: a script run as root **inside** an existing guest.

- [ ] **Step 1: Add the failing verify.py checks**

In `guest/tests/verify.py`, after the Task 4 battery checks, add:

```python
    retrofit = read(GUEST / "scripts/install-battery-into-existing-guest.sh")
    check(
        "dkms install try-omarchy-battery/1.0.0" in retrofit
        and "systemctl enable --now omarchy-native-battery-bridge.service" in retrofit
        and "curl" not in retrofit,
        "existing guests retrofit the battery from staged files, never the network",
    )
```

Run `python3 guest/tests/verify.py` — expected: FAIL (file missing).

- [ ] **Step 2: Write the retrofit script**

Create `guest/scripts/install-battery-into-existing-guest.sh` (mode 0755):

```bash
#!/bin/bash
# Install the host battery integration into an EXISTING Try Omarchy guest.
#
# Run INSIDE the guest as root, against files staged through the shared Mac
# folder (never the network):
#
#   1. On the Mac, copy these repo paths into the shared folder, preserving
#      the layout below.
#   2. In the guest: sudo ~/<folder>/battery-retrofit/install-battery-into-existing-guest.sh
#
# Expected staging layout (--source defaults to this script's directory):
#   native-module/try-omarchy-battery/{try-omarchy-battery.c,Makefile,dkms.conf}
#   native-overlay/usr/local/bin/omarchy-native-battery-bridge
#   native-overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service
#   native-overlay/etc/udev/rules.d/95-omarchy-native-battery.rules
#   native-overlay/etc/modules-load.d/95-try-omarchy-battery.conf
#   native-overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf
#
# A factory reset is never required; the DKMS hook rebuilds the module on
# every guest kernel update from then on.

set -euo pipefail

fail() {
  echo "install-battery: $*" >&2
  exit 1
}

source_dir=$(cd "$(dirname "$0")" && pwd -P)
while (($#)); do
  case "$1" in
    --source)
      source_dir=${2:-}
      shift 2
      ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

(( EUID == 0 )) || fail "run as root (sudo)"
[[ -e /dev/virtio-ports/dev.tryomarchy.battery ]] ||
  fail "no battery port; update the Try Omarchy app on the Mac first"
for command in dkms install modprobe systemctl udevadm; do
  command -v "$command" >/dev/null || fail "$command is required"
done

module_source="$source_dir/native-module/try-omarchy-battery"
overlay="$source_dir/native-overlay"
for file in \
  "$module_source/try-omarchy-battery.c" \
  "$module_source/Makefile" \
  "$module_source/dkms.conf" \
  "$overlay/usr/local/bin/omarchy-native-battery-bridge" \
  "$overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service" \
  "$overlay/etc/udev/rules.d/95-omarchy-native-battery.rules" \
  "$overlay/etc/modules-load.d/95-try-omarchy-battery.conf" \
  "$overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf"; do
  [[ -f $file ]] || fail "staged file is missing: $file"
done

version=1.0.0
install -d -m 0755 "/usr/src/try-omarchy-battery-$version"
for file in try-omarchy-battery.c Makefile dkms.conf; do
  install -m 0644 "$module_source/$file" "/usr/src/try-omarchy-battery-$version/$file"
done
install -m 0755 "$overlay/usr/local/bin/omarchy-native-battery-bridge" \
  /usr/local/bin/omarchy-native-battery-bridge
install -m 0644 "$overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service" \
  /usr/lib/systemd/system/omarchy-native-battery-bridge.service
install -m 0644 "$overlay/etc/udev/rules.d/95-omarchy-native-battery.rules" \
  /etc/udev/rules.d/95-omarchy-native-battery.rules
install -m 0644 "$overlay/etc/modules-load.d/95-try-omarchy-battery.conf" \
  /etc/modules-load.d/95-try-omarchy-battery.conf
install -d -m 0755 /etc/UPower/UPower.conf.d
install -m 0644 "$overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf" \
  /etc/UPower/UPower.conf.d/90-try-omarchy.conf

if ! dkms status "try-omarchy-battery/$version" 2>/dev/null | grep -q installed; then
  dkms install "try-omarchy-battery/$version"
fi
modprobe try_omarchy_battery
udevadm control --reload
udevadm trigger --subsystem-match=virtio-ports
systemctl daemon-reload
systemctl enable --now omarchy-native-battery-bridge.service
systemctl try-restart upower.service 2>/dev/null || true

echo "install-battery: done — the bar battery appears within 30 seconds"
```

- [ ] **Step 3: Lint and test**

Run: `bash -n guest/scripts/install-battery-into-existing-guest.sh && ./guest/test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add guest/scripts/install-battery-into-existing-guest.sh guest/tests/verify.py
git commit -m "Add the battery retrofit script for existing persistent guests"
```

---

### Task 8: Documentation and final verification

**Files:**
- Modify: `docs/architecture.md`
- Create: `docs/host-battery.md`
- Modify: `README.md` (one highlight line)

**Interfaces:**
- Consumes: everything above; no code.

- [ ] **Step 1: architecture.md paragraph**

In `docs/architecture.md`, after the camera paragraph (which ends "...the
launcher can restart the optional bridge without restarting Omarchy."), add:

```markdown
A further virtio-serial port (`dev.tryomarchy.battery`) mirrors the Mac's
battery into the guest. A Swift bridge watches IOKit power sources and sends
complete JSON snapshots — percentage, charge state, AC presence, and time
estimates — on every change and every 30 seconds. A root guest agent writes
each snapshot as one line into a small DKMS `power_supply` module, which
presents `BAT0` and `ADP0` under `/sys/class/power_supply`, so UPower and the
Omarchy bar treat the VM as the laptop it runs on. The guest can only request
a refresh; nothing it sends can change Mac power state. A UPower drop-in keeps
the guest from acting on a critical battery — warnings appear, the Mac decides.
On a Mac with no internal battery the guest sees only mains power and the bar
shows nothing. See [host battery](host-battery.md) for the protocol, the sysfs
contract, and how to retrofit an existing guest without a factory reset.
```

- [ ] **Step 2: Write docs/host-battery.md**

Create `docs/host-battery.md` covering, in this order (source every claim from
the spec at `docs/superpowers/specs/2026-09-15-host-battery-design.md`):

1. **What it does** — real `BAT0`/`ADP0` supplies, zero Omarchy configuration.
2. **Protocol** — the JSON snapshot line (copy the example from the spec), the
   `refresh` request, the 30-second heartbeat, snapshot-not-delta rationale.
3. **Sysfs contract** — the state-line grammar with both examples, whole-line
   rejection, `-1` semantics, the 0600 mode.
4. **Critical battery policy** — both UPower keys and why
   (`Ignore` is risky in upower 1.91.4).
5. **Retrofitting an existing guest** — the staging layout and the exact
   commands, copied from the retrofit script's header comment; note the DKMS
   hook keeps it alive across guest kernel updates; note a factory reset is
   never required.
6. **Failure modes** — reproduce the spec's failure-mode table verbatim.

- [ ] **Step 3: README highlight**

In `README.md`, in the `## Highlights` list, after the camera line, add:

```markdown
- The Mac's battery, charge state, and time estimates mirrored into the Omarchy bar
```

- [ ] **Step 4: Full verification**

Run, from the repo root:

```bash
make test
./guest/test
```

Expected: everything PASSES. Then confirm the dry-run wiring end-to-end:

```bash
OMARCHY_QEMU_GPU_DRY_RUN=1 ./macos/run-qemu-gpu.sh 2>&1 | grep battery
```

Expected: the QEMU command line shows the `omarchy-battery-bridge` chardev and
the `nr=5` virtserialport, and a `battery bridge command:` line is printed.
(If the script requires an app-bundle context for dry runs, run it the same
way the existing contract test does and rely on Task 6's assertions instead.)

- [ ] **Step 5: Commit**

```bash
git add docs/architecture.md docs/host-battery.md README.md
git commit -m "Document the host battery mirror and its retrofit path"
```

---

## Manual validation on Apple Silicon (before merge)

Per the repo's convention for host-integration features:

1. `make test` and `make runtime`, then build and run the app.
2. In the guest: `upower -d` lists `BAT0` with manufacturer Apple, model
   Mac Battery; `cat /sys/class/power_supply/BAT0/capacity` matches the Mac.
3. Unplug the Mac: the bar icon flips to discharging within a few seconds;
   replug: charging. Percentage tracks over time.
4. `sudo cat /sys/devices/platform/try-omarchy-battery/state` shows the last
   snapshot; a non-root read fails.
5. Kill the host bridge process: within seconds `upower -d` shows state
   `unknown`; the launcher restarts the bridge and state recovers.
6. On a desktop Mac (or with the battery bridge suppressed): no battery widget.
7. Retrofit path: stage the eight files into a shared folder on a pre-feature
   guest, run the script, confirm the bar battery appears without a reset.

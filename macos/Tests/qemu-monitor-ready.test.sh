#!/bin/bash

# The launcher's "Ready. QMP:" line is a contract: the helper connects to that
# socket and tears the VM down if the monitor does not answer. QEMU creates the
# socket file early in its initialisation but only accepts connections once its
# main loop runs, with a listen backlog of one, so a client that connects too
# early and gives up leaves every later connect refused until the loop starts.
# Ready must therefore mean "the monitor answered", not "the file exists".

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)
library="$macos_dir/qemu-monitor-ready.sh"
launcher="$macos_dir/run-qemu-gpu.sh"

fail() {
  printf 'qemu-monitor-ready.test: %s\n' "$*" >&2
  exit 1
}

[[ -f $library ]] || fail "missing library: $library"
# shellcheck source=../qemu-monitor-ready.sh
source "$library"
declare -F qemu_wait_for_qmp_monitor >/dev/null || \
  fail 'library must define qemu_wait_for_qmp_monitor'

scratch=$(mktemp -d "${TMPDIR:-/tmp}/qemu-monitor-ready.XXXXXX")
cleanup() {
  [[ -z ${server_pid:-} ]] || kill "$server_pid" 2>/dev/null || true
  [[ -z ${sleeper_pid:-} ]] || kill "$sleeper_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT

# A stand-in for QEMU: binds and listens (backlog 1) immediately, like the
# chardev does during init, but only starts accepting after ACCEPT_DELAY
# seconds, like the main loop. Each accepted client gets a QMP greeting.
fake_qemu() {
  python3 - "$1" "$2" <<'PY' &
import socket, sys, time
path, delay = sys.argv[1], float(sys.argv[2])
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
time.sleep(delay)
while True:
    client, _ = server.accept()
    # A probe that gave up during the delay is still queued here; like QEMU,
    # shrug off the peer having gone away.
    try:
        client.sendall(b'{"QMP": {"version": {}, "capabilities": []}}\r\n')
    except OSError:
        pass
    client.close()
PY
  server_pid=$!
}

# Something with a live pid to stand in for the QEMU process.
sleep 300 &
sleeper_pid=$!

# 1. Slow init: the monitor answers only after 1.5 s. Ready must wait for it.
socket_path="$scratch/slow.sock"
fake_qemu "$socket_path" 1.5
until [[ -S $socket_path ]]; do sleep 0.02; done
start=$(python3 -c 'import time; print(time.monotonic())')
qemu_wait_for_qmp_monitor "$socket_path" "$sleeper_pid" || \
  fail 'a monitor that answers after a slow init must count as ready'
elapsed=$(python3 -c "import time; print(time.monotonic() - $start)")
python3 -c "import sys; sys.exit(0 if $elapsed >= 1.4 else 1)" || \
  fail "ready was declared after ${elapsed}s, before the monitor could answer"
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; unset server_pid

# 2. Fast init: an immediately answering monitor must not be held up.
socket_path="$scratch/fast.sock"
fake_qemu "$socket_path" 0
until [[ -S $socket_path ]]; do sleep 0.02; done
start=$(python3 -c 'import time; print(time.monotonic())')
qemu_wait_for_qmp_monitor "$socket_path" "$sleeper_pid" || \
  fail 'an answering monitor must count as ready'
elapsed=$(python3 -c "import time; print(time.monotonic() - $start)")
python3 -c "import sys; sys.exit(0 if $elapsed < 1.0 else 1)" || \
  fail "an answering monitor took ${elapsed}s to be declared ready"
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; unset server_pid

# 3. QEMU gone: a socket file with no process behind it must fail promptly
#    rather than wait out the whole deadline.
socket_path="$scratch/dead.sock"
python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$socket_path"
kill "$sleeper_pid"; wait "$sleeper_pid" 2>/dev/null || true
dead_pid=$sleeper_pid; unset sleeper_pid
start=$(python3 -c 'import time; print(time.monotonic())')
if qemu_wait_for_qmp_monitor "$socket_path" "$dead_pid" 2>/dev/null; then
  fail 'a monitor whose QEMU has exited must not count as ready'
fi
elapsed=$(python3 -c "import time; print(time.monotonic() - $start)")
python3 -c "import sys; sys.exit(0 if $elapsed < 3.0 else 1)" || \
  fail "a dead QEMU took ${elapsed}s to be reported"

# 4. The launcher must consult the monitor before announcing Ready.
wait_line=$(grep -n 'qemu_wait_for_qmp_monitor "$qmp_socket" "$qemu_pid"' "$launcher" | cut -d: -f1 | head -1)
ready_line=$(grep -n '^echo "\[qemu-gpu\] Ready. QMP: \$qmp_socket" >&2$' "$launcher" | cut -d: -f1 | head -1)
[[ -n $wait_line && -n $ready_line ]] || \
  fail 'launcher must wait for the QMP monitor and print the Ready line'
(( wait_line < ready_line )) || \
  fail 'launcher must wait for the QMP monitor before printing Ready'

echo 'qemu-monitor-ready.test: PASS'

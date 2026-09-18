# Wait until QEMU's QMP monitor actually answers.
#
# QEMU creates its chardev socket files early in initialisation, but the
# monitor only accepts connections once the main loop runs, and the socket
# listens with a backlog of one. A client that connects during that gap and
# gives up leaves its connection queued until QEMU accepts it, so every later
# connect is refused until the main loop starts. Announcing the VM as ready on
# the socket file alone therefore hands the helper a socket it may not be able
# to use for seconds; the helper treats that as a broken monitor and tears the
# VM down. Ready has to mean the monitor answered.
#
# Sourced by run-qemu-gpu.sh; expects `fail` to be defined by the caller.

# qemu_wait_for_qmp_monitor SOCKET QEMU_PID
#
# Returns 0 once a connection to SOCKET receives a QMP greeting. Each probe
# gives the monitor 250 ms to answer and then disconnects; a refused connect
# or a silent monitor is retried after 100 ms. Both outcomes are expected
# while QEMU is still initialising: a probe that gave up may itself occupy the
# backlog, and the main loop drains it as its first act, so the next probe
# gets through. Fails if QEMU exits, or after 60 s so a monitor that never
# answers still fails startup instead of hanging it.
qemu_wait_for_qmp_monitor() {
  local socket_path=$1
  local qemu_pid=$2
  local deadline=$((SECONDS + 60))

  while (( SECONDS < deadline )); do
    if python3 - "$socket_path" <<'PY' 2>/dev/null
import socket
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(0.25)
try:
    client.connect(sys.argv[1])
    greeting = client.recv(4096)
except (OSError, socket.timeout):
    raise SystemExit(1)
finally:
    client.close()
raise SystemExit(0 if greeting.lstrip().startswith(b'{"QMP"') else 1)
PY
    then
      return 0
    fi
    kill -0 "$qemu_pid" 2>/dev/null || {
      echo 'qemu-monitor-ready: QEMU exited before its QMP monitor answered' >&2
      return 1
    }
    sleep 0.1
  done

  echo 'qemu-monitor-ready: the QMP monitor did not answer within 60 seconds' >&2
  return 1
}

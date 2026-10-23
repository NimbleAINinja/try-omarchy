#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../network-helper" && pwd -P)
output=$(mktemp -d /private/tmp/omarchy-network-unit.XXXXXX)
trap 'rm -rf "$output"' EXIT
bash "$root/build.sh" "$output"
/usr/bin/clang -Wall -Wextra -Werror -Wno-deprecated-declarations "$root/payload-check.test.c" -o "$output/payload-check-test"
"$output/payload-check-test"
/usr/bin/clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 "$root/stream.test.c" -o "$output/stream-test"
mkdir -p "$output/Contents/Resources/network" "$output/Contents/MacOS"
cp "$output/socket_vmnet" "$output/omarchy-network-supervisor" "$output/omarchy-network-client" "$output/Contents/Resources/network/"
codesign --force --sign - "$output/Contents/Resources/network/omarchy-network-client"
daemon="$output/Contents/MacOS/omarchy-network-daemon"
OMARCHY_NETWORK_SERVICE_NAME=dev.tryomarchy.test.network \
  bash "$root/build-daemon.sh" "$daemon" "$output/Contents/Resources"
if "$daemon"; then
  echo 'network-helper.test: daemon accepted an unprivileged launch' >&2
  exit 1
fi
refuses() {
  if "$daemon" check 2>/dev/null; then
    echo "network-helper.test: the daemon's check accepted $1" >&2
    exit 1
  fi
}
refuses 'a runtime without the helper beside it'
install -m 0755 /usr/bin/true "$output/Contents/MacOS/omarchy-vm-helper"
[[ $("$daemon" check) == dev.tryomarchy.test.network ]] || {
  echo 'network-helper.test: the daemon did not accept the runtime it was built with' >&2
  exit 1
}
cp "$output/Contents/Resources/network/omarchy-network-client" "$output/client.signed"
codesign --force --sign - --identifier dev.tryomarchy.resigned "$output/Contents/Resources/network/omarchy-network-client"
refuses 'a re-signed client'
cp "$output/client.signed" "$output/Contents/Resources/network/omarchy-network-client"
cp "$output/Contents/Resources/network/socket_vmnet" "$output/server.built"
printf x >>"$output/Contents/Resources/network/socket_vmnet"
refuses 'a changed server'
cp "$output/server.built" "$output/Contents/Resources/network/socket_vmnet"
"$daemon" check >/dev/null
"$output/stream-test"
/usr/bin/clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 -DVERSION='"test"' \
  -framework vmnet "$root/recovery.test.c" "$root/vendor/cli.c" -o "$output/recovery-test"
"$output/recovery-test"
if "$output/omarchy-network-supervisor" run; then
  echo 'network-helper.test: invalid invocation accepted' >&2
  exit 1
fi
echo 'network-helper.test: PASS'

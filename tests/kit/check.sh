#!/bin/bash
#
# Checks a built kit the way an embedding app receives it (docs/vm-kit.md):
# the archive and its digest, the bundle and the signature of every Mach-O in
# it, QEMU starting with its libraries, the manifest, the guest resources, no
# bridged-networking daemon, the launcher's self-check, and the run mode's
# refusals from the kit's own helper. Starts no VM.
#
#   tests/kit/check.sh [KIT_DIR]    (default: dist/kit.noindex, from make kit)
#
# A Developer ID kit must be signed by team KIT_TEAM_ID (default RZC79MPD34)
# and accepted by Gatekeeper; KIT_NOTARIZED=0 skips Gatekeeper for a kit that
# was signed but not notarized. An ad hoc kit skips both.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
output=${1:-"$root/dist/kit.noindex"}
fail() {
  echo "kit-check: $*" >&2
  exit 1
}
[[ -d $output ]] || fail "no kit in $output; run make kit"
output=$(cd "$output" && pwd -P)
kit="$output/Try Omarchy Kit.app"
contents="$kit/Contents"
resources="$contents/Resources"
archive="$output/TryOmarchyKit.zip"
scratch=$(mktemp -d '/private/tmp/omarchy-kit-check.XXXXXX')
trap 'rm -rf "$scratch"' EXIT

for file in "$kit" "$archive" "$archive.sha256" "$output/TryOmarchyKit.json"; do
  [[ -e $file && ! -L $file ]] || fail "missing ${file#"$output/"}"
done

# The archive is what an app downloads: its digest, and the same signed kit.
(cd "$output" && /usr/bin/shasum -a 256 -c TryOmarchyKit.zip.sha256 >/dev/null) || fail "TryOmarchyKit.zip does not match its .sha256"
[[ $(wc -l <"$archive.sha256") -eq 1 ]] || fail "TryOmarchyKit.zip.sha256 must name one file"
ditto -x -k "$archive" "$scratch/unpacked"
[[ -d "$scratch/unpacked/Try Omarchy Kit.app" ]] || fail "the archive does not hold Try Omarchy Kit.app at its top"
diff -rq "$kit" "$scratch/unpacked/Try Omarchy Kit.app" >/dev/null || fail "the archive's kit differs from the built kit"
codesign --verify --deep --strict "$scratch/unpacked/Try Omarchy Kit.app" || fail "the archive's kit has an invalid signature"
codesign --verify --deep --strict "$kit" || fail "the kit has an invalid signature"
signature_options=()
[[ ${KIT_NOTARIZED:-1} != 0 ]] || signature_options=(--signature-only)
python3 "$root/scripts/kit_signature.py" verify ${signature_options[@]+"${signature_options[@]}"} \
  "$scratch/unpacked/Try Omarchy Kit.app" || fail "the archive's kit is not signed as one kit"
"$scratch/unpacked/Try Omarchy Kit.app/Contents/Resources/runtime/bin/Try Omarchy" --version >/dev/null ||
  fail "the archive's QEMU does not start with its libraries"

info() { /usr/bin/plutil -extract "$1" raw -o - "$contents/Info.plist" 2>/dev/null; }
[[ $(info CFBundleIdentifier) == dev.tryomarchy.kit ]] || fail "the kit's bundle identifier is not dev.tryomarchy.kit"
[[ $(info CFBundleExecutable) == omarchy-vm-helper ]] || fail "the kit's executable is not the helper"
[[ $(info LSUIElement) == true && $(info TryOmarchyKitFormat) == 1 ]] || fail "the kit's Info.plist is not a kit's"

python3 "$root/scripts/kit_manifest.py" --root "$root" --check "$resources/kit.json" >/dev/null || fail "kit.json is invalid"
cmp -s "$resources/kit.json" "$output/TryOmarchyKit.json" || fail "TryOmarchyKit.json differs from the kit's kit.json"

# Bridged networking needs the full app's daemon; the kit leaves it out.
[[ ! -e $contents/Library && ! -e $resources/network && ! -e $contents/MacOS/omarchy-network-daemon ]] ||
  fail "the kit carries the bridged-networking daemon"
[[ -z $(find "$kit" -path '*LaunchDaemons*' -print -quit) ]] || fail "the kit carries a launch daemon"
[[ $(ls "$contents/MacOS") == omarchy-vm-helper ]] || fail "the kit's MacOS folder holds more than the helper"

for file in runtime/bin/"Try Omarchy" runtime/bin/zstd scripts/run-qemu-gpu.sh firmware/edk2-aarch64-code.fd \
  guest/factory.json guest/download.json guest/packages.txt guest/SHA256SUMS TryOmarchy.icns; do
  [[ -f $resources/$file && ! -L $resources/$file ]] || fail "the kit has no $file"
done
shopt -s nullglob
packages=("$resources"/guest-packages/*)
shopt -u nullglob
((${#packages[@]} == 1)) && [[ ${packages[0]##*/} =~ ^try-omarchy-[0-9][A-Za-z0-9._+-]*-(aarch64|any)\.pkg\.tar\.zst$ ]] ||
  fail "the kit must carry exactly one try-omarchy package"

# A kit downloads its image: the manifest names the factory's image, and the
# image itself is not in the kit.
python3 -I - "$resources/guest" <<'PY' || fail "the kit's download manifest does not describe its factory"
import json, re, sys
from pathlib import Path
from urllib.parse import urlsplit
guest = Path(sys.argv[1])
factory = json.loads((guest / "factory.json").read_text())
download = json.loads((guest / "download.json").read_text())
digest = re.compile(r"[0-9a-f]{64}")
parts = download["parts"]
assert download["format"] == 1 and download["kind"] == "try-omarchy-factory-download"
assert download["identity"] == factory["disk"]["sha256"]
assert download["image"]["sha256"] == factory["compressed"]["sha256"]
assert 1 <= len(parts) <= 64 and sum(part["bytes"] for part in parts) == download["image"]["bytes"]
def allowed(url):
    url = urlsplit(url)
    return url.scheme == "https" or (url.scheme == "http" and url.hostname in ("127.0.0.1", "localhost"))
assert all(allowed(part["url"]) and digest.fullmatch(part["sha256"]) for part in parts)
assert not (guest / factory["compressed"]["path"]).exists()
PY

# The launcher accepts the factory it describes (as build-kit.sh checks).
expected=$(python3 -I -c 'import json, sys; disk = json.load(open(sys.argv[1]))["disk"]; print(disk["sha256"] + "\t" + str(disk["bytes"]))' "$resources/guest/factory.json")
record=$(OMARCHY_QEMU_GPU_INSPECT_ONLY=1 "$resources/scripts/run-qemu-gpu.sh") || fail "the kit's launcher rejects its factory"
[[ $record == "$expected" ]] || fail "the kit's launcher reports $record, not the factory's $expected"

# The kit's own helper speaks the run-mode protocol and refuses what it
# cannot run before it starts anything. Its input stays open, as an app's
# does: the end of input means shut down.
mkdir -p "$scratch/home"
CFFIXED_USER_HOME="$scratch/home" OMARCHY_QEMU_GPU_STATE_ROOT="$scratch/vm" OMARCHY_VM_RUN_TEST_SKIP_PREFLIGHT=1 \
  python3 -I - "$contents/MacOS/omarchy-vm-helper" <<'PY' || fail "the kit's run mode did not refuse what it cannot run"
import json, subprocess, sys
for line, code, status in [
    ('{"version":1}', "invalid-configuration", 64),
    ('{"version":1,"productName":"Kit Check","bridges":[],"network":"bridged"}', "bridged-network-unavailable", 1),
]:
    helper = subprocess.Popen([sys.argv[1], "--run-vm"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL)
    helper.stdin.write(line.encode() + b"\n")
    helper.stdin.flush()
    events = [json.loads(event) for event in helper.stdout]
    helper.stdin.close()
    helper.wait(timeout=30)
    assert [(event["event"], event.get("code")) for event in events] == [("error", code), ("exited", None)], events
    assert events[-1]["status"] == status == helper.returncode, (events, helper.returncode)
PY
[[ ! -e $scratch/vm ]] || fail "a refused run created the VM folder"

echo "kit-check: PASS ($(python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1])); print(m["version"], "protocol", m["runProtocolVersion"])' "$resources/kit.json"))"

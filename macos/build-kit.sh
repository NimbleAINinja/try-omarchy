#!/bin/bash
#
# Derives the kit from a built app: the bundle another app embeds to run the
# VM through the helper's run mode (docs/installer-trial.md). It is the app
# without its bridged-networking daemon, and it downloads its factory.
#
#   macos/build-kit.sh --app APP --output DIR [--sign-identity IDENTITY]
#
# Writes DIR/Try Omarchy Kit.app, DIR/TryOmarchyKit.zip and its digest,
# DIR/TryOmarchyKit.zip.sha256. The embedding app signs the kit as itself.

set -euo pipefail

fail() {
  echo "build-kit: $*" >&2
  exit 1
}
usage() {
  sed -n '7p' "$0" | sed 's/^# *//' >&2
  exit 64
}

app=''
output=''
sign_identity=-
while (($#)); do
  case $1 in
    --app) (($# >= 2)) || usage; app=$2; shift 2 ;;
    --output) (($# >= 2)) || usage; output=$2; shift 2 ;;
    --sign-identity) (($# >= 2)) || usage; sign_identity=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $app && -n $output ]] || usage
[[ -d $app && ! -L $app ]] || fail "no app at $app"
macos_dir=$(cd "$(dirname "$0")" && pwd -P)
app=$(cd "$app" && pwd -P)
mkdir -p "$output"
output=$(cd "$output" && pwd -P)

kit_name='Try Omarchy Kit.app'
kit="$output/$kit_name"
archive="$output/TryOmarchyKit.zip"
contents="$kit/Contents"
guest="$contents/Resources/guest"

rm -rf "$kit" "$archive" "$archive.sha256"
ditto "$app" "$kit"
rm -rf "$contents/_CodeSignature" "$contents/Library" "$contents/Resources/network" \
  "$contents/MacOS/omarchy-network-daemon"

[[ -f $guest/download.json && ! -L $guest/download.json ]] ||
  fail "the app carries no factory download manifest; build it with --configuration production"
compressed=$(/usr/bin/plutil -extract compressed.path raw -o - "$guest/factory.json")
[[ ! -e $guest/$compressed ]] || fail "the app carries its factory image; a kit downloads it"

python3 - "$contents/Info.plist" <<'PYTHON'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
value = plistlib.loads(path.read_bytes())
value["CFBundleIdentifier"] = "dev.tryomarchy.kit"
value["CFBundleName"] = value["CFBundleDisplayName"] = "Try Omarchy Kit"
value["LSUIElement"] = True
value["TryOmarchyKitFormat"] = 1
path.write_bytes(plistlib.dumps(value))
PYTHON

sign_options=(--force --sign "$sign_identity" --identifier dev.tryomarchy.kit
  --entitlements "$macos_dir/omarchy-vm-helper.entitlements")
[[ $sign_identity == - ]] || sign_options+=(--options runtime --timestamp)
codesign "${sign_options[@]}" "$contents/MacOS/omarchy-vm-helper"
codesign "${sign_options[@]}" "$kit"
codesign --verify --deep --strict "$kit"

# The kit's launcher must accept the factory it describes.
OMARCHY_QEMU_GPU_INSPECT_ONLY=1 "$contents/Resources/scripts/run-qemu-gpu.sh" >/dev/null ||
  fail "the kit's launcher rejects its factory"

(cd "$output" && ditto -c -k --keepParent "$kit_name" "$archive")
digest=$(/usr/bin/shasum -a 256 "$archive" | cut -d' ' -f1)
printf '%s  %s\n' "$digest" "${archive##*/}" >"$archive.sha256"
echo "[kit] Built $archive ($digest)"

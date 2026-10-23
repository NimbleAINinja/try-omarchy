#!/bin/bash
#
# Builds the daemon after its payloads and the client have been signed, and
# pins them: the client's code-signing hash and the payloads' SHA-256. The
# daemon serves the helper beside it, with the payloads in RESOURCES/network.
#
#   build-daemon.sh DAEMON RESOURCES
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd -P)
daemon=${1:?daemon path required}
resources=${2:?resources directory required}
header_dir=$(mktemp -d /private/tmp/omarchy-network-build.XXXXXX)
trap 'rm -rf "$header_dir"' EXIT
mkdir -p "$(dirname "$daemon")"
python3 - "$daemon" "$resources" "$header_dir/network-build.h" <<'PY'
import hashlib,json,os,re,subprocess,sys
from pathlib import Path
daemon,resources=Path(sys.argv[1]).resolve(),Path(sys.argv[2]).resolve()
service=os.environ.get("OMARCHY_NETWORK_SERVICE_NAME", "dev.tryomarchy.network")
if not re.fullmatch(r"[A-Za-z0-9]+(?:[.][A-Za-z0-9-]+)+", service): raise SystemExit("Invalid networking service name")
location=os.path.relpath(resources,daemon.parent)
if not re.fullmatch(r"[A-Za-z0-9 ._/-]+", location): raise SystemExit("Invalid networking resources location")
values={"NETWORK_SERVICE_NAME": service, "NETWORK_RESOURCES": location}
for key,path in [('CLIENT_REQUIREMENT',resources/'network/omarchy-network-client')]:
    output=subprocess.run(['codesign','-d','--verbose=4',str(path)],check=True,capture_output=True,text=True).stderr
    value=re.search(r'^CDHash=([0-9a-f]{40})$',output,re.M)
    if not value: raise SystemExit('Missing signed helper identity')
    values[key]='cdhash H"'+value[1]+'"'
for key,name in [('SERVER_SHA256','socket_vmnet'),('SUPERVISOR_SHA256','omarchy-network-supervisor')]:
    values[key]=hashlib.sha256((resources/'network'/name).read_bytes()).hexdigest()
Path(sys.argv[3]).write_text(''.join('#define '+key+' '+json.dumps(value)+'\n' for key,value in values.items()))
PY
/usr/bin/clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations -fblocks -mmacosx-version-min=15.0 \
  -I "$header_dir" -framework CoreFoundation -framework Security -framework SystemConfiguration \
  "$root/daemon.c" -o "$daemon"

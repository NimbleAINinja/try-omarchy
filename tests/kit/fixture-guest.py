#!/usr/bin/env python3
"""Write a stand-in for dist/guest, so CI can build the app and the kit on macOS.

The factory needs privileged ARM64 Docker and is 3 GB, and a kit carries only
the image's download manifest. This writes the files build-app.sh reads, with
a small placeholder image, and a placeholder try-omarchy package named the way
guest/package/build.sh names the real one. Nothing here boots.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
IMAGE = "omarchy-aarch64-edge.img"


def package_name() -> str:
    pkgbuild = (ROOT / "guest/package/try-omarchy/PKGBUILD").read_text(encoding="utf-8")
    fields = {key: re.search(rf"^{key}=\(?'?([A-Za-z0-9._+-]+)", pkgbuild, re.M) for key in ("pkgver", "pkgrel", "arch")}
    if not all(fields.values()):
        raise ValueError("cannot read the package version from guest/package/try-omarchy/PKGBUILD")
    return "try-omarchy-{pkgver}-{pkgrel}-{arch}.pkg.tar.zst".format(**{key: match[1] for key, match in fields.items()})


def write(output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    compressed = output / f"{IMAGE}.zst"
    compressed.write_bytes(hashlib.sha256(b"fixture factory").digest() * 32768)
    factory = {
        "format": 1,
        "kind": "upstream-shell-factory",
        "platform": "aarch64",
        "channel": "edge",
        "boot": "uefi-limine",
        "disk": {"path": IMAGE, "bytes": 21474836480, "sha256": hashlib.sha256(b"fixture disk").hexdigest()},
        "compressed": {"path": compressed.name, "sha256": hashlib.sha256(compressed.read_bytes()).hexdigest()},
    }
    (output / "factory.json").write_text(json.dumps(factory, indent=2) + "\n")
    package = package_name()
    (output / "packages.txt").write_text("try-omarchy " + package.removeprefix("try-omarchy-").rsplit("-", 1)[0] + "\n")
    names = [compressed.name, "factory.json", "packages.txt"]
    (output / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}\n" for name in names))
    packages = output / "packages"
    packages.mkdir(exist_ok=True)
    for stale in packages.glob("try-omarchy-*.pkg.tar.zst"):
        stale.unlink()
    (packages / package).write_bytes(b"fixture package\n")
    print(f"[fixture] {output}: {compressed.name}, {package}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    write(parser.parse_args().output)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"fixture-guest: {error}", file=sys.stderr)
        raise SystemExit(1)

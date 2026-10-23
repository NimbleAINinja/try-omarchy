#!/usr/bin/env python3
"""Sign the kit's code inside out, check its signatures, and notarize its archive.

  kit_signature.py sign [--pinned] --identity IDENTITY KIT
  kit_signature.py verify [--team TEAM] [--signature-only] KIT
  kit_signature.py notarize --profile PROFILE ARCHIVE
  kit_signature.py staple KIT

Every Mach-O in the kit is signed as dev.tryomarchy.kit: libraries first, then
the other tools, then QEMU with the hypervisor and microphone, then the helper
with the camera and microphone. A Developer ID signature carries the hardened
runtime and a secure timestamp. An ad hoc signature carries neither, because
the hardened runtime refuses libraries that have no team.

The networking daemon pins the bytes of its server and supervisor and the
signature of its client when it is built. So `sign --pinned` signs those three
before the daemon is built, and `sign` signs everything else and never them.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "dev.tryomarchy.kit"
TEAM = "RZC79MPD34"
QEMU_ENTITLEMENTS = ROOT / "macos/qemu-hvf.entitlements"
HELPER_ENTITLEMENTS = ROOT / "macos/omarchy-vm-helper.entitlements"
NETWORK_SERVICE = "dev.tryomarchy.kit.network"
THIN = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"}
FAT = {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
LIBRARY_TYPES = {6, 8}
RUNTIME = re.compile(r"flags=0x[0-9a-f]+\([^)]*runtime")


@dataclass(frozen=True)
class Layout:
    code: Path
    qemu: Path
    helper: Path
    daemon: Path
    pinned: tuple[Path, ...]
    bundle: Path | None

    def gatekeeper_targets(self) -> list[Path]:
        return [self.bundle] if self.bundle else [self.helper, self.qemu]


def layout(kit: Path) -> Layout:
    """Where the kit's code is: the one place that knows the kit is a bundle.
    A kit of plain helpers has no bundle to seal, verify deeply or staple."""
    contents = kit / "Contents"
    network = contents / "Resources/network"
    return Layout(code=kit, qemu=contents / "Resources/runtime/bin/Try Omarchy",
                  helper=contents / "MacOS/omarchy-vm-helper", daemon=contents / "MacOS/omarchy-network-daemon",
                  pinned=tuple(network / name for name in
                               ("socket_vmnet", "omarchy-network-supervisor", "omarchy-network-client")),
                  bundle=kit)


def macho_type(path: Path) -> int | None:
    with path.open("rb") as source:
        header = source.read(8)
        if header[:4] in THIN:
            source.seek(12)
            return struct.unpack("<I", source.read(4))[0]
        if header[:4] in FAT and struct.unpack(">I", header[4:8])[0] >= 1:
            wide = header[:4] == b"\xca\xfe\xba\xbf"
            source.seek(16)
            offset = struct.unpack(">Q" if wide else ">I", source.read(8 if wide else 4))[0]
            source.seek(offset)
            if source.read(4) in THIN:
                source.seek(offset + 12)
                return struct.unpack("<I", source.read(4))[0]
    return None


def code_files(kit: Layout) -> list[Path]:
    """Every Mach-O under the kit, in signing order: deepest libraries first."""
    found = []
    for directory, _, files in os.walk(kit.code, followlinks=False):
        for name in files:
            path = Path(directory) / name
            if not path.is_symlink() and path.is_file() and (kind := macho_type(path)) is not None:
                found.append((kind, path))

    def rank(item: tuple[int, Path]) -> tuple[int, int, str]:
        kind, path = item
        role = 3 if path == kit.helper else 2 if path == kit.qemu else 0 if kind in LIBRARY_TYPES else 1
        return role, -len(path.parts), str(path)

    return [path for _, path in sorted(found, key=rank)]


def entitlements_for(kit: Layout, path: Path) -> Path | None:
    if path in (kit.helper, kit.bundle):
        return HELPER_ENTITLEMENTS
    return QEMU_ENTITLEMENTS if path == kit.qemu else None


def run(*arguments: str | Path) -> subprocess.CompletedProcess:
    return subprocess.run([str(argument) for argument in arguments], capture_output=True, text=True)


def sign(path: Path, identity: str, pinned: bool = False) -> None:
    kit = layout(path)
    options = ["--force", "--sign", identity, "--identifier", IDENTIFIER]
    if identity != "-":
        options += ["--options", "runtime", "--timestamp"]
    if pinned:
        missing = [code for code in kit.pinned if not code.is_file()]
        if missing:
            raise ValueError(f"the kit has no {missing[0].relative_to(kit.code)}")
        codes = list(kit.pinned)
    else:
        codes = [code for code in code_files(kit) if code not in kit.pinned] + ([kit.bundle] if kit.bundle else [])
    for code in codes:
        entitlements = entitlements_for(kit, code)
        extra = ["--entitlements", str(entitlements)] if entitlements else []
        result = run("codesign", *options, *extra, code)
        if result.returncode != 0:
            raise ValueError(f"cannot sign {code.relative_to(kit.code)}: {result.stderr.strip()}")
    what = "the networking runtime the daemon pins" if pinned else "the kit's code"
    print(f"[kit] Signed {what} as {IDENTIFIER} ({'ad hoc' if identity == '-' else identity})")


def signed_entitlements(path: Path) -> dict | None:
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(path)], capture_output=True)
    if result.returncode != 0:
        return None
    try:
        return plistlib.loads(result.stdout) if result.stdout.strip() else {}
    except (ValueError, plistlib.InvalidFileException):
        return None


def verify(path: Path, team: str, gatekeeper: bool) -> list[str]:
    """Findings about the kit's signatures; none means it is signed as a release or a test kit."""
    kit = layout(path)
    findings: list[str] = []
    files = code_files(kit)
    for required in (kit.helper, kit.qemu, kit.daemon, *kit.pinned):
        if required not in files:
            findings.append(f"the kit has no {required.relative_to(kit.code)}")
    if findings:
        return findings
    adhoc = "Signature=adhoc" in run("codesign", "-dv", "--verbose=4", kit.helper).stderr
    if adhoc:
        print("kit-signature: ad hoc kit: the team, hardened runtime, timestamp and Gatekeeper checks are skipped")
    for code in files:
        where = code.relative_to(kit.code)
        details = run("codesign", "-dv", "--verbose=4", code)
        if details.returncode != 0:
            findings.append(f"{where} is not signed")
            continue
        text = "\n" + details.stderr
        if f"\nIdentifier={IDENTIFIER}\n" not in text:
            findings.append(f"{where} is not signed as {IDENTIFIER}")
        if run("codesign", "--verify", "--strict", code).returncode != 0:
            findings.append(f"{where} has an invalid signature")
        if adhoc:
            if "\nSignature=adhoc\n" not in text:
                findings.append(f"{where} is signed by a team, and the helper ad hoc")
        else:
            if "\nAuthority=Developer ID Application: " not in text:
                findings.append(f"{where} is not signed with a Developer ID Application certificate")
            if f"\nTeamIdentifier={team}\n" not in text:
                signer = re.search(r"\nTeamIdentifier=([^\n]*)", text)
                findings.append(f"{where} is signed by team {signer[1] if signer else 'none'}, not {team}")
            if not RUNTIME.search(text):
                findings.append(f"{where} is not signed with the hardened runtime")
            if "\nTimestamp=" not in text:
                findings.append(f"{where} has no secure timestamp")
        expected = entitlements_for(kit, code)
        if signed_entitlements(code) != (plistlib.loads(expected.read_bytes()) if expected else {}):
            findings.append(f"{where} carries other entitlements than {expected.name if expected else 'none'}")
    if kit.bundle and run("codesign", "--verify", "--deep", "--strict", kit.bundle).returncode != 0:
        findings.append(f"{kit.bundle.name} does not verify (codesign --verify --deep --strict)")
    daemon = run(kit.daemon, "check")
    if daemon.returncode != 0 or daemon.stdout.strip() != NETWORK_SERVICE:
        findings.append(f"{kit.daemon.relative_to(kit.code)} check does not accept its runtime "
                        f"({(daemon.stderr or daemon.stdout).strip() or daemon.returncode})")
    if not adhoc and gatekeeper and not findings:
        for target in kit.gatekeeper_targets():
            assessment = run("spctl", "--assess", "--type", "execute", "-vv", target)
            if assessment.returncode != 0:
                findings.append(f"Gatekeeper rejects {target.name} ({assessment.stderr.strip()}); "
                                "a Developer ID kit is published notarized")
    if not findings:
        mode = "ad hoc" if adhoc else f"team {team}" + ("" if gatekeeper else ", Gatekeeper not checked")
        print(f"kit-signature: {len(files)} Mach-O files signed as {IDENTIFIER} ({mode})")
    return findings


def notarize(archive: Path, profile: str) -> None:
    print(f"[kit] Submitting {archive.name} for notarization", flush=True)
    result = run("xcrun", "notarytool", "submit", archive, "--keychain-profile", profile,
                 "--wait", "--output-format", "json")
    try:
        submission = json.loads(result.stdout)
    except ValueError:
        submission = {}
    if submission.get("status") != "Accepted":
        identifier = submission.get("id", "")
        hint = f"; see xcrun notarytool log {identifier} --keychain-profile {profile}" if identifier else ""
        raise ValueError(f"notarization of {archive.name} ended {submission.get('status') or 'without a status'}"
                         f"{hint}: {result.stderr.strip() or result.stdout.strip()}")
    print(f"[kit] Notarized {archive.name} ({submission.get('id')})")


def staple(path: Path) -> None:
    kit = layout(path)
    if not kit.bundle:
        print("[kit] The kit has no bundle to staple; Gatekeeper finds its ticket online")
        return
    for action in ("staple", "validate"):
        result = run("xcrun", "stapler", action, kit.bundle)
        if result.returncode != 0:
            raise ValueError(f"stapler {action} {kit.bundle.name}: {(result.stderr or result.stdout).strip()}")
    print(f"[kit] Stapled the notarization ticket to {kit.bundle.name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    signing = commands.add_parser("sign")
    signing.add_argument("--pinned", action="store_true", help="only what the networking daemon pins")
    signing.add_argument("--identity", required=True)
    signing.add_argument("kit", type=Path)
    checking = commands.add_parser("verify")
    checking.add_argument("--team", default=os.environ.get("KIT_TEAM_ID") or TEAM)
    checking.add_argument("--signature-only", action="store_true", help="skip Gatekeeper, before notarization")
    checking.add_argument("kit", type=Path)
    notarizing = commands.add_parser("notarize")
    notarizing.add_argument("--profile", required=True)
    notarizing.add_argument("archive", type=Path)
    stapling = commands.add_parser("staple")
    stapling.add_argument("kit", type=Path)
    args = parser.parse_args()
    if args.command == "sign":
        sign(args.kit, args.identity, args.pinned)
    elif args.command == "verify":
        findings = verify(args.kit, args.team, not args.signature_only)
        for finding in findings:
            print(f"kit-signature: {finding}", file=sys.stderr)
        if findings:
            print(f"kit-signature: refused: {len(findings)} finding(s)", file=sys.stderr)
            return 1
    elif args.command == "notarize":
        notarize(args.archive, args.profile)
    else:
        staple(args.kit)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"kit-signature: {error}", file=sys.stderr)
        sys.exit(1)

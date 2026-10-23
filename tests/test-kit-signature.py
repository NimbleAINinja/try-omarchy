#!/usr/bin/env python3
"""Check how scripts/kit_signature.py signs a kit and what its check refuses."""

from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "scripts"))

import kit_signature  # noqa: E402


TEAM = kit_signature.TEAM
OTHER_TEAM = "T2C384FJBD"


class KitSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build = tempfile.TemporaryDirectory(prefix="kit-signature-build-")
        build = Path(cls.build.name)
        (build / "tool.c").write_text("int main(void) { return 0; }\n")
        (build / "library.c").write_text("int fixture(void) { return 1; }\n")
        (build / "daemon.c").write_text(
            '#include <stdio.h>\n#include <stdlib.h>\n'
            'int main(void) { puts(getenv("DAEMON_SERVICE") ? getenv("DAEMON_SERVICE") : "dev.tryomarchy.kit.network");'
            ' return 0; }\n')
        subprocess.run(["cc", "-o", build / "tool", build / "tool.c"], check=True)
        subprocess.run(["cc", "-dynamiclib", "-o", build / "library.dylib", build / "library.c"], check=True)
        subprocess.run(["cc", "-o", build / "daemon", build / "daemon.c"], check=True)
        cls.daemon = build / "daemon"
        cls.tool = build / "tool"
        cls.library = build / "library.dylib"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.build.cleanup()

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="kit-signature-")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.kit = self.work / "TryOmarchyKit.bundle"
        contents = self.kit / "Contents"
        runtime = contents / "Resources/runtime"
        for directory in (contents / "MacOS", runtime / "bin", runtime / "lib", contents / "Resources/network"):
            directory.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "omarchy-vm-helper", "CFBundlePackageType": "BNDL",
        }))
        shutil.copy2(self.tool, contents / "MacOS/omarchy-vm-helper")
        shutil.copy2(self.tool, runtime / "bin/Try Omarchy")
        shutil.copy2(self.tool, runtime / "bin/zstd")
        shutil.copy2(self.library, runtime / "lib/libfixture.dylib")
        shutil.copy2(self.daemon, contents / "MacOS/omarchy-network-daemon")
        for name in ("socket_vmnet", "omarchy-network-supervisor", "omarchy-network-client"):
            shutil.copy2(self.tool, contents / "Resources/network" / name)
        (contents / "Resources/run-qemu-gpu.sh").write_text("#!/bin/sh\n")
        (runtime / "lib/libfixture.1.dylib").symlink_to("libfixture.dylib")
        self.layout = kit_signature.layout(self.kit)
        self.stubs = self.work / "stubs"
        self.stubs.mkdir()
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        path = os.environ["PATH"]
        self.addCleanup(os.environ.__setitem__, "PATH", path)
        os.environ["PATH"] = f"{self.stubs}{os.pathsep}{path}"

    def stub(self, name: str, source: str) -> None:
        stub = self.stubs / name
        stub.write_text(f"#!{sys.executable}\n" + textwrap.dedent(source))
        stub.chmod(0o755)

    def developer_id(self, teams: dict[str, str]) -> None:
        """codesign reporting a Developer ID signature, with the team for each file named in teams."""
        self.stub("codesign", f'''
            import os, sys
            arguments = sys.argv[1:]
            if arguments[:2] != ["-dv", "--verbose=4"]:
                os.execv("/usr/bin/codesign", ["codesign", *arguments])
            path = arguments[-1]
            team = next((team for name, team in {teams!r}.items() if path.endswith(name)), {TEAM!r})
            sys.stderr.write(f"Executable={{path}}\\nIdentifier=dev.tryomarchy.kit\\n"
                             "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1 location=embedded\\n"
                             f"Authority=Developer ID Application: Example ({{team}})\\n"
                             f"Timestamp=23 Oct 2026\\nTeamIdentifier={{team}}\\n")
        ''')

    def test_signs_libraries_then_tools_then_qemu_then_the_helper(self) -> None:
        names = [path.relative_to(self.kit).as_posix() for path in kit_signature.code_files(self.layout)]
        self.assertEqual(names, [
            "Contents/Resources/runtime/lib/libfixture.dylib",
            "Contents/Resources/runtime/bin/zstd",
            "Contents/Resources/network/omarchy-network-client",
            "Contents/Resources/network/omarchy-network-supervisor",
            "Contents/Resources/network/socket_vmnet",
            "Contents/MacOS/omarchy-network-daemon",
            "Contents/Resources/runtime/bin/Try Omarchy",
            "Contents/MacOS/omarchy-vm-helper",
        ])

    def sign_kit(self) -> None:
        kit_signature.sign(self.kit, "-", pinned=True)
        kit_signature.sign(self.kit, "-")

    def test_never_re_signs_what_the_networking_daemon_pins(self) -> None:
        kit_signature.sign(self.kit, "-", pinned=True)
        pinned = {path: path.read_bytes() for path in self.layout.pinned}
        for path in pinned:
            self.assertIn("Identifier=dev.tryomarchy.kit\n", kit_signature.run("codesign", "-dv", path).stderr)
        self.assertNotIn("Identifier=dev.tryomarchy.kit\n", kit_signature.run("codesign", "-dv", self.layout.daemon).stderr)
        kit_signature.sign(self.kit, "-")
        self.assertEqual({path: path.read_bytes() for path in pinned}, pinned)
        self.assertIn("Identifier=dev.tryomarchy.kit\n", kit_signature.run("codesign", "-dv", self.layout.daemon).stderr)

    def test_refuses_a_daemon_that_rejects_its_runtime(self) -> None:
        self.sign_kit()
        self.addCleanup(os.environ.pop, "DAEMON_SERVICE")
        os.environ["DAEMON_SERVICE"] = "dev.tryomarchy.network"
        [finding] = kit_signature.verify(self.kit, TEAM, gatekeeper=False)
        self.assertIn("Contents/MacOS/omarchy-network-daemon check does not accept its runtime", finding)

    def test_an_ad_hoc_kit_passes_with_its_entitlements(self) -> None:
        self.sign_kit()
        self.assertEqual(kit_signature.verify(self.kit, TEAM, gatekeeper=True), [])
        self.assertEqual(kit_signature.signed_entitlements(self.layout.qemu),
                         plistlib.loads(kit_signature.QEMU_ENTITLEMENTS.read_bytes()))
        self.assertEqual(kit_signature.signed_entitlements(self.layout.helper),
                         plistlib.loads(kit_signature.HELPER_ENTITLEMENTS.read_bytes()))

    def test_refuses_an_unsigned_mach_o(self) -> None:
        self.sign_kit()
        library = self.kit / "Contents/Resources/runtime/lib/libfixture.dylib"
        subprocess.run(["codesign", "--remove-signature", library], check=True)
        findings = kit_signature.verify(self.kit, TEAM, gatekeeper=False)
        self.assertIn("Contents/Resources/runtime/lib/libfixture.dylib is not signed", findings)

    def test_refuses_another_identifier_or_other_entitlements(self) -> None:
        self.sign_kit()
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "dev.example.other",
                        self.kit / "Contents/Resources/runtime/bin/zstd"], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "dev.tryomarchy.kit",
                        self.layout.qemu], check=True, capture_output=True)
        findings = kit_signature.verify(self.kit, TEAM, gatekeeper=False)
        self.assertIn("Contents/Resources/runtime/bin/zstd is not signed as dev.tryomarchy.kit", findings)
        self.assertIn("Contents/Resources/runtime/bin/Try Omarchy carries other entitlements than "
                      "qemu-hvf.entitlements", findings)

    def test_refuses_a_mach_o_signed_by_another_team(self) -> None:
        self.sign_kit()
        self.developer_id({"libfixture.dylib": OTHER_TEAM})
        self.assertEqual(kit_signature.verify(self.kit, TEAM, gatekeeper=False), [
            f"Contents/Resources/runtime/lib/libfixture.dylib is signed by team {OTHER_TEAM}, not {TEAM}",
        ])

    def test_refuses_a_team_signed_mach_o_in_an_ad_hoc_kit(self) -> None:
        self.sign_kit()
        self.stub("codesign", '''
            import os, sys
            arguments = sys.argv[1:]
            if arguments[:2] == ["-dv", "--verbose=4"] and arguments[-1].endswith("zstd"):
                sys.stderr.write("Identifier=dev.tryomarchy.kit\\nAuthority=Developer ID Application: X (T2C384FJBD)\\n")
                sys.exit(0)
            os.execv("/usr/bin/codesign", ["codesign", *arguments])
        ''')
        self.assertEqual(kit_signature.verify(self.kit, TEAM, gatekeeper=False), [
            "Contents/Resources/runtime/bin/zstd is signed by a team, and the helper ad hoc",
        ])

    def test_a_developer_id_kit_needs_gatekeeper(self) -> None:
        self.sign_kit()
        self.developer_id({})
        self.stub("spctl", '''
            import sys
            sys.stderr.write(sys.argv[-1] + ": rejected\\nsource=Unnotarized Developer ID\\n")
            sys.exit(3)
        ''')
        self.assertEqual(kit_signature.verify(self.kit, TEAM, gatekeeper=False), [])
        helper, qemu = kit_signature.verify(self.kit, TEAM, gatekeeper=True)
        self.assertIn("Gatekeeper rejects omarchy-vm-helper", helper)
        self.assertIn("Gatekeeper rejects Try Omarchy", qemu)
        self.assertIn("Unnotarized Developer ID", qemu)
        self.stub("spctl", "import sys\nsys.exit(0)\n")
        self.assertEqual(kit_signature.verify(self.kit, TEAM, gatekeeper=True), [])

    def test_notarization_must_be_accepted(self) -> None:
        archive = self.work / "TryOmarchyKit.zip"
        archive.write_bytes(b"zip")
        self.stub("xcrun", '''
            import json, os, sys
            with open(os.environ["XCRUN_LOG"], "a") as log:
                log.write(" ".join(sys.argv[1:]) + "\\n")
            print(json.dumps({"id": "1234", "status": os.environ["NOTARY_STATUS"]}))
        ''')
        log = self.work / "xcrun.log"
        os.environ["XCRUN_LOG"] = str(log)
        self.addCleanup(os.environ.pop, "XCRUN_LOG")
        self.addCleanup(os.environ.pop, "NOTARY_STATUS")
        os.environ["NOTARY_STATUS"] = "Invalid"
        with self.assertRaisesRegex(ValueError, "ended Invalid; see xcrun notarytool log 1234 --keychain-profile p"):
            kit_signature.notarize(archive, "p")
        os.environ["NOTARY_STATUS"] = "Accepted"
        kit_signature.notarize(archive, "p")
        kit_signature.staple(self.kit)
        self.assertEqual(log.read_text().splitlines()[1:], [
            f"notarytool submit {archive} --keychain-profile p --wait --output-format json",
            f"stapler staple {self.kit}",
            f"stapler validate {self.kit}",
        ])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Check and compile the Cocoa product name and icon, without QEMU."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import tempfile
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-product-identity.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"
LAUNCHER = ROOT / "macos/run-qemu-gpu.sh"


def patched() -> str:
    lines = PATCH.read_text(encoding="utf-8").splitlines()
    body = lines[next(i for i, line in enumerate(lines) if line.startswith("@@")):]
    return "\n".join(line[1:] for line in body if line[:1] in (" ", "+"))


def block(text: str, start: str) -> str:
    begin = text.index(start + "\n{")
    return text[begin: text.index("\n}\n", begin) + 3]


def png(width: int, height: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\x00" + b"\x80\x80\x80" * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def icns(width: int) -> bytes:
    image = png(width, width)
    entry = b"icp4" + struct.pack(">I", 8 + len(image)) + image
    return b"icns" + struct.pack(">I", 8 + len(entry)) + entry


class CocoaProductIdentityTests(unittest.TestCase):
    def test_builder_pins_and_applies_the_patch_first_among_cocoa_patches(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        expected = re.search(r"^identity_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected.group(1))
        applied = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$([a-z_]+)"$', builder, re.M)
        self.assertLess(applied.index("identity_patch"), applied.index("display_patch"))

    def test_process_window_and_menus_follow_the_name_the_launcher_passes(self) -> None:
        text = patched()
        for item in ("About", "Hide", "Quit"):
            self.assertIn(f'[@"{item} " stringByAppendingString:cocoa_product_name()]', text)
        self.assertIn("quit %@?\", cocoa_product_name()", text)
        self.assertIn("[[NSProcessInfo processInfo] setProcessName:cocoa_product_name()];\n"
                      "    [QemuApplication sharedApplication];\n    cocoa_set_product_icon();", text)
        self.assertEqual(text.count("Try Omarchy"), 1)
        self.assertIn('-name "guest=${product_name//,/,,}"', LAUNCHER.read_text(encoding="utf-8"))
        self.assertIn("export TRYOMARCHY_PRODUCT_ICON", LAUNCHER.read_text(encoding="utf-8"))

    def test_name_and_icon_compile_and_resolve(self) -> None:
        text = patched()
        name = block(text, "static NSString *cocoa_product_name(void)")
        icon = block(text, "static void cocoa_set_product_icon(void)")
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            source = work / "identity.m"
            source.write_text(
                f"""
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>

static const char *qemu_name;

{name}
{icon}
int main(int argc, char **argv)
{{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    qemu_name = argc > 1 ? argv[1] : NULL;
    [NSApplication sharedApplication];
    NSSize before = [[NSApp applicationIconImage] size];
    cocoa_set_product_icon();
    NSSize after = [[NSApp applicationIconImage] size];
    printf("%s|", [cocoa_product_name() UTF8String]);
    if (NSEqualSizes(after, before)) {{
        printf("unchanged\\n");
    }} else {{
        printf("%.0fx%.0f\\n", after.width, after.height);
    }}
    [pool release];
    return 0;
}}
""",
                encoding="utf-8",
            )
            bundle = work / "Kit.app/Contents/Resources"
            (bundle / "runtime/bin").mkdir(parents=True)
            binary = bundle / "runtime/bin/Try Omarchy"
            compiler = shlex.split(os.environ.get("CC", "cc"))
            subprocess.run(
                compiler + ["-fno-objc-arc", "-Wall", "-Wextra", "-Werror", str(source),
                            "-framework", "AppKit", "-o", str(binary)],
                check=True,
            )
            (bundle / "TryOmarchy.icns").write_bytes(icns(16))
            installer_icon = work / "Installer.png"
            installer_icon.write_bytes(png(24, 12))
            (work / "product").mkdir()
            link = work / "product/Omarchy Installer"
            link.symlink_to(binary)
            environment = {key: value for key, value in os.environ.items() if key != "TRYOMARCHY_PRODUCT_ICON"}

            def run(executable: Path, *arguments: str, icon_path: str | None = None) -> str:
                env = dict(environment)
                if icon_path is not None:
                    env["TRYOMARCHY_PRODUCT_ICON"] = icon_path
                return subprocess.run([str(executable), *arguments], capture_output=True, text=True,
                                      check=True, env=env).stdout.strip()

            self.assertEqual(run(binary), "Try Omarchy|16x16")
            self.assertEqual(run(binary, ""), "Try Omarchy|16x16")
            self.assertEqual(run(link, "Omarchy Installer"), "Omarchy Installer|16x16")
            self.assertEqual(run(link, "Omarchy Installer", icon_path=str(installer_icon)),
                             "Omarchy Installer|24x12")
            self.assertEqual(run(link, "Omarchy Installer", icon_path="Installer.png"), "Omarchy Installer|16x16")
            self.assertEqual(run(binary, icon_path=str(work / "missing.png")), "Try Omarchy|unchanged")


if __name__ == "__main__":
    unittest.main()

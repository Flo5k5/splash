import io
import plistlib
import re
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from dev.tools import package_app

THIN_ARM64 = bytes.fromhex("cffaedfe0c000001")


class PackageAppTests(unittest.TestCase):
    def test_the_app_builds_for_the_minimum_macos_its_bundle_declares(self):
        # LSMinimumSystemVersion is MACOS_MIN_VERSION; the Swift package
        # cannot read the Makefile, so it repeats the version.
        makefile = (package_app.ROOT / "Makefile").read_text()
        version = re.search(r"^MACOS_MIN_VERSION := (\S+)$", makefile, re.M)[1]
        manifest = (package_app.ROOT / "app/Package.swift").read_text()
        self.assertIn(f'platforms: [.macOS("{version}")]', manifest)

    def test_bundle_short_version_is_the_release_versions_x_y_z(self):
        for version, short in (
            ("1.4.1", "1.4.1"),
            ("1.4.1-36-g6e9dfe3f", "1.4.1"),
            ("10.20.300", "10.20.300"),
            ("6e9dfe3f", None),
            ("1.4", None),
            ("v1.4.1", None),
            ("1.4.1.2", None),
            ("1.4.1rc1", None),
            ("1.4.1-", None),
            ("1.4.1-../x", None),
        ):
            with self.subTest(version=version):
                self.assertEqual(package_app.short_version(version), short)

    def test_info_plist_describes_the_bundle_assemble_lays_out(self):
        info = plistlib.loads(
            plistlib.dumps(package_app.info_plist("1.4.1-36-g6e9dfe3f", "1505", "26.4"))
        )
        self.assertEqual(
            info,
            {
                "CFBundleIdentifier": "ai.inco.splash",
                "CFBundleName": "Splash",
                "CFBundleDisplayName": "Splash",
                "CFBundleExecutable": "Splash",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.4.1",
                "CFBundleVersion": "1505",
                "CFBundleIconFile": "AppIcon",
                "CFBundleIconName": "AppIcon",
                "LSMinimumSystemVersion": "26.4",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "NSHighResolutionCapable": True,
                "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
                "NSHumanReadableCopyright": "Copyright © Inco AI",
            },
        )

    def test_mach_o_files_are_found_by_content_not_by_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "python/bin").mkdir(parents=True)
            (root / "engine").mkdir()
            (root / "lib").mkdir()
            binaries = []
            for name, magic in (
                ("python/bin/python3.13", "cffaedfe"),
                ("engine/splash", "cefaedfe"),
                ("lib/big-endian.so", "feedfacf"),
                ("lib/big-endian-32.so", "feedface"),
                ("lib/universal.dylib", "cafebabe"),
                ("lib/universal-64.dylib", "cafebabf"),
            ):
                (root / name).write_bytes(bytes.fromhex(magic) + b"\0" * 28)
                binaries.append(root / name)
            (root / "python/bin/python3").symlink_to("python3.13")
            (root / "python/bin/hf").write_text("#!/usr/bin/env python3\n")
            (root / "lib/module.so.txt").write_text("not a library")
            (root / "lib/short").write_bytes(b"\xcf\xfa")
            (root / "lib/empty").write_bytes(b"")
            (root / "lib/folder.so").mkdir()
            self.assertEqual(package_app.mach_o_files(root), sorted(binaries))

    def compile_icon(self, stdout, written=(), returncode=0):
        """Run compile_icon with actool printing stdout, writing the files
        written and exiting with returncode."""
        with tempfile.TemporaryDirectory() as temporary:
            resources = Path(temporary)

            def actool(command, **options):
                self.assertEqual(options, {"stdout": subprocess.PIPE})
                for name in written:
                    (resources / name).touch()
                return subprocess.CompletedProcess(command, returncode, stdout)

            with mock.patch.object(package_app.subprocess, "run", side_effect=actool):
                package_app.compile_icon(resources, "26.4")

    def test_an_icon_actool_fails_to_compile_stops_the_build(self):
        compiled = {"com.apple.actool.compilation-results": {"output-files": []}}
        # As actool reports a missing .icon, exiting 0 or not.
        failed = {
            **compiled,
            "com.apple.actool.errors": [
                {"description": "Icon export exited with status 255, signal 0"},
                {"description": "Failed to create a catalog"},
            ],
        }
        for returncode in (0, 1):
            with (
                self.subTest(returncode=returncode),
                self.assertRaisesRegex(
                    RuntimeError,
                    "^actool: Icon export exited with status 255, signal 0; "
                    "Failed to create a catalog$",
                ),
            ):
                self.compile_icon(plistlib.dumps(failed), returncode=returncode)
        # Without errors, as when --app-icon does not name the .icon, it must
        # still have written both files.
        for written in ((), ("Assets.car",), ("AppIcon.icns",)):
            with (
                self.subTest(written=written),
                self.assertRaisesRegex(RuntimeError, "actool wrote no "),
            ):
                self.compile_icon(plistlib.dumps(compiled), written)
        self.compile_icon(plistlib.dumps(compiled), ("Assets.car", "AppIcon.icns"))
        # xcrun prints nothing on stdout when it finds no actool.
        with self.assertRaises(subprocess.CalledProcessError):
            self.compile_icon(b"", returncode=72)

    def signing_commands(self, identity):
        """The commands sign runs for a runtime of three Mach-O files, a link
        to one and a script: runtime paths relative to the runtime, the app
        as APP."""
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Splash.app"
            runtime = app / "Contents/Resources/splash"
            for folder in ("python/bin", "python/lib", "engine", "install"):
                (runtime / folder).mkdir(parents=True)
            for name in ("python/bin/python3.13", "python/lib/x.so", "engine/splash"):
                (runtime / name).write_bytes(THIN_ARM64)
            (runtime / "python/bin/python3").symlink_to("python3.13")
            (runtime / "install/launcher.py").write_text("# launcher\n")
            with mock.patch.object(
                package_app.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 0),
            ) as run:
                self.assertEqual(package_app.sign(app, identity), 3)
            return [
                [
                    argument.removeprefix(f"{runtime}/").replace(str(app), "APP")
                    for argument in call.args[0]
                ]
                for call in run.call_args_list
            ]

    def test_ad_hoc_signing_has_no_hardened_runtime_or_timestamp(self):
        adhoc = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
        self.assertEqual(
            self.signing_commands("-"),
            [
                [*adhoc, "--identifier", "ai.inco.splash.engine", "engine/splash"],
                [
                    *adhoc,
                    "--identifier",
                    "ai.inco.splash.python",
                    "python/bin/python3.13",
                ],
                [*adhoc, "python/lib/x.so"],
                [*adhoc, "APP"],
                ["codesign", "--verify", "--strict", "engine/splash"],
                ["codesign", "--verify", "--strict", "python/bin/python3.13"],
                ["codesign", "--verify", "--strict", "python/lib/x.so"],
                ["codesign", "--verify", "--deep", "--strict", "--verbose=2", "APP"],
            ],
        )

    def test_identity_signing_has_hardened_runtime_and_timestamp(self):
        identity = "Developer ID Application: Test (TEAM)"
        signed = ["codesign", "--force", "--sign", identity, "--timestamp"]
        signed += ["--options", "runtime"]
        self.assertEqual(
            self.signing_commands(identity)[:4],
            [
                [*signed, "--identifier", "ai.inco.splash.engine", "engine/splash"],
                [
                    *signed,
                    "--identifier",
                    "ai.inco.splash.python",
                    "python/bin/python3.13",
                ],
                [*signed, "python/lib/x.so"],
                [*signed, "APP"],
            ],
        )

    def test_invalid_arguments_stop_before_the_build(self):
        # Notarization takes a DMG signed with an identity, and the bundle's
        # short version needs the release version's x.y.z.
        for arguments in (
            ["dmg", "--notary-profile", "splash"],
            [
                "app",
                "--sign",
                "Developer ID Application: Test",
                "--notary-profile",
                "splash",
            ],
            ["dmg", "--version", "6e9dfe3f"],
        ):
            with (
                self.subTest(arguments=arguments),
                mock.patch.object(
                    package_app,
                    "build_executable",
                    side_effect=AssertionError("built despite invalid arguments"),
                ),
                redirect_stderr(io.StringIO()),
                self.assertRaises(SystemExit),
            ):
                package_app.main(
                    ["--version", "1.4.1", "--macos-min", "26.4", *arguments]
                )


if __name__ == "__main__":
    unittest.main()

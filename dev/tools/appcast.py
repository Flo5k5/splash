#!/usr/bin/env python3
"""Write dist/appcast.xml, the appcast a release of Splash for Mac carries: it
offers the release's disk image as the update, with the release notes, signed
with the release key."""

import argparse
import base64
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.etree import ElementTree

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from dev.tools import package_app  # noqa: E402

# The release key's item in the login keychain, apart from any other key
# Sparkle's tools keep there.
ACCOUNT = package_app.BUNDLE_ID
# Sparkle's tools, which SwiftPM unpacks with the package app/Package.swift pins.
TOOLS = ROOT / "app/.build/artifacts/sparkle/Sparkle/bin"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
# A release's version, which its tag is: x.y.z, or x.y.z-rc.N for a release
# candidate.
RELEASE_VERSION = re.compile(r"\d+\.\d+\.\d+(-rc\.\d+)?")


def generate(image, notes, version, key_file):
    """Run Sparkle's generate_appcast on image and notes, in a folder of their
    own, and return the appcast it writes: image as the download from the
    release, notes embedded, signed with the private key in key_file or, by
    default, the login keychain's. It reads the versions Sparkle compares, the
    bundle's CFBundleVersion and CFBundleShortVersionString, and the minimum
    macOS, LSMinimumSystemVersion, from the app in image."""
    with tempfile.TemporaryDirectory(prefix=".appcast-", dir=image.parent) as temporary:
        folder = Path(temporary)
        os.link(image, folder / image.name)
        shutil.copyfile(notes, folder / f"{image.stem}.md")
        key = ["--ed-key-file", str(key_file)] if key_file else ["--account", ACCOUNT]
        subprocess.run(
            [str(TOOLS / "generate_appcast"), *key]
            + ["--download-url-prefix", f"{package_app.RELEASES}/download/{version}/"]
            + ["--embed-release-notes"]
            + ["--full-release-notes-url", package_app.RELEASES]
            + ["-o", str(folder / "appcast.xml"), str(folder)],
            check=True,
        )
        return (folder / "appcast.xml").read_bytes()


def check(appcast, image, version, macos_min):
    """Check that appcast offers image alone, as release version's download for
    macOS macos_min or later, signed with the key whose public half every app
    shipped holds. generate_appcast only warns when the key it signs with is
    not the one the app in image holds, and then signs nothing."""
    items = ElementTree.fromstring(appcast).findall("channel/item")
    if len(items) != 1:
        raise RuntimeError(f"the appcast offers {len(items)} updates, not 1")
    item = items[0]
    enclosure = item.find("enclosure")
    expected = {
        "url": f"{package_app.RELEASES}/download/{version}/{image.name}",
        "length": str(image.stat().st_size),
        "shortVersionString": package_app.short_version(version),
        "minimumSystemVersion": macos_min,
    }
    found = {
        "url": enclosure.get("url"),
        "length": enclosure.get("length"),
        "shortVersionString": item.findtext(f"{SPARKLE}shortVersionString"),
        "minimumSystemVersion": item.findtext(f"{SPARKLE}minimumSystemVersion"),
    }
    if found != expected:
        raise RuntimeError(f"the appcast offers {found}, not {expected}")
    key = base64.b64decode(package_app.SPARKLE_PUBLIC_KEY)
    signature = base64.b64decode(enclosure.get(f"{SPARKLE}edSignature", ""))
    try:
        Ed25519PublicKey.from_public_bytes(key).verify(signature, image.read_bytes())
    except InvalidSignature:
        raise RuntimeError(
            f"{image.name} is not signed with the release key whose public half "
            "is SPARKLE_PUBLIC_KEY in dev/tools/package_app.py"
        ) from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--version", required=True, help="the release's version, x.y.z or x.y.z-rc.N"
    )
    parser.add_argument("--macos-min", required=True, help="minimum macOS, e.g. 26.4")
    parser.add_argument(
        "--notes", required=True, type=Path, help="the release notes, in Markdown"
    )
    parser.add_argument(
        "--key-file",
        type=Path,
        help="the release key's private half, as generate_keys -x exports it; "
        "the login keychain's by default",
    )
    args = parser.parse_args(argv)
    if not RELEASE_VERSION.fullmatch(args.version):
        parser.error("release version must be x.y.z or x.y.z-rc.N, e.g. 1.5.0")
    if not package_app.SPARKLE_PUBLIC_KEY:
        parser.error(
            "SPARKLE_PUBLIC_KEY in dev/tools/package_app.py is empty: "
            "apps built without it check for no update"
        )
    image = ROOT / "dist" / f"Splash-{args.version}.dmg"
    if not image.is_file():
        parser.error(f"no disk image to offer: {image}; make dmg builds it")
    # Unpacks Sparkle's tools, unless a build has already.
    subprocess.run(
        ["swift", "package", "resolve", "--package-path", str(ROOT / "app")],
        check=True,
    )
    appcast = generate(image, args.notes, args.version, args.key_file)
    check(appcast, image, args.version, args.macos_min)
    output = ROOT / "dist/appcast.xml"
    output.write_bytes(appcast)
    print(
        f"Wrote {output}. Release {args.version} carries it beside {image.name} "
        "and a copy of it named Splash.dmg."
    )


if __name__ == "__main__":
    main()

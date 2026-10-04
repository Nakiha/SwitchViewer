#!/usr/bin/env python3
"""Write release metadata from one version file, including on incremental builds."""
import json
import plistlib
from pathlib import Path
import platform
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def release_version():
    value = json.loads((ROOT / "Version.json").read_text())
    if not re.fullmatch(r"\d+\.\d+\.\d+", value["version"]) or type(value["build"]) is not int or value["build"] < 1:
        raise ValueError("Version.json requires a semantic version and a positive integer build")
    return value


def output(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def write_metadata(app):
    version = release_version()
    revision = output("git", "rev-parse", "HEAD")
    if output("git", "status", "--porcelain", "--untracked-files=normal"):
        revision += "+dirty"
    contents = app / "Contents"
    plist = {
        "CFBundleExecutable": "SwitchViewer",
        "CFBundleIdentifier": "com.zhu.switchviewer",
        "CFBundleName": "SwitchViewer",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version["version"],
        "CFBundleVersion": str(version["build"]),
        "LSUIElement": True,
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
        "NSCameraUsageDescription": "SwitchViewer 需要访问采集卡画面。",
        "NSMicrophoneUsageDescription": "SwitchViewer 需要访问采集卡音频。",
        "SVSourceRevision": revision,
    }
    with (contents / "Info.plist").open("wb") as destination:
        plistlib.dump(plist, destination)
    metadata = dict(version, revision=revision, sdk=output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
                    xcode=output("xcodebuild", "-version"),
                    architectures=output("lipo", "-archs", str(contents / "MacOS/SwitchViewer")),
                    build_os=platform.mac_ver()[0], signing="ad-hoc", notarized=False)
    (contents / "Resources/BUILD-INFO.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    if sys.argv[1:] == ["--version"]:
        print(release_version()["version"])
    elif len(sys.argv) == 2:
        write_metadata(Path(sys.argv[1]).resolve())
    else:
        raise SystemExit("Usage: write-app-metadata.py [--version | app-path]")

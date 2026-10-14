#!/usr/bin/env python3
"""Package a built native app for safe synthetic UI comparisons and relaunches."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: package-native.py /absolute/synthetic-fixture-root")
fixture_root = Path(sys.argv[1]).resolve(strict=True)
database = fixture_root / "native" / "clipecho.db"
if not (fixture_root / "fixture.json").is_file() or not database.is_file():
    raise SystemExit("Expected a create-fixture.py synthetic fixture root")
source = Path(__file__).resolve().parent.parent / "build" / "ClipEcho Native.app"
if not source.is_dir():
    raise SystemExit("Build the native app before packaging QA")
target = fixture_root / "runtime" / "ClipEcho Native QA.app"
shutil.copytree(source, target, dirs_exist_ok=True)
plist = target / "Contents" / "Info.plist"
info = plistlib.loads(plist.read_bytes())
info["CFBundleIdentifier"] = "com.copy-stack.desktop.native.qa"
info["CFBundleName"] = info["CFBundleDisplayName"] = "ClipEcho Native QA"
info["LSEnvironment"] = {"CLIPECHO_NATIVE_QA_DATABASE": str(database)}
plist.write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
print(target)

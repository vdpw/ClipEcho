#!/usr/bin/env python3
"""Give the separately compiled original QA executable a safe, uniquely named bundle."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
assert json.loads((root / "fixture.json").read_text())["synthetic_only"] is True
repository = Path(__file__).resolve().parents[2]
runtime = root / "runtime"
runtime.mkdir(mode=0o700, exist_ok=True)
subprocess.run(["clang", "-dynamiclib", "-fobjc-arc", "-framework", "AppKit", str(repository / "native-macos/QA/qa-pasteboard.m"), "-o", str(runtime / "qa-pasteboard.dylib")], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(runtime / "qa-pasteboard.dylib")], check=True)
bundle = runtime / "ClipEcho Original QA.app"
(bundle / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
(bundle / "Contents/Resources").mkdir(exist_ok=True)
shutil.copy2(repository / "src-tauri/target/debug/clip_echo", bundle / "Contents/MacOS/clip_echo")
info = {"CFBundleName": "ClipEcho Original QA", "CFBundleDisplayName": "ClipEcho Original QA", "CFBundleIdentifier": "com.copy-stack.desktop.qa", "CFBundleExecutable": "clip_echo", "CFBundlePackageType": "APPL", "CFBundleVersion": "0.4.0", "CFBundleShortVersionString": "0.4.0", "NSHighResolutionCapable": True,
        "LSEnvironment": {"COPY_STACK_QA_DATA_DIR": str(root / "original"), "CLIPECHO_QA_PASTEBOARD_NAME": "com.copy-stack.desktop.qa." + root.name, "DYLD_INSERT_LIBRARIES": str(runtime / "qa-pasteboard.dylib")}}
with (bundle / "Contents/Info.plist").open("wb") as file:
    plistlib.dump(info, file)
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
print(bundle)

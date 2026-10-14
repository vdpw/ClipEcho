#!/bin/bash
set -euo pipefail
qa_scripts="$(cd "$(dirname "$0")" && pwd)"
repository="$(cd "$qa_scripts/../.." && pwd)"
qa_root="${1:?Usage: launch-original.sh /absolute/path/to/generated/fixture/root}"
[[ "$qa_root" = /* && -f "$qa_root/fixture.json" && -f "$qa_root/original/clipecho.db" ]] || { echo 'A generated synthetic fixture root is required.' >&2; exit 2; }
python3 - "$qa_root/fixture.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['synthetic_only'] is True
PY
qa_build="$qa_root/runtime"
mkdir -p "$qa_build"
chmod 700 "$qa_build"
clang -dynamiclib -fobjc-arc -framework AppKit "$qa_scripts/qa-pasteboard.m" -o "$qa_build/qa-pasteboard.dylib"
codesign --force --sign - "$qa_build/qa-pasteboard.dylib"
# Export only the QA process's data directory and named-pasteboard settings.
# The injected library checks these guards before changing NSPasteboard.
cd "$repository"
export COPY_STACK_QA_DATA_DIR="$qa_root/original"
export CLIPECHO_QA_PASTEBOARD_NAME="com.copy-stack.desktop.qa.$(basename "$qa_root")"
export DYLD_INSERT_LIBRARIES="$qa_build/qa-pasteboard.dylib"
exec pnpm tauri dev --config "$qa_scripts/original-tauri.conf.json"

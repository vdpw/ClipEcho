#!/bin/bash
set -euo pipefail

[[ $# -eq 0 ]] || { echo 'Usage: self-test.sh' >&2; exit 2; }
project_root="$(cd "$(dirname "$0")/.." && pwd)"
executable="$project_root/build/ClipEcho.app/Contents/MacOS/ClipEcho"
[[ -x "$executable" ]] || { echo 'Build the app before running its isolated self-test.' >&2; exit 1; }
log="$(mktemp "${TMPDIR:-/tmp}/clipecho-self-test.XXXXXX")"
trap 'rm -f "$log"' EXIT
"$executable" --self-test 2>&1 | tee "$log"
if ! grep -q '^Native self-test passed:' "$log"; then
  echo 'The self-test exited before its final success marker.' >&2
  exit 1
fi

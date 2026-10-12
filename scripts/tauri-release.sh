#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

verify_lockfile() {
  if ! git show HEAD:src-tauri/Cargo.lock | cmp -s - src-tauri/Cargo.lock; then
    echo "Cargo.lock must match HEAD; update dependencies in a reviewed PR." >&2
    exit 1
  fi
}

verify_lockfile
pnpm tauri "$@"
# tauri-action must see this failure before it creates/uploads a release.
verify_lockfile

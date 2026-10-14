#!/bin/bash
set -euo pipefail

[[ $# -eq 0 ]] || { echo 'Usage: prepare-ci-display.sh' >&2; exit 2; }
if [[ "${GITHUB_ACTIONS:-}" != true || "$(uname -s)" != Darwin ]]; then
  echo 'Display preparation is restricted to macOS GitHub Actions runners.' >&2
  exit 2
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_root/scripts/toolchain.sh"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
clipecho_sdk="$(xcrun --sdk macosx --show-sdk-path)"
"$clipecho_swift" -sdk "$clipecho_sdk" -swift-version 6 \
  -module-cache-path "$project_root/.build/module-cache" \
  "$project_root/scripts/prepare-ci-display.swift"

#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$native_root"
source "$native_root/scripts/toolchain.sh"
export CLANG_MODULE_CACHE_PATH="$native_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$native_root/.build/module-cache"
plugin_args=()
# Some SwiftPM distributions omit the Swift Testing macro registration.
if [[ -n "$clipecho_testing_macros" ]]; then
    plugin_args=(-Xswiftc -load-plugin-library -Xswiftc "$clipecho_testing_macros")
fi
"$clipecho_swift" test --disable-sandbox --disable-xctest --enable-swift-testing \
    --cache-path "$native_root/.build/package-cache" --config-path "$native_root/.build/config" --security-path "$native_root/.build/security" \
    -Xswiftc -module-cache-path -Xswiftc "$native_root/.build/module-cache" "${plugin_args[@]}" "$@"

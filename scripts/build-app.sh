#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Usage: build-app.sh [debug|release]' >&2; exit 2 ;; esac
cd "$native_root"
source "$native_root/scripts/toolchain.sh"
# Put caches inside the new project, including on restricted CI hosts.
export CLANG_MODULE_CACHE_PATH="$native_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$native_root/.build/module-cache"
debug_args=()
# Local release packages need no dSYM; retain them on request for a signed release.
if [[ "$configuration" == release && "${CLIPECHO_DEBUG_SYMBOLS:-0}" != 1 ]]; then debug_args=(-debug-info-format none); fi
"$clipecho_swift" build -c "$configuration" "${debug_args[@]}" --disable-sandbox --cache-path "$native_root/.build/package-cache" --config-path "$native_root/.build/config" --security-path "$native_root/.build/security" -Xswiftc -module-cache-path -Xswiftc "$native_root/.build/module-cache"
bin_path="$("$clipecho_swift" build -c "$configuration" --show-bin-path --disable-sandbox --cache-path "$native_root/.build/package-cache" --config-path "$native_root/.build/config" --security-path "$native_root/.build/security")"
app="$native_root/build/ClipEcho.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/ClipEcho" "$app/Contents/MacOS/ClipEcho"
cp "$native_root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$native_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$native_root/Resources/tray-template.png" "$app/Contents/Resources/tray-template.png"
cp "$native_root/Resources/Lucide-LICENSE.txt" "$app/Contents/Resources/Lucide-LICENSE.txt"
codesign --force --sign - "$app"
printf '%s\n' "$app"

#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$native_root"
source "$native_root/scripts/toolchain.sh"
"$native_root/scripts/build-app.sh" debug
open "$native_root/build/ClipEcho.app" --args "$@"

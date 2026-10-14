#!/bin/bash
# Sourced by native scripts. Keep Swift selection local to these processes:
# do not prepend a toolchain directory to PATH or select it globally via xcrun.
# Overrides: CLIPECHO_SWIFT_TOOLCHAIN, CLIPECHO_SWIFT_EXEC,
# CLIPECHO_SWIFTC_EXEC, and CLIPECHO_TESTING_MACROS.

clipecho_executable_path() {
  local candidate="$1"
  if [[ "$candidate" != */* ]]; then
    candidate="$(command -v "$candidate")" || return 1
  fi
  [[ -x "$candidate" && ! -d "$candidate" ]] || return 1
  if [[ "$candidate" != /* ]]; then candidate="$PWD/$candidate"; fi
  printf '%s\n' "$candidate"
}

clipecho_select_toolchain() {
  local selected_toolchain="${CLIPECHO_SWIFT_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain}"
  clipecho_swift="$(clipecho_executable_path "${CLIPECHO_SWIFT_EXEC:-$selected_toolchain/usr/bin/swift}")" || {
    printf '%s\n' 'Install Swift 6.4.1 or set CLIPECHO_SWIFT_TOOLCHAIN / CLIPECHO_SWIFT_EXEC.' >&2
    return 1
  }
  clipecho_swiftc="$(clipecho_executable_path "${CLIPECHO_SWIFTC_EXEC:-$selected_toolchain/usr/bin/swiftc}")" || {
    printf '%s\n' 'Set CLIPECHO_SWIFTC_EXEC to the matching Swift compiler.' >&2
    return 1
  }

  # SwiftPM honors these explicit compiler paths. A scoped selection must not
  # redirect xcrun, clang, or tools used by another language through TOOLCHAINS.
  unset TOOLCHAINS
  export SWIFT_EXEC="$clipecho_swiftc"
  export SWIFT_EXEC_MANIFEST="$clipecho_swiftc"

  # Query the real compiler, including when its entry point is a shell wrapper.
  # macOS plutil parses the JSON; no Python, jq, or third-party helper is needed.
  local runtime_resources
  runtime_resources="$("$clipecho_swiftc" -print-target-info | /usr/bin/plutil -extract paths.runtimeResourcePath raw -o - -)" || {
    printf '%s\n' 'The selected Swift compiler did not provide its runtime resource path.' >&2
    return 1
  }
  clipecho_testing_macros="${CLIPECHO_TESTING_MACROS:-}"
  if [[ -n "$clipecho_testing_macros" ]]; then
    [[ -f "$clipecho_testing_macros" ]] || {
      printf '%s\n' 'CLIPECHO_TESTING_MACROS must identify an existing macro plugin.' >&2
      return 1
    }
  else
    local plugin
    for plugin in "$runtime_resources/host/plugins/testing/libTestingMacros.dylib" "$runtime_resources/host/plugins/libTestingMacros.dylib"; do
      if [[ -f "$plugin" ]]; then clipecho_testing_macros="$plugin"; break; fi
    done
  fi
}

clipecho_select_toolchain

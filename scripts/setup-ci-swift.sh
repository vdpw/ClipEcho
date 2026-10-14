#!/bin/bash
set -euo pipefail

# Install the same official toolchain on both native GitHub macOS runners.
# Selection remains scoped to ClipEcho; never modify PATH or TOOLCHAINS.
swift_version=6.4.1
toolchain="$HOME/Library/Developer/Toolchains/swift-${swift_version}-RELEASE.xctoolchain"
project_root="$(cd "$(dirname "$0")/.." && pwd)"

[[ "$(uname -s)" == Darwin ]] || { echo 'Swift CI setup requires macOS.' >&2; exit 2; }
required_tools="$(sed -n 's|^// swift-tools-version: *||p' "$project_root/Package.swift")"
[[ "$required_tools" == 6.4 ]] || {
  echo 'Update the CI Swift toolchain pin when Package.swift changes its tools version.' >&2
  exit 1
}

if [[ ! -x "$toolchain/usr/bin/swift" || ! -x "$toolchain/usr/bin/swiftc" ]]; then
  download_dir="$(mktemp -d "${TMPDIR:-/tmp}/clipecho-swift.XXXXXX")"
  trap 'rm -rf "$download_dir"' EXIT
  package="$download_dir/swift.pkg"
  url="https://download.swift.org/swift-${swift_version}-release/xcode/swift-${swift_version}-RELEASE/swift-${swift_version}-RELEASE-osx.pkg"
  curl --fail --location --show-error --retry 3 --proto '=https' --tlsv1.2 "$url" -o "$package"
  signature="$(pkgutil --check-signature "$package")"
  printf '%s\n' "$signature"
  [[ "$signature" == *'Developer ID Installer: Swift Open Source (V9AUD2URP3)'* ]] || {
    echo 'The Swift installer does not have the official Swift Open Source signature.' >&2
    exit 1
  }
  installer -pkg "$package" -target CurrentUserHomeDirectory
fi

compiler_version="$("$toolchain/usr/bin/swiftc" --version)"
printf '%s\n' "$compiler_version"
[[ "$compiler_version" =~ Swift[[:space:]]version[[:space:]]6\.4\.1([[:space:]]|$) ]] || {
  echo 'The installed Swift compiler does not match the pinned 6.4.1 release.' >&2
  exit 1
}
xcrun --sdk macosx --show-sdk-path
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'CLIPECHO_SWIFT_TOOLCHAIN=%s\n' "$toolchain" >> "$GITHUB_ENV"
fi
printf 'ClipEcho toolchain: %s\n' "$toolchain"

#!/bin/bash
set -euo pipefail

usage() { echo 'Usage: package-release.sh vMAJOR.MINOR.PATCH[-PRERELEASE] [arm64|x86_64]' >&2; exit 2; }
[[ $# -ge 1 && $# -le 2 ]] || usage
tag="$1"
architecture="${2:-$(uname -m)}"
case "$architecture" in arm64|x86_64) ;; *) usage ;; esac
version_number='(0|[1-9][0-9]*)'
prerelease_identifier='(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
tag_pattern="^v${version_number}\\.${version_number}\\.${version_number}(-${prerelease_identifier}(\\.${prerelease_identifier})*)?$"
[[ "$tag" =~ $tag_pattern ]] || { echo 'Expected a vMAJOR.MINOR.PATCH tag with an optional prerelease suffix.' >&2; exit 2; }

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$project_root/build/ClipEcho.app"
executable="$app/Contents/MacOS/ClipEcho"
plist="$app/Contents/Info.plist"
[[ -x "$executable" && -f "$plist" ]] || { echo 'Build the release app before packaging.' >&2; exit 1; }
[[ "$(lipo -archs "$executable")" == "$architecture" ]] || {
  echo 'The app architecture does not match the requested release architecture.' >&2
  exit 1
}

version="${tag#v}"
bundle_version="${version%%-*}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $bundle_version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $bundle_version" "$plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")" == "$bundle_version" ]] || {
    echo 'The packaged app version does not match the release tag.' >&2
    exit 1
  }
done
plutil -lint "$plist"
# Updating Info.plist invalidates the build signature; sign the final bundle.
codesign --force --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"

output_dir="$project_root/build/release"
mkdir -p "$output_dir"
stem="ClipEcho-${version}-macos-${architecture}"
staging="$(mktemp -d "${TMPDIR:-/tmp}/clipecho-release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/$stem.zip"
ditto -x -k "$output_dir/$stem.zip" "$staging/unpacked"
codesign --verify --deep --strict --verbose=2 "$staging/unpacked/ClipEcho.app"

mkdir -p "$staging/disk"
ditto "$app" "$staging/disk/ClipEcho.app"
ln -s /Applications "$staging/disk/Applications"
hdiutil create -ov -format UDZO -volname "ClipEcho $version" \
  -srcfolder "$staging/disk" "$output_dir/$stem.dmg"
hdiutil verify "$output_dir/$stem.dmg"
(
  cd "$output_dir"
  shasum -a 256 "$stem.zip" "$stem.dmg" > "$stem.sha256"
  shasum -a 256 -c "$stem.sha256"
)
printf '%s\n' "$output_dir/$stem.zip" "$output_dir/$stem.dmg" "$output_dir/$stem.sha256"

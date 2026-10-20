#!/bin/sh
#===----------------------------------------------------------------------===#
#
# This source file is part of MpVFX.
#
# Copyright (c) 2026 Arshiya Rahgozar.
#
# Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
# http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
# or http://opensource.org/licenses/MIT), at your option.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
#
#===----------------------------------------------------------------------===#
# Build MpVFX.app and the drag-to-Applications disk image from a release build.
# Run from mpvfx-swift/ after `python3 scripts/fetch-binaries.py && swift build -c release`:
#   sh packaging/macos/package.sh <dist-dir> developer-id|adhoc
# Writes <dist-dir>/MpVFX-<version>-macos-<arch>.dmg (prints its path last).
#
# The signing mode is required and there is no fallback between the two:
#   developer-id  sign with the "Developer ID Application" identity in the keychain (packaging/macos/import-cert.sh puts
#                 one there in CI), notarize with Apple and staple the ticket. The identity and the notarization
#                 credentials come from the environment the workflow sets; any of them missing, or Apple not accepting
#                 the image, fails the run.
#   adhoc         an ad-hoc signature for testing on this machine (pull requests); Gatekeeper blocks it elsewhere.
# MPVFX_BUILD (build number, default: git short sha) and MPVFX_VERSION (default: packaging/VERSION).
# MPVFX_SYMBOLS_DIR: when set, the binary's dSYM is written there (<name>.dSYM.tar.gz) before the binary is stripped;
# the shipped app never carries symbols (strip-check.yml verifies the disk image).
set -eu

dist=${1:?usage: package.sh <dist-dir> developer-id|adhoc}
mode=${2:?usage: package.sh <dist-dir> developer-id|adhoc}
case "$mode" in
  developer-id)
    [ -n "${MACOS_SIGN_IDENTITY:-}" ] || { echo "developer-id: no signing identity in the environment" >&2; exit 1; }
    [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] \
      || { echo "developer-id: notarization credentials missing from the environment" >&2; exit 1; } ;;
  adhoc) ;;
  *) echo "unknown signing mode: $mode (developer-id or adhoc)" >&2; exit 1 ;;
esac
mkdir -p "$dist"; dist=$(cd "$dist" && pwd)
version=${MPVFX_VERSION:-$(cat packaging/VERSION)}
build=${MPVFX_BUILD:-$(git rev-parse --short HEAD 2>/dev/null || echo 0)}
arch=$(uname -m)
work=$(mktemp -d)
app="$work/MpVFX.app"
bin=$(swift build -c release --show-bin-path)

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/MpVFX" "$app/Contents/MacOS/MpVFX"
if [ -n "${MPVFX_SYMBOLS_DIR:-}" ]; then
  mkdir -p "$MPVFX_SYMBOLS_DIR"
  dsymutil "$app/Contents/MacOS/MpVFX" -o "$work/MpVFX.dSYM"
  tar -C "$work" -czf "$MPVFX_SYMBOLS_DIR/MpVFX-$version-macos-$arch.dSYM.tar.gz" MpVFX.dSYM
fi
strip -S -x "$app/Contents/MacOS/MpVFX"   # debug and local symbols; what dyld binds stays
for b in "$bin"/*.bundle; do if [ -e "$b" ]; then cp -R "$b" "$app/Contents/Resources/"; fi; done
# The Metal kernels ship inside the app or the app grades on the CPU (MetalGradePipeline.resourceBundle): refuse to
# package an app without them rather than let a build machine's own copy hide it.
kernels="$app/Contents/Resources/Mpvfx_MpvfxMetal.bundle"
if [ ! -f "$kernels/Contents/Resources/default.metallib" ] && [ ! -f "$kernels/Contents/Resources/MpvfxColor.metal" ] &&
   [ ! -f "$kernels/default.metallib" ] && [ ! -f "$kernels/MpvfxColor.metal" ]; then
  echo "package.sh: $kernels holds neither default.metallib nor MpvfxColor.metal" >&2; exit 1
fi

# Dylibs the binary loads from outside the OS (the media engine is linked statically): copy into Frameworks.
otool -L "$app/Contents/MacOS/MpVFX" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/)' > "$work/extdeps.txt" || true
while read -r d; do
  [ -n "$d" ] || continue
  f=$(basename "$d"); src="$d"; [ -f "$src" ] || src="$bin/$f"
  [ -f "$src" ] || src=$(ls .binaries/*/lib/"$f" 2>/dev/null | head -n 1)   # engine dylibs (binaries.lock)
  [ -f "$src" ] || { echo "package.sh: cannot find $d to bundle" >&2; exit 1; }
  cp "$src" "$app/Contents/Frameworks/$f"
  install_name_tool -change "$d" "@rpath/$f" "$app/Contents/MacOS/MpVFX"
done < "$work/extdeps.txt"
# Drop the build-time rpaths into .binaries/ so the app only looks inside its own bundle.
for r in $(otool -l "$app/Contents/MacOS/MpVFX" | awk '$1 == "path" {print $2}' | grep "/\.binaries/" || true); do
  install_name_tool -delete_rpath "$r" "$app/Contents/MacOS/MpVFX"
done
otool -l "$app/Contents/MacOS/MpVFX" | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/MpVFX"

# Icon: the iconset sizes macOS expects, from the committed PNGs (packaging/icon/make-icon.py).
for c in .binaries/*/; do   # each engine's licence and third-party notices travel with it
  c=$(basename "$c"); mkdir -p "$app/Contents/Resources/EngineLicenses/$c"
  cp .binaries/"$c"/LICENSE .binaries/"$c"/NOTICE "$app/Contents/Resources/EngineLicenses/$c/" 2>/dev/null || true
done
set_dir="$work/MpVFX.iconset"; mkdir -p "$set_dir"
for s in 16 32 128 256 512; do
  cp "packaging/icon/mpvfx-$s.png" "$set_dir/icon_${s}x${s}.png"
  cp "packaging/icon/mpvfx-$((s * 2)).png" "$set_dir/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$set_dir" -o "$app/Contents/Resources/MpVFX.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MpVFX</string>
<key>CFBundleIdentifier</key><string>app.onetake.mpvfx</string>
<key>CFBundleName</key><string>MpVFX</string>
<key>CFBundleDisplayName</key><string>MpVFX</string>
<key>CFBundleIconFile</key><string>MpVFX</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.video</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"

# Sign inside out: each dylib, then the app. Developer ID signing uses the hardened runtime and a secure
# timestamp (both required for notarization).
if [ "$mode" = developer-id ]; then
  set -- --force --sign "$MACOS_SIGN_IDENTITY" --options runtime --timestamp
else
  echo "ad-hoc build: for testing only (Gatekeeper blocks it on other Macs)"
  set -- --force --sign -
fi
for f in "$app/Contents/Frameworks/"*; do if [ -e "$f" ]; then codesign "$@" "$f"; fi; done
codesign "$@" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# Disk image: the app and a link to /Applications, compressed. hdiutil on CI runners fails now and then with
# "Resource busy"; three tries.
dmg="$dist/MpVFX-$version-macos-$arch.dmg"
stage="$work/dmg"; mkdir -p "$stage"; cp -R "$app" "$stage/"; ln -s /Applications "$stage/Applications"
rm -f "$dmg"
for try in 1 2 3; do
  hdiutil create -volname "MpVFX" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" && break
  [ "$try" = 3 ] && exit 1; sleep 5
done

if [ "$mode" = developer-id ]; then
  codesign --force --sign "$MACOS_SIGN_IDENTITY" --timestamp "$dmg"
  xcrun notarytool submit "$dmg" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait --timeout 30m --output-format json > "$work/notary.json"
  cat "$work/notary.json"; echo
  if ! grep -q '"status" *: *"Accepted"' "$work/notary.json"; then
    id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$work/notary.json" | head -1)
    [ -z "$id" ] || xcrun notarytool log "$id" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID"
    echo "notarization was not accepted" >&2; exit 1
  fi
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
rm -rf "$work"
echo "$dmg"

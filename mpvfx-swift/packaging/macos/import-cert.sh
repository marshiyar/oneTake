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
# CI only: put the Developer ID Application certificate into a temporary keychain and print its identity name.
# Run from anywhere:  identity=$(sh packaging/macos/import-cert.sh)
# Environment: MACOS_CERT_P12_BASE64 (the .p12 export, base64), MACOS_CERT_PASSWORD (the .p12 password).
# The keychain lives under $RUNNER_TEMP (or a mktemp dir) and is removed with the runner.
set -eu
: "${MACOS_CERT_P12_BASE64:?}" "${MACOS_CERT_PASSWORD:?}"
dir=${RUNNER_TEMP:-$(mktemp -d)}
kc="$dir/mpvfx-signing.keychain-db"
kc_pass=$(uuidgen)
printf '%s' "$MACOS_CERT_P12_BASE64" | base64 --decode > "$dir/cert.p12"
security create-keychain -p "$kc_pass" "$kc" >&2
security set-keychain-settings -lut 21600 "$kc" >&2
security unlock-keychain -p "$kc_pass" "$kc" >&2
security import "$dir/cert.p12" -k "$kc" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >&2
rm -f "$dir/cert.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$kc_pass" "$kc" >/dev/null
# Search this keychain first, keep the login keychain after it.
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"') >&2
identity=$(security find-identity -v -p codesigning "$kc" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
[ -n "$identity" ] || { echo "no Developer ID Application identity in the certificate" >&2; exit 1; }
echo "$identity"

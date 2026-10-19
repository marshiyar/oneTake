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
# The certificate (a .p12 export, base64) and its password come from the environment the workflow sets.
# The keychain lives under $RUNNER_TEMP (or a mktemp dir) and is removed with the runner. Apple's Developer ID
# intermediates are imported too: a certificate issued by the G2 authority is not trusted without its intermediate, and
# an untrusted identity is not a valid signing identity. On failure it says why without printing the certificate.
set -eu
: "${MACOS_CERT_P12_BASE64:?}" "${MACOS_CERT_PASSWORD:?}"
dir=${RUNNER_TEMP:-$(mktemp -d)}
kc="$dir/mpvfx-signing.keychain-db"
kc_pass=$(uuidgen)
printf '%s' "$MACOS_CERT_P12_BASE64" | base64 --decode > "$dir/cert.p12"
security create-keychain -p "$kc_pass" "$kc" >&2
security set-keychain-settings -lut 21600 "$kc" >&2
security unlock-keychain -p "$kc_pass" "$kc" >&2
for ca in DeveloperIDG2CA DeveloperIDCA; do
  curl -fsSL --retry 3 -o "$dir/$ca.cer" "https://www.apple.com/certificateauthority/$ca.cer" \
    || { echo "could not download Apple's $ca intermediate" >&2; exit 1; }
  security import "$dir/$ca.cer" -k "$kc" >&2
done
if ! security import "$dir/cert.p12" -k "$kc" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1; then
  rm -f "$dir/cert.p12"
  echo "the certificate could not be imported: wrong password, or not a .p12 export" >&2; exit 1
fi
rm -f "$dir/cert.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$kc_pass" "$kc" >/dev/null
# Search this keychain first, keep the login keychain after it.
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"') >&2
identity=$(security find-identity -v -p codesigning "$kc" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
if [ -z "$identity" ]; then
  # Why, without names: is there a private key, and which kinds of certificate came in.
  keys=$(security find-identity -p codesigning "$kc" | grep -c '"' || true)
  kinds=$(security find-certificate -a -p "$kc" | openssl crl2pkcs7 -nocrl -certfile /dev/stdin 2>/dev/null \
    | openssl pkcs7 -print_certs -noout 2>/dev/null | sed -n 's/^subject=.*CN *= *\([^:,]*\).*/\1/p' | sort | uniq -c | tr '\n' ';')
  echo "no valid Developer ID Application identity: $keys identities with a private key; certificates by kind: $kinds" >&2
  [ "$keys" -gt 0 ] || echo "the .p12 holds no private key: export it from Keychain Access > My Certificates" >&2
  exit 1
fi
echo "$identity"

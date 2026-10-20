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
# CI only, on Linux, in seconds and before any macOS runner is waited for: checks the signing and notarization secrets
# the workflow puts in the environment. The certificate must open with its password, hold its private key, be a
# Developer ID Application certificate that has not expired, match that key, and belong to the configured team; the
# Apple ID and app-specific password must have their expected shape. Each failure says which check failed and never
# prints a secret, a name or an identifier. Exit 0 = every check passed.
set -eu
fail() { echo "signing check failed: $*" >&2; exit 1; }
for v in MACOS_CERT_P12_BASE64 MACOS_CERT_PASSWORD APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || fail "a signing or notarization secret is not set"
done
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
printf '%s' "$MACOS_CERT_P12_BASE64" | base64 --decode > "$dir/c.p12" 2>/dev/null \
  || fail "the certificate secret is not base64 text (copy it with: base64 -i DeveloperID.p12 | pbcopy)"
# Keychain Access writes .p12 files with the older PKCS#12 ciphers, which OpenSSL 3 reads through its legacy provider.
p12() { openssl pkcs12 -legacy -in "$dir/c.p12" -passin env:MACOS_CERT_PASSWORD "$@" 2>/dev/null; }
p12 -nokeys -clcerts -out "$dir/certs.pem" || fail "the certificate password does not open the .p12, or it is not a .p12"
p12 -nocerts -nodes -out "$dir/key.pem" || fail "the private key in the .p12 could not be read"
grep -q "PRIVATE KEY" "$dir/key.pem" \
  || fail "the .p12 holds no private key (export it from Keychain Access > login > My Certificates with the key under it)"
# One file per certificate in the export; find the Developer ID Application one.
awk -v d="$dir" '/BEGIN CERTIFICATE/ {n++} n {print > (d "/cert" n ".pem")}' "$dir/certs.pem"
found=
for c in "$dir"/cert[0-9]*.pem; do
  [ -e "$c" ] || continue
  subject=$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253)
  case "$subject" in *"CN=Developer ID Application:"*) found=$c; break ;; esac
done
[ -n "$found" ] || fail "the .p12 holds no Developer ID Application certificate (another kind was exported)"
openssl x509 -in "$found" -noout -checkend 0 >/dev/null || fail "the Developer ID Application certificate has expired"
[ "$(openssl x509 -in "$found" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$dir/key.pem" -pubout | openssl sha256)" ] \
  || fail "the private key in the .p12 does not belong to the Developer ID Application certificate"
team=$(printf '%s\n' "$subject" | tr ',' '\n' | sed -n 's/^OU=//p' | head -1)
[ "$team" = "$APPLE_TEAM_ID" ] || fail "the certificate belongs to a different team than the team ID secret"
case "$APPLE_ID" in *@*.*) ;; *) fail "the Apple ID secret is not an email address" ;; esac
printf '%s' "$APPLE_APP_PASSWORD" | grep -Eqx '[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}' \
  || fail "the app-specific password secret is not in Apple's xxxx-xxxx-xxxx-xxxx form (your normal password does not work)"
echo "signing check passed: Developer ID Application certificate with its key, valid, for the configured team"

#!/usr/bin/env bash
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
# runners_app_installed.sh: prints installed=true when the oneTake-Runners1 App (RUNNERS_APP_ID, RUNNERS_APP_PRIVATE_KEY)
# is installed on $GITHUB_REPOSITORY, else installed=false; never fails. Work is sent to OneTake-app/OneTake-actionRunners-1
# only when it is: without that installation the runners repository cannot report statuses back here, so remote shards
# would time out and the nightly disk image would be lost. GET /repos/{owner}/{repo}/installation with the App's JWT
# (https://docs.github.com/en/rest/apps/apps#get-a-repository-installation-for-the-authenticated-app, read 2026-10-21).
set -u
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
installed=false
if [ -n "${RUNNERS_APP_ID:-}" ] && [ -n "${RUNNERS_APP_PRIVATE_KEY:-}" ]; then
  key=$(mktemp); trap 'rm -f "$key"' EXIT
  printf '%s\n' "$RUNNERS_APP_PRIVATE_KEY" > "$key"
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 300))" "$RUNNERS_APP_ID" | b64url)
  if sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" 2>/dev/null | b64url) && [ -n "$sig" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $header.$payload.$sig" \
      -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$GITHUB_REPOSITORY/installation" || true)
    [ "$code" = 200 ] && installed=true
    [ "$installed" = true ] || echo "::notice::oneTake-Runners1 is not installed on $GITHUB_REPOSITORY (HTTP $code): every job runs here"
  else
    echo "::warning::RUNNERS_APP_PRIVATE_KEY is not a usable private key: every job runs here"
  fi
fi
echo "installed=$installed"

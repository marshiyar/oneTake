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
# is installed on $GITHUB_REPOSITORY with Commit statuses and Contents: write, else installed=false; never fails.
# Work is sent to OneTake-app/OneTake-actionRunners-1
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
    jwt="$header.$payload.$sig"
    body=$(mktemp)
    code=$(curl -s -o "$body" -w '%{http_code}' -H "Authorization: Bearer $jwt" \
      -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$GITHUB_REPOSITORY/installation" || true)
    if [ "$code" = 200 ]; then
      # Installed is not enough: OneTake-actionRunners-1 must be able to set statuses and upload release assets here.
      # Ask for exactly that token (POST /app/installations/{id}/access_tokens; read 2026-10-21:
      # https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app); 201 or nothing.
      id=$(sed -n 's/^  "id": \([0-9]*\),*$/\1/p' "$body" | head -1)
      want=$(printf '{"repositories":["%s"],"permissions":{"statuses":"write","contents":"write"}}' "${GITHUB_REPOSITORY#*/}")
      code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" -d "$want" \
        "https://api.github.com/app/installations/${id:-0}/access_tokens" || true)
      [ "$code" = 201 ] && installed=true
      [ "$installed" = true ] || echo "::notice::oneTake-Runners1 is installed on $GITHUB_REPOSITORY but lacks Commit statuses and Contents: write (HTTP $code): every job runs here" >&2
    else
      echo "::notice::oneTake-Runners1 is not installed on $GITHUB_REPOSITORY (HTTP $code): every job runs here" >&2
    fi
    rm -f "$body"
  else
    echo "::warning::RUNNERS_APP_PRIVATE_KEY is not a usable private key: every job runs here" >&2
  fi
fi
echo "installed=$installed"

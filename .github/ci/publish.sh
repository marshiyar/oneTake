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
# publish.sh <files...>: upload to the release build-<branch>-<shortsha> (created if missing; latest on main, prerelease
# elsewhere); keep the newest 3 per branch.
set -euo pipefail
branch=${GITHUB_REF_NAME//\//-}; short=${GITHUB_SHA::7}; tag="build-$branch-$short"
files=(); for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
[ ${#files[@]} -gt 0 ] || { echo "::error::nothing to publish"; exit 1; }
# The Linux/Windows and macOS workflows publish into the same release and can finish together: if the create
# loses that race, the release exists and the upload goes on.
# main: a full release marked latest, so releases/latest always holds the newest green installers; other branches:
# prereleases.
kind=--prerelease; [ "$branch" = main ] && kind=--latest
gh release view "$tag" >/dev/null 2>&1 || gh release create "$tag" $kind --target "$GITHUB_SHA" \
  --title "MpVFX $(date -u +%Y-%m-%d) ($branch $short)" \
  --notes "MpVFX installers built from $branch at $GITHUB_SHA: macOS .dmg, Windows setup.exe, Ubuntu/Debian .deb, plus portable archives. Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
  || { sleep 5; gh release view "$tag" >/dev/null; }
gh release upload "$tag" "${files[@]}" --clobber
gh release view "$tag" --json assets --jq '.assets[] | "\(.name) \(.url)"'
gh release list --limit 200 --json tagName,createdAt \
  --jq "[.[] | select(.tagName | startswith(\"build-$branch-\"))] | sort_by(.createdAt) | reverse | .[3:][] | .tagName" |
  while read -r old; do [ -n "$old" ] && gh release delete "$old" --cleanup-tag --yes; done

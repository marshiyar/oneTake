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
# publish.sh <files...>: upload a green CI run's installers to a GitHub release, chosen by the ref the run is for:
#   branch main: the prerelease nightly-<shortsha> (one per commit; a rerun on the same commit uploads into it again),
#                never marked latest; only the newest 7 nightly-* releases are kept.
#   tag v<version>: the full release <tag>, marked latest; <version> must equal mpvfx-swift/packaging/VERSION. Never
#                pruned.
#   anything else: nothing is published.
# Sourced (`. publish.sh`), it only defines its functions, so the ref decision can be checked without GitHub.
set -euo pipefail

version_file=mpvfx-swift/packaging/VERSION
nightly_keep=7

# decide: from GITHUB_REF_TYPE, GITHUB_REF_NAME and GITHUB_SHA, set mode (nightly, official or none), and for a
# publishing mode tag, title and flags (the gh release create options). Fails when a v* tag does not match VERSION.
decide() {
  local ref_type=${GITHUB_REF_TYPE:-} ref=${GITHUB_REF_NAME:-} short=${GITHUB_SHA:0:7} version want
  mode=none tag='' title='' flags=()
  if [ "$ref_type" = tag ]; then
    case "$ref" in
      v?*) ;;
      *) echo "::notice::tag $ref is not a v* release tag; nothing is published"; return 0 ;;
    esac
    version=${ref#v}
    [ -f "$version_file" ] || { echo "::error::$version_file is missing; cannot check tag $ref against it"; return 1; }
    want=$(tr -d '[:space:]' < "$version_file")
    if [ "$version" != "$want" ]; then
      echo "::error::tag $ref is version $version but $version_file says ${want:-<empty>}; bump VERSION or retag"
      return 1
    fi
    mode=official tag=$ref title="oneTake $version" flags=(--verify-tag --latest)
  elif [ "$ref_type" = branch ] && [ "$ref" = main ]; then
    mode=nightly tag="nightly-$short" title="oneTake nightly $(date -u +%Y-%m-%d) ($short)"
    flags=(--prerelease --latest=false --target "$GITHUB_SHA")
  else
    echo "::notice::$ref_type $ref is neither main nor a v* tag; nothing is published"
  fi
}

# notes: the release notes for the decided mode.
notes() {
  local server=${GITHUB_SERVER_URL:-https://github.com} repo=${GITHUB_REPOSITORY:-} run commit
  run="$server/$repo/actions/runs/${GITHUB_RUN_ID:-}"
  commit="$server/$repo/commit/$GITHUB_SHA"
  if [ "$mode" = nightly ]; then
    printf '%s\n\n%s\n%s\n' \
      "Untested development build from main: installers from every green CI run of main, not an official release." \
      "Commit: $commit" "Run: $run"
  elif [ -f CHANGELOG.md ]; then
    printf 'Release notes: see CHANGELOG (%s).\n' "$server/$repo/blob/$tag/CHANGELOG.md"
  else
    printf 'oneTake %s, built from %s.\n' "${tag#v}" "$commit"
  fi
}

# asset_label <file>: "#<display label>" for gh release upload, naming the macOS disk image's developer verification
# (owner ruling 2026-10-21: an unverified build still ships, labelled as such); empty for every other file.
asset_label() {
  case "$1" in
    *-developer-verified.dmg) echo "#oneTake for macOS (Developer Verified)" ;;
    *-developer-stamp-unverified.dmg) echo "#oneTake for macOS (Developer Stamp Unverified)" ;;
  esac
}

# prune_nightlies: delete every nightly-* release but the newest $nightly_keep (never touches any other release).
prune_nightlies() {
  gh release list --limit 200 --json tagName,createdAt \
    --jq "[.[] | select(.tagName | startswith(\"nightly-\"))] | sort_by(.createdAt) | reverse | .[$nightly_keep:][] | .tagName" |
    while read -r old; do
      case "$old" in nightly-?*) gh release delete "$old" --cleanup-tag --yes ;; esac
    done
}

main() {
  decide
  [ "$mode" != none ] || return 0
  local files=() f
  for f in "$@"; do [ -f "$f" ] && files+=("$f$(asset_label "$f")"); done
  [ ${#files[@]} -gt 0 ] || { echo "::error::nothing to publish"; return 1; }
  echo "publishing $mode release $tag: $title"
  # A rerun on the same commit or tag finds the release already there and uploads into it.
  gh release view "$tag" >/dev/null 2>&1 || gh release create "$tag" "${flags[@]}" --title "$title" --notes "$(notes)" \
    || { sleep 5; gh release view "$tag" >/dev/null; }
  gh release upload "$tag" "${files[@]}" --clobber
  gh release view "$tag" --json assets --jq '.assets[] | "\(.name) \(.url)"'
  [ "$mode" != nightly ] || prune_nightlies
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

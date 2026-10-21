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
#   tag v<X.Y.Z>-alpha.<N>, v<X.Y.Z>-beta.<N>, v<X.Y.Z>-rc.<N> (N = 1, 2, ...): the prerelease <tag> on that channel,
#                never marked latest, never pruned; <X.Y.Z> must equal mpvfx-swift/packaging/VERSION.
#   tag v<X.Y.Z>: the stable release <tag>, marked latest; <X.Y.Z> must equal mpvfx-swift/packaging/VERSION. Never
#                pruned.
#   a v* tag with any other suffix after the hyphen: refused (the job fails, nothing is published).
#   anything else: nothing is published.
# The notes of every release say so when the macOS disk image is not notarized (dist/macos-notarization.txt, written
# by the macos job, holds anything but "notarized"), and how to open the app then.
# Sourced (`. publish.sh`), it only defines its functions, so the ref decision can be checked without GitHub
# (.github/ci/test_publish.py).
set -euo pipefail

version_file=mpvfx-swift/packaging/VERSION
notarization_file=${MACOS_NOTARIZATION_FILE:-dist/macos-notarization.txt}
nightly_keep=7

# decide: from GITHUB_REF_TYPE, GITHUB_REF_NAME and GITHUB_SHA, set mode (nightly, prerelease, official or none),
# channel (nightly, alpha, beta, rc or stable), and for a publishing mode tag, title and flags (the gh release create
# options). Fails when a v* tag does not match VERSION, or carries a suffix other than -alpha.N, -beta.N or -rc.N.
decide() {
  local ref_type=${GITHUB_REF_TYPE:-} ref=${GITHUB_REF_NAME:-} short=${GITHUB_SHA:0:7} version want pre number='' label
  mode=none channel='' tag='' title='' flags=()
  if [ "$ref_type" = tag ]; then
    case "$ref" in
      v?*) ;;
      *) echo "::notice::tag $ref is not a v* release tag; nothing is published"; return 0 ;;
    esac
    version=${ref#v}
    if [ "$version" != "${version%%-*}" ]; then
      pre=${version#*-} version=${version%%-*}
      if [[ "$pre" =~ ^(alpha|beta|rc)\.([1-9][0-9]*)$ ]]; then
        channel=${BASH_REMATCH[1]} number=${BASH_REMATCH[2]}
      else
        echo "::error::tag $ref: the part after the hyphen must be alpha.<N>, beta.<N> or rc.<N> (N = 1, 2, ...)," \
          "e.g. v$version-beta.1; nothing is published. Delete the tag (git push origin :refs/tags/$ref) and push a" \
          "valid one"
        return 1
      fi
    fi
    [ -f "$version_file" ] || { echo "::error::$version_file is missing; cannot check tag $ref against it"; return 1; }
    want=$(tr -d '[:space:]' < "$version_file")
    if [ "$version" != "$want" ]; then
      echo "::error::tag $ref is version $version but $version_file says ${want:-<empty>}; bump VERSION or retag"
      return 1
    fi
    if [ -n "$channel" ]; then
      label=$channel
      [ "$channel" != rc ] || label=RC
      mode=prerelease tag=$ref title="oneTake $version $label $number"
      flags=(--verify-tag --prerelease --latest=false)
    else
      mode=official channel=stable tag=$ref title="oneTake $version" flags=(--verify-tag --latest)
    fi
  elif [ "$ref_type" = branch ] && [ "$ref" = main ]; then
    mode=nightly channel=nightly tag="nightly-$short" title="oneTake nightly $(date -u +%Y-%m-%d) ($short)"
    flags=(--prerelease --latest=false --target "$GITHUB_SHA")
  else
    echo "::notice::$ref_type $ref is neither main nor a v* tag; nothing is published"
  fi
}

# notes: the release notes for the decided mode.
notes() {
  local server=${GITHUB_SERVER_URL:-https://github.com} repo=${GITHUB_REPOSITORY:-} run commit promise=''
  run="$server/$repo/actions/runs/${GITHUB_RUN_ID:-}"
  commit="$server/$repo/commit/$GITHUB_SHA"
  if [ "$mode" = nightly ]; then
    printf '%s\n\n%s\n%s\n' \
      "Untested development build from main: installers from every green CI run of main, not an official release." \
      "Commit: $commit" "Run: $run"
  elif [ "$mode" = prerelease ]; then
    case "$channel" in
      alpha) promise="Alpha channel: an early test build. Features may be missing or change, and projects saved with it may not open in later builds; keep backups." ;;
      beta) promise="Beta channel: a feature-complete test build for wider testing. Expect bugs; keep backups of your projects." ;;
      rc) promise="Release-candidate channel: this build becomes ${tag%%-*} unless a blocking bug is found." ;;
    esac
    printf '%s\n\n%s\n\n' "This is a test build, not a stable release: $title." "$promise"
    if [ -f CHANGELOG.md ]; then printf 'Changes: see CHANGELOG (%s).\n' "$server/$repo/blob/$tag/CHANGELOG.md"; fi
    printf '%s\n%s\n' "Commit: $commit" "Run: $run"
  elif [ -f CHANGELOG.md ]; then
    printf 'Release notes: see CHANGELOG (%s).\n' "$server/$repo/blob/$tag/CHANGELOG.md"
  else
    printf 'oneTake %s, built from %s.\n' "${tag#v}" "$commit"
  fi
  # A missing or unreadable marker counts as not notarized: an unneeded hint costs less than a blocked user.
  if [ "$(tr -d '[:space:]' < "$notarization_file" 2>/dev/null || true)" != notarized ]; then
    printf '\n%s\n' "macOS: this disk image is not notarized by Apple, so macOS will ask you to approve the app the first time you open it: right-click (or Control-click) MpVFX in Applications, choose Open, then Open again (if no Open button is offered: System Settings > Privacy & Security > Open Anyway)."
  fi
}

# prune_nightlies: delete every nightly-* release but the newest $nightly_keep. Alpha, beta, rc and stable releases
# are never touched: the jq filter selects nightly-* only and the case below deletes nothing else.
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
  for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
  [ ${#files[@]} -gt 0 ] || { echo "::error::nothing to publish"; return 1; }
  echo "publishing $mode ($channel) release $tag: $title"
  # A rerun on the same commit or tag finds the release already there and uploads into it.
  gh release view "$tag" >/dev/null 2>&1 || gh release create "$tag" "${flags[@]}" --title "$title" --notes "$(notes)" \
    || { sleep 5; gh release view "$tag" >/dev/null; }
  gh release upload "$tag" "${files[@]}" --clobber
  gh release view "$tag" --json assets --jq '.assets[] | "\(.name) \(.url)"'
  [ "$mode" != nightly ] || prune_nightlies
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

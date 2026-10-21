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
# The notes (written after the upload, with gh release edit --notes-file) open with a channel banner, embed the smoke
# screenshot of every OS, give a download table (with the not-notarized line when dist/macos-notarization.txt holds
# anything but "notarized", or dist/.not-notarized exists) and list what changed since the previous release of the same
# or a higher channel (at most 50 entries).
# Sourced (`. publish.sh`), it only defines its functions, so decisions and notes can be checked without GitHub
# (.github/ci/test_publish.py).
set -euo pipefail

version_file=mpvfx-swift/packaging/VERSION
notarization_file=${MACOS_NOTARIZATION_FILE:-dist/macos-notarization.txt}
nightly_keep=7
changes_max=50

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
    mode=nightly channel=nightly tag="nightly-$short"
    title="oneTake nightly $(date -u +%Y-%m-%d) ($short), development build"
    flags=(--prerelease --latest=false --target "$GITHUB_SHA")
  else
    echo "::notice::$ref_type $ref is neither main nor a v* tag; nothing is published"
  fi
}

# channel_of <tag>: print the channel a release tag belongs to (nightly, alpha, beta, rc, stable), or nothing for a
# tag of no channel (the old build-main-* releases, anything else).
channel_of() {
  case "$1" in
    nightly-?*) echo nightly ;;
    v*-alpha.*) echo alpha ;;
    v*-beta.*) echo beta ;;
    v*-rc.*) echo rc ;;
    v*-*) ;;
    v?*) echo stable ;;
  esac
}

# channel_rank <channel>: nightly 0 < alpha 1 < beta 2 < rc 3 < stable 4; -1 for no channel.
channel_rank() {
  case "$1" in nightly) echo 0 ;; alpha) echo 1 ;; beta) echo 2 ;; rc) echo 3 ;; stable) echo 4 ;; *) echo -1 ;; esac
}

# previous_release <tag> <channel>: from release tags on stdin, newest first, print the first one that is not <tag>
# and whose channel is <channel> or higher (a beta compares with the last beta, rc or stable; a nightly with any).
previous_release() {
  local want t r
  want=$(channel_rank "$2")
  while read -r t; do
    [ -n "$t" ] && [ "$t" != "$1" ] || continue
    r=$(channel_rank "$(channel_of "$t")")
    if [ "$r" -ge 0 ] && [ "$r" -ge "$want" ]; then echo "$t"; return 0; fi
  done
}

# format_changes <previous tag> <total commits>: commit subjects on stdin (newest first) as a Markdown list of at most
# $changes_max entries, a trailing "(#N)" linked to its pull request; the rest is one line linking the full compare.
format_changes() {
  local prev=$1 total=$2 base n=0 line
  base="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    [ "$n" -le "$changes_max" ] || continue
    if [[ "$line" =~ ^(.*)\ \(#([0-9]+)\)$ ]]; then
      printf -- '- %s ([#%s](%s/pull/%s))\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$base" "${BASH_REMATCH[2]}"
    else
      printf -- '- %s\n' "$line"
    fi
  done
  [ "$total" -ge "$n" ] 2>/dev/null || total=$n
  if [ "$n" -eq 0 ]; then
    printf 'No changes since %s.\n' "$prev"
  elif [ "$total" -gt "$changes_max" ]; then
    printf -- '- ... and %s more: [all changes since %s](%s/compare/%s...%s)\n' \
      "$((total - changes_max))" "$prev" "$base" "$prev" "$GITHUB_SHA"
  fi
}

# changes: the "What changed" list for the decided release, from GitHub (the previous release of the same or a higher
# channel, then the commits between it and this one). Never fails: a lookup error becomes a link to the history.
changes() {
  local base prev out total
  base="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}"
  prev=$(gh release list --limit 200 --json tagName,createdAt --jq 'sort_by(.createdAt) | reverse | .[].tagName' \
    2>/dev/null | previous_release "$tag" "$channel" || true)
  if [ -z "$prev" ]; then
    printf 'The first release on this channel: see the [history](%s/commits/%s).\n' "$base" "$GITHUB_SHA"
    return 0
  fi
  if out=$(gh api "repos/$GITHUB_REPOSITORY/compare/$prev...$GITHUB_SHA" \
      --jq '.total_commits, ([.commits[].commit.message | split("\n")[0]] | reverse | .[])' 2>/dev/null); then
    total=$(printf '%s\n' "$out" | head -n 1)
    printf 'Since [%s](%s/releases/tag/%s):\n\n' "$prev" "$base" "$prev"
    printf '%s\n' "$out" | tail -n +2 | format_changes "$prev" "$total"
  else
    printf 'See the [changes since %s](%s/compare/%s...%s).\n' "$prev" "$base" "$prev" "$GITHUB_SHA"
  fi
}

# notarized: true when the macOS disk image of this run was notarized. A missing or unreadable marker counts as not
# notarized: an unneeded hint costs less than a blocked user.
notarized() {
  [ ! -e "$(dirname "$notarization_file")/.not-notarized" ] &&
    [ "$(tr -d '[:space:]' < "$notarization_file" 2>/dev/null || true)" = notarized ]
}

# stable_gate: a stable release (the public launch) ships its macOS disk image notarized or not at all: fail when
# the assets hold a .dmg that is not notarized. Every other channel passes (notarization is not attempted there).
stable_gate() {
  local a
  [ "$channel" = stable ] || return 0
  for a in "${assets[@]}"; do
    case "$a" in
      *.dmg) notarized || {
        echo "::error::stable release $tag: the macOS disk image $a is not notarized; a stable release ships notarized" \
          "or not at all. Fix the APPLE_* secrets and rerun the tag's run"
        return 1
      } ;;
    esac
  done
}

# banner: the first lines of the notes, one distinct sentence per channel (a GitHub alert for nightly, alpha, beta, rc).
banner() {
  case "$channel" in
    nightly) printf '> [!WARNING]\n> **Nightly**: automatic development build of main, untested by people; expect breakage. Not for real projects.\n' ;;
    alpha) printf '> [!WARNING]\n> **Alpha**: early test build for testers; expect bugs. Not for real projects.\n> This is a test build, not a stable release: features may be missing or change, and projects saved with it may not open in later builds.\n' ;;
    beta) printf '> [!NOTE]\n> **Beta**: feature-complete test build for wider testing; expect some bugs and keep backups of your projects.\n> This is a test build, not a stable release.\n' ;;
    rc) printf '> [!NOTE]\n> **Release candidate**: this build becomes %s unless a blocking bug is found; please report anything that stops you.\n> This is a test build, not a stable release.\n' "${tag%%-*}" ;;
    stable) printf '> **Stable**: the official %s release.\n' "$title" ;;
  esac
}

# notes: the release notes for the decided release. Reads the globals mode, channel, tag, title, assets (the uploaded
# file names) and changes_md (the "What changed" list); makes no network call.
notes() {
  local server=${GITHUB_SERVER_URL:-https://github.com} repo=${GITHUB_REPOSITORY:-} dl a os row kind hint
  local mac='' win='' linux=''
  dl="$server/$repo/releases/download/$tag"
  banner
  printf '\n## Screenshots\n\n'
  for a in "${assets[@]}"; do
    case "$a" in
      mac*-smoke.png) os=macOS ;; windows*-smoke.png) os=Windows ;; linux*-smoke.png) os=Linux ;;
      *-smoke.png) os=${a%-smoke.png} ;; *) continue ;;
    esac
    printf '![%s](%s/%s)\n\n' "$os" "$dl" "$a"
  done
  for a in "${assets[@]}"; do
    case "$a" in
      *.dmg) mac+="${mac:+<br>}[\`$a\`]($dl/$a) disk image" ;;
      *-setup.exe) win+="${win:+<br>}[\`$a\`]($dl/$a) installer" ;;
      *.zip) win+="${win:+<br>}[\`$a\`]($dl/$a) portable zip" ;;
      *.deb) linux+="${linux:+<br>}[\`$a\`]($dl/$a) Debian package" ;;
      *.tar.gz) linux+="${linux:+<br>}[\`$a\`]($dl/$a) portable archive" ;;
    esac
  done
  printf '## Download\n\n| OS | File | Install |\n|---|---|---|\n'
  for os in macOS Windows Linux; do
    case "$os" in
      macOS) row=$mac hint="Open the .dmg and drag MpVFX to Applications (Apple silicon, macOS 15 or newer)."
        if ! notarized; then hint+=" Not notarized: right-click → Open the first time."; fi ;;
      Windows) row=$win hint="Run the setup.exe, or unzip the portable zip anywhere and run MpVFX.exe (Windows 10 or 11, x64). Unsigned: on \"Windows protected your PC\" choose More info, then Run anyway ([README]($server/$repo/blob/$GITHUB_SHA/README.md#download))." ;;
      Linux) row=$linux hint="\`sudo apt install ./<file>.deb\` (Ubuntu 24.04 or newer, Debian 13), or unpack the archive and run MpVFX." ;;
    esac
    kind=${row:-not in this build}
    printf '| %s | %s | %s |\n' "$os" "$kind" "$hint"
  done
  if ! notarized; then
    printf '\nmacOS: not notarized: right-click → Open the first time (if macOS offers no Open button: System Settings > Privacy & Security > Open Anyway).\n'
  fi
  printf '\n## What changed\n\n%s\n' "${changes_md:-}"
  if [ "$mode" != nightly ] && [ -f CHANGELOG.md ]; then
    printf '\nRelease notes: see CHANGELOG (%s).\n' "$server/$repo/blob/$tag/CHANGELOG.md"
  fi
  printf '\nCommit: %s\nRun: %s\n' "$server/$repo/commit/$GITHUB_SHA" "$server/$repo/actions/runs/${GITHUB_RUN_ID:-}"
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
  local files=() f notes_file
  assets=()
  for f in "$@"; do [ -f "$f" ] && files+=("$f") && assets+=("$(basename "$f")"); done
  [ ${#files[@]} -gt 0 ] || { echo "::error::nothing to publish"; return 1; }
  stable_gate || return 1
  echo "publishing $mode ($channel) release $tag: $title"
  changes_md=$(changes)
  notes_file=$(mktemp)
  notes > "$notes_file"
  # A rerun on the same commit or tag finds the release already there and uploads into it.
  gh release view "$tag" >/dev/null 2>&1 || gh release create "$tag" "${flags[@]}" --title "$title" \
    --notes-file "$notes_file" || { sleep 5; gh release view "$tag" >/dev/null; }
  gh release upload "$tag" "${files[@]}" --clobber
  # The notes again, now that the screenshots they embed are assets of the release (and a rerun refreshes them).
  gh release edit "$tag" --title "$title" --notes-file "$notes_file"
  rm -f "$notes_file"
  gh release view "$tag" --json assets --jq '.assets[] | "\(.name) \(.url)"'
  [ "$mode" != nightly ] || prune_nightlies
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

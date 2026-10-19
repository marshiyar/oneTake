#!/bin/sh
# make-snapshot.sh [options] DEST: build the public oneTake tree from the old app repository, check it, report.
#
#   --source URL            repository to snapshot (default https://github.com/marshiyar/mpvfx-swift-agentic.git)
#   --ref REF               branch or tag to snapshot (default main)
#   --wait-for N,N,...      pull requests of the source that must be merged first (default 71,72,74,73,69,70,62);
#                           checked with `gh api` or the GitHub API (GH_TOKEN once the source is private);
#                           --wait-for none skips the check
#   --engine-fixtures=MODE  copy (default): the engine's project-generated media fixtures the app tests read; or omit
#   --commit                git init DEST and make the one initial commit (author and committer: the owner)
#
# The source is cloned read-only into a temporary folder that is deleted at the end; nothing is pushed anywhere.
# Steps: clone -> tools/snapshot/snapshot.py (copy public files, overlay oneTake files, rewrite for prebuilt
# engines) -> tools/snapshot/leak-scan.py (maintainer-only text, rules read from the temporary clone) -> report.
# The report (DEST/../snapshot-report.txt) lists what was copied, what was left out and why, every rewrite, leak-scan
# findings and lines that still name old engine paths.
# Exit 0 when the tree is ready to publish, 1 when a rewrite failed or the leak scan found something, 2 on bad input.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
source_url=https://github.com/marshiyar/mpvfx-swift-agentic.git
ref=main
wait_for=71,72,74,73,69,70,62
fixtures=--engine-fixtures=copy
commit=no
while [ $# -gt 0 ]; do
  case "$1" in
    --source) source_url=$2; shift 2 ;;
    --ref) ref=$2; shift 2 ;;
    --wait-for) wait_for=$2; shift 2 ;;
    --engine-fixtures=omit|--engine-fixtures=copy) fixtures=$1; shift ;;
    --commit) commit=yes; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "make-snapshot: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || { echo "usage: make-snapshot.sh [options] DEST (see --help)" >&2; exit 2; }
dest=$1
if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
  echo "make-snapshot: $dest exists and is not empty" >&2; exit 2
fi
mkdir -p "$dest"; dest=$(cd "$dest" && pwd)
report="$(dirname "$dest")/snapshot-report.txt"

# 1. The pull requests that must land before the snapshot.
if [ "$wait_for" != none ]; then
  repo=$(printf '%s\n' "$source_url" | sed -n 's|^https://github.com/\([^/]*/[^/.]*\)\(\.git\)\{0,1\}$|\1|p')
  [ -n "$repo" ] || { echo "make-snapshot: cannot tell the GitHub repository of $source_url; pass --wait-for none" >&2; exit 2; }
  open=""
  for n in $(printf '%s' "$wait_for" | tr ',' ' '); do
    if command -v gh >/dev/null 2>&1 && merged=$(gh api "repos/$repo/pulls/$n" --jq 'if .merged then "yes" else "no" end' 2>/dev/null); then
      :
    else merged=$(python3 -I -c '
import json, sys, urllib.request
import os
headers = {"Accept": "application/vnd.github+json", "User-Agent": "make-snapshot"}
token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
if token:
    headers["Authorization"] = f"Bearer {token}"   # needed once the source repository is private
req = urllib.request.Request(f"https://api.github.com/repos/{sys.argv[1]}/pulls/{sys.argv[2]}", headers=headers)
try:
    print("yes" if json.load(urllib.request.urlopen(req, timeout=30)).get("merged") else "no")
except Exception as e:
    print(f"unknown ({e})")
' "$repo" "$n")
    fi
    echo "make-snapshot: $repo#$n merged: $merged"
    [ "$merged" = yes ] || open="$open #$n"
  done
  if [ -n "$open" ]; then
    echo "make-snapshot: not merged yet:$open. Take the snapshot after they land (or pass --wait-for none)." >&2
    exit 1
  fi
fi

# 2. Read-only clone of the source.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "make-snapshot: cloning $source_url ($ref)"
git clone -q --depth 1 --branch "$ref" "$source_url" "$work/source"
head=$(git -C "$work/source" rev-parse HEAD)

# 3. Public tree, overlay and rewrites.
status=0
python3 -I -B "$here/snapshot/snapshot.py" $fixtures "$work/source" "$dest" || status=1

# 4. Leak scan, with the private rules read from the temporary clone.
{
  echo
  echo "Leak scan"
} >> "$report"
if python3 -I -B "$here/snapshot/leak-scan.py" --root "$dest" --private "$work/source" > "$work/leaks.txt" 2> "$work/leaks.err"; then
  cat "$work/leaks.err" >> "$report"
else
  status=1
  { sed 's/^/  ! /' "$work/leaks.txt"; cat "$work/leaks.err"; } >> "$report"
fi
cat "$work/leaks.err"

# 5. Optional fresh history: one initial commit by the owner.
if [ "$commit" = yes ]; then
  if [ "$status" -ne 0 ]; then
    echo "make-snapshot: not committing: fix the problems in $report first" >&2
  else
    git -C "$dest" init -q -b main
    git -C "$dest" add -A
    GIT_AUTHOR_NAME="Arshiya Rahgozar" GIT_AUTHOR_EMAIL="57055687+marshiyar@users.noreply.github.com" \
    GIT_COMMITTER_NAME="Arshiya Rahgozar" GIT_COMMITTER_EMAIL="57055687+marshiyar@users.noreply.github.com" \
      git -C "$dest" -c commit.gpgsign=false commit -q -m "MpVFX: the open app, with prebuilt engines" \
      -m "The editor's source, tests, documentation, installers and CI. The media and keyframe engines are proprietary libraries the build downloads by version and SHA-256 (mpvfx-swift/binaries.lock)."
    echo "make-snapshot: committed $(git -C "$dest" rev-parse --short HEAD) in $dest (nothing pushed)"
  fi
fi

echo "make-snapshot: snapshot of $head in $dest; report: $report"
[ "$status" -eq 0 ] && echo "make-snapshot: ready" || echo "make-snapshot: NOT ready (see the report)"
exit $status

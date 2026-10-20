#!/usr/bin/env python3
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
"""codex_patch.py <comment body file> <patch out file>: the one unified diff in a Codex reply, checked before use.

Exit 0 with the patch written when the reply holds exactly one ```diff block that is a text-only unified diff of at
most MAX_BYTES, touches at most MAX_FILES files, and changes nothing under the refused paths (workflows, the scripts
that run with repository tokens or signing credentials, the security policy files, the engine lock): those stay
changes a person reviews.
Exit 1 with the reason on stdout otherwise (nothing to apply). Exit 2 on bad arguments.
"""
import re, sys

MAX_BYTES = 200_000
MAX_FILES = 40
# Also every script a job with credentials runs: publish.sh (contents: write), and in the macOS signing job the
# signing checks and packaging, the Metal toolchain set-up and the engine fetch (they run with the imported signing
# identity and the notarization secrets).
REFUSED = re.compile(r"^(\.github/workflows/|\.github/ci/(agentbot|codex_patch|sentinel|strip-check)\.py$|"
                     r"\.github/ci/(publish|metal-toolchain)\.sh$|mpvfx-swift/packaging/macos/|"
                     r"mpvfx-swift/scripts/fetch-binaries\.py$|"
                     r"\.github/sentinel|\.github/dependabot\.yml$|\.github/CODEOWNERS$|\.codex/|\.claude/|"
                     r"mpvfx-swift/binaries\.lock$)")
BLOCK = re.compile(r"```diff[ \t]*\n(.*?)\n```", re.S)
HEADER = re.compile(r"^diff --git a/(\S+) b/(\S+)$")
HUNK = re.compile(r"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@")
# Lines git writes between a `diff --git` header and its first hunk.
EXTENDED = re.compile(r"^(index |old mode |new mode |deleted file mode |new file mode |similarity index |"
                      r"dissimilarity index )")
NAMED = re.compile(r"^(rename from|rename to|copy from|copy to) (\S+)$")


def sections(patch):
    """(paths, None) or (None, reason): every path the patch names, read the way `git apply` reads it. Each section
    starts with `diff --git`; its `---`, `+++`, rename and copy lines must name that section's files; hunks are
    consumed by their line counts. Any other line outside a hunk is refused, so no section can hide from the check."""
    lines = patch.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    paths, current, i = set(), None, 0
    while i < len(lines):
        line = lines[i]
        m = HEADER.match(line)
        if m:
            current = {m.group(1), m.group(2)}
            paths |= current
            i += 1
            continue
        if current is None:
            return None, "no `diff --git` header: not a unified git diff"
        if line.startswith(("--- ", "+++ ")):
            name = line[4:]
            if name != "/dev/null":
                if not name.startswith(("a/", "b/")) or name[2:] not in current:
                    return None, f"`{line}` is not the file its `diff --git` header names"
            i += 1
            continue
        n = NAMED.match(line)
        if n:
            if n.group(2) not in current:
                return None, f"`{line}` is not the file its `diff --git` header names"
            i += 1
            continue
        if EXTENDED.match(line):
            i += 1
            continue
        h = HUNK.match(line)
        if not h:
            return None, f"unexpected line outside a hunk: `{line[:80]}`"
        old = int(h.group(1) or "1") if h.group(1) != "0" else 0
        new = int(h.group(2) or "1") if h.group(2) != "0" else 0
        i += 1
        while (old > 0 or new > 0) and i < len(lines):
            body = lines[i]
            if body.startswith(" ") or body == "":
                old, new = old - 1, new - 1
            elif body.startswith("-"):
                old -= 1
            elif body.startswith("+"):
                new -= 1
            elif not body.startswith("\\"):
                return None, f"a hunk ends early at `{body[:80]}`"
            i += 1
        if old != 0 or new != 0:
            return None, "a hunk's line counts do not match its lines"
        while i < len(lines) and lines[i].startswith("\\"):
            i += 1
    if not paths:
        return None, "no `diff --git` header: not a unified git diff"
    return paths, None


def extract(body):
    """(patch, None) or (None, reason)."""
    blocks = BLOCK.findall(body)
    if len(blocks) != 1:
        return None, f"expected one diff block, found {len(blocks)}"
    patch = blocks[0] + "\n"
    if len(patch.encode()) > MAX_BYTES:
        return None, f"the patch is over {MAX_BYTES:,} bytes"
    if "GIT binary patch" in patch or "\nBinary files " in patch:
        return None, "the patch changes a binary file"
    paths, reason = sections(patch)
    if reason:
        return None, reason
    if len(paths) > MAX_FILES:
        return None, f"the patch touches {len(paths)} files (limit {MAX_FILES})"
    for p in sorted(paths):
        if p.startswith("/") or ".." in p.split("/"):
            return None, f"a path leaves the repository: {p}"
        if REFUSED.match(p):
            return None, f"`{p}` is a path a person changes, not an automatic patch"
    return patch, None


def main(argv):
    if len(argv) != 3:
        print(__doc__.split("\n")[0], file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        patch, reason = extract(f.read())
    if reason:
        print(reason)
        return 1
    with open(argv[2], "w", encoding="utf-8") as f:
        f.write(patch)
    print(f"patch: {len(patch.encode()):,} bytes, {len(sections(patch)[0])} files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

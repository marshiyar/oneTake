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
that run with repository tokens, the security policy files, the engine lock): those stay changes a person reviews.
Exit 1 with the reason on stdout otherwise (nothing to apply). Exit 2 on bad arguments.
"""
import re, sys

MAX_BYTES = 200_000
MAX_FILES = 40
REFUSED = re.compile(r"^(\.github/workflows/|\.github/ci/(agentbot|codex_patch|sentinel|strip-check)\.py$|"
                     r"\.github/sentinel|\.github/dependabot\.yml$|\.github/CODEOWNERS$|\.codex/|\.claude/|"
                     r"mpvfx-swift/binaries\.lock$)")
BLOCK = re.compile(r"```diff[ \t]*\n(.*?)\n```", re.S)
HEADER = re.compile(r"^diff --git a/(\S+) b/(\S+)$", re.M)


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
    paths = sorted({p for pair in HEADER.findall(patch) for p in pair})
    if not paths:
        return None, "no `diff --git` header: not a unified git diff"
    if len(paths) > MAX_FILES:
        return None, f"the patch touches {len(paths)} files (limit {MAX_FILES})"
    for p in paths:
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
    print(f"patch: {len(patch.encode()):,} bytes, {len(set(HEADER.findall(patch)))} files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

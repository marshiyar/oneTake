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
"""Every in-house source file opens with the copyright block (LICENSE).

Usage, from the repository root:
  python3 -I -B mpvfx-swift/scripts/copyright.py          # check: exit 1 and list each file without the block
  python3 -I -B mpvfx-swift/scripts/copyright.py --fix    # add the block where it is missing

The block (block_lines below, in the file's comment syntax) goes after a shebang, `// swift-tools-version` or `@echo off`
line when the file has one; --fix also replaces the one-line header an earlier revision wrote.
Not covered: test fixtures and files a generator writes whose output CI checks against it (their
generator carries the block; see GENERATED).
"""
import os, subprocess, sys

FRAME = "===----------------------------------------------------------------------==="
# The app continues the Apache-2.0 mpvfx app and is dual licensed (LICENSE).
OPEN_TEXT = ["Copyright (c) 2026 Arshiya Rahgozar.", "",
             "Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or",
             "http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT",
             "or http://opensource.org/licenses/MIT), at your option.", "",
             "SPDX-License-Identifier: MIT OR Apache-2.0"]
PRIVATE_TEXT = ["Copyright (c) 2026 Arshiya Rahgozar. All rights reserved.", "",
                "Proprietary. No licence to use, copy, modify or distribute this file is",
                "granted except in writing by the copyright holder (see LICENSE).", "",
                "SPDX-License-Identifier: LicenseRef-MpVFX"]
PRIVATE = ()   # every file in this repository is under the app licence
OLD_LINE = "Copyright (c) 2026 Arshiya Rahgozar. All rights reserved. SPDX-License-Identifier: LicenseRef-MpVFX"


def text_for(path):
    return PRIVATE_TEXT if path.startswith(PRIVATE) else OPEN_TEXT


COMMENT = {".swift": "//", ".rs": "//", ".c": "//", ".h": "//", ".m": "//", ".metal": "//", ".hlsl": "//",
           ".glsl": "//", ".comp": "//", ".js": "//", ".mjs": "//", ".ts": "//", ".py": "#", ".sh": "#",
           ".ps1": "#", ".cmd": "::"}
SKIP = ()
# Written by mpvfx-swift/scripts/gpu/gen-compute-shaders.py and compared with it by `--check` in the gate.
GENERATED = {"mpvfx-swift/Sources/CMpvfxVulkan/mpvfx_grade_spirv.h", "mpvfx-swift/Sources/CMpvfxWin32/mpvfx_grade_hlsl.h"}
GENERATED_DIRS = ("mpvfx-swift/scripts/gpu/generated/",)
# First lines that must stay first: the block goes after them.
KEEP_FIRST = ("#!", "// swift-tools-version", "@echo off", "# -*- coding")


def covered(path):
    ext = os.path.splitext(path)[1]
    if ext not in COMMENT or path.startswith(SKIP) or "/fixtures/" in path or "/EngineFixtures/" in path or path in GENERATED:
        return False
    return not path.startswith(GENERATED_DIRS)


def block_lines(path, eol):
    c = COMMENT[os.path.splitext(path)[1]]
    frame = f":: {FRAME}" if c == "::" else f"{c}{FRAME}{c[::-1]}"
    body = [c, f"{c} This source file is part of MpVFX.", c] + [f"{c} {t}" if t else c for t in text_for(path)] + [c]
    return [line + eol for line in [frame, *body, frame]]


def has_block(path, text):
    eol = "\r\n" if "\r\n" in text else "\n"
    return "".join(block_lines(path, eol)) in text[:2000]


def strip_old(lines):
    """Lines without an earlier header: the one-line form, or a block of either kind."""
    out, i = [], 0
    while i < len(lines):
        if OLD_LINE in lines[i]:
            i += 1
            continue
        if FRAME in lines[i] and i + 1 < len(lines) and any("This source file is part of MpVFX." in l for l in lines[i:i + 4]):
            j = i + 1
            # The old block ends at its closing frame line; one that lost it ends at its last comment line, so a
            # missing frame never takes the code below it.
            while j < len(lines) and FRAME not in lines[j] and lines[j].lstrip().startswith(("//", "#", "::", "<!--", "--", ";")):
                j += 1
            i = j + 1 if j < len(lines) and FRAME in lines[j] else j
            continue
        out.append(lines[i])
        i += 1
    return out


def with_block(path, text):
    # The file's own line ending (the Windows .cmd and .ps1 files are CRLF, .gitattributes).
    eol = "\r\n" if "\r\n" in text else "\n"
    lines = strip_old(text.splitlines(keepends=True))
    at = 0
    while at < len(lines) and lines[at].startswith(KEEP_FIRST):
        at += 1
    return "".join(lines[:at] + block_lines(path, eol) + lines[at:])


def main(argv=None):
    fix = "--fix" in (argv if argv is not None else sys.argv[1:])
    files = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split("\n")
    missing = []
    for path in filter(covered, filter(None, files)):
        if not os.path.isfile(path):
            continue
        text = open(path, encoding="utf-8", newline="").read()
        if has_block(path, text):
            continue
        if fix:
            open(path, "w", encoding="utf-8", newline="").write(with_block(path, text))
        missing.append(path)
    if missing and not fix:
        print("\n".join(missing))
    verb = "added the copyright block to" if fix else "missing the copyright block:"
    print(f"copyright: {len(missing)} files {verb}" if missing else "copyright: every source file opens with the block")
    return 1 if missing and not fix else 0


if __name__ == "__main__":
    sys.exit(main())

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
"""platforms.py <files.txt>: which jobs of mpvfx-ci.yml a pull request needs, from the files it changes.

<files.txt> holds one repository path per line (both sides of a rename). Prints, for $GITHUB_OUTPUT:
  code=true|false      false: documentation only, every job is skipped
  linux=, windows=, macos=true|false   whether that platform's build, package and test jobs run
The fast Linux checks job runs whenever code is true. Each file maps to the platforms whose build it can change
(RULES, first match wins); a file no rule names is shared and runs every platform. An empty list, or one of 3000
files or more (where the pull request files API stops), runs everything.
"""
import re
import sys

PLATFORMS = ("linux", "windows", "macos")
ALL = frozenset(PLATFORMS)
DOCS = None          # no job at all
NONE = frozenset()   # only the checks job

# Paths are relative to the repository root; S = the package's Sources/.
S = "mpvfx-swift/Sources/"
RULES = [
    # VisualSpecTests reads the colour table of DESIGN.md: code, not documentation.
    (r"mpvfx-swift/docs/DESIGN\.md", ALL),
    (
        (
            r".*\.md|mpvfx-swift/docs/.*|LICENSE|LICENSE-MIT|LICENSE-APACHE|NOTICE|(.*/)?\.gitignore"
            r"|\.github/(ISSUE_TEMPLATE/.*|CODEOWNERS|FUNDING\.yml)"
        ),
        DOCS,
    ),
    # CI: the workflow that runs the builds, and the scripts its build and test jobs call.
    (r"\.github/workflows/mpvfx-ci\.yml", ALL),
    (r"\.github/workflows/mpvfx-macos\.yml", {"macos"}),
    (r"\.github/ci/test-shards\.py", ALL),
    (r"\.github/ci/run-shard\.py", {"linux", "windows"}),
    (r"\.github/ci/metal-toolchain\.sh", {"macos"}),
    # This file decides what the pull request that changes it runs, so a change to it runs everything.
    (r"\.github/ci/platforms\.py", ALL),
    # Workflows and scripts no build job uses: their own tests run in the checks job (or their own workflow).
    (r"\.github/workflows/.*|\.github/ci/.*|\.github/(dependabot\.yml|sentinel\.toml|sentinel-baseline/.*)", NONE),
    (r"\.claude/.*|\.codex/.*", NONE),
    (r"mpvfx-swift/scripts/(copyright|test_fetch_binaries)\.py", NONE),
    # Installers.
    (r"mpvfx-swift/packaging/linux/.*", {"linux"}),
    (r"mpvfx-swift/packaging/windows/.*", {"windows"}),
    (r"mpvfx-swift/packaging/macos/.*", {"macos"}),
    # Linux-only targets: CGtk3 and CPulse are dependencies only on Linux, CVulkan and CMpvfxVulkan exist only in a
    # Linux manifest (Package.swift).
    (S + r"(CGtk3|CPulse|CVulkan|CMpvfxVulkan)/.*", {"linux"}),
    # CMpvfxWin32 is compiled everywhere but each file is inside #ifdef _WIN32: Linux checks the empty side.
    (S + r"CMpvfxWin32/.*", {"windows", "linux"}),
    # The Vulkan and Direct3D 11 kernels are generated from the Metal shading body, and CMpvfxColorShared includes
    # MpvfxColorShared.h: the shaders are shared. The rest of MpvfxMetal is in the macOS manifest only.
    (S + r"MpvfxMetal/Shaders/.*", ALL),
    (S + r"MpvfxMetal/.*", {"macos"}),
    # The compute kernel generator: GLSL for Linux, HLSL for Windows (the Linux tests also run the HLSL); Metal does
    # not use it.
    (r"mpvfx-swift/scripts/gpu/.*", {"linux", "windows"}),
]
COMPILED = [(re.compile(p), platforms) for p, platforms in RULES]
MAX_FILES = 3000


def platforms_of(path):
    for pattern, platforms in COMPILED:
        if pattern.fullmatch(path):
            return platforms
    return ALL


def classify(paths):
    """(code, platforms, reasons): reasons maps each platform that runs to the first file that needs it."""
    if not paths or len(paths) >= MAX_FILES:
        return True, ALL, {p: f"{len(paths)} files listed" for p in PLATFORMS}
    code, needed, reasons = False, set(), {}
    for path in paths:
        platforms = platforms_of(path)
        if platforms is DOCS:
            continue
        code = True
        for p in sorted(platforms - needed):
            reasons[p] = path
        needed |= platforms
    return code, needed, reasons


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        sys.exit(__doc__.split("\n")[0])
    with open(argv[0]) as f:
        paths = [line.strip() for line in f if line.strip()]
    code, needed, reasons = classify(paths)
    print(f"code={str(code).lower()}")
    for p in PLATFORMS:
        print(f"{p}={str(p in needed).lower()}")
        why = f"runs ({reasons[p]})" if p in needed else "not affected, skipped"
        print(f"{p}: {why}" if code else f"{p}: documentation only, skipped", file=sys.stderr)


if __name__ == "__main__":
    main()

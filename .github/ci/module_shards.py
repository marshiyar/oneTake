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
"""module_shards.py <files.txt>: which test shards a pull request must run.

Reads one repository path per line, maps each to the modules it can affect,
then to the test shards that observe those modules. Prints for $GITHUB_OUTPUT:
  shards=<comma list>   the shards to run (subset of library,audio-presets,audio-live,rest)
Leaf-only changes run one or two shards; anything shared runs all four.
Full runs (schedule, full_tests) ignore this and run every shard.
Shard contents (test-shards.py): library = LibraryServiceTests; audio-presets =
AudioFxLiveEditTests preset/export tests + short seeks; audio-live = live-edit,
seek and determinism tests; rest = everything else.
"""
import re
import sys

S = "mpvfx-swift/Sources/"
T = "mpvfx-swift/Tests/"
ALL = ("library", "audio-presets", "audio-live", "rest")

# Leaf module -> shards whose tests observe it. A module is a leaf when no
# shipped target outside its own tests depends on it (Package.swift): a change
# there cannot break another module's tests. Fan-in modules (MpvfxShared,
# MpvfxColor, MpvfxTimeline, MpvfxPlayer, MpvfxRuntime, MpvfxDesktop,
# MpvfxDesktopCore, MpvfxBackend, MpvfxPanels, MpvfxCanvas, MpvfxAudio, the
# engine adapters, binaries.lock, Package.swift) are deliberately absent, so a
# change to any of them runs every shard.
LEAVES = {
    "MpvfxScopes": ("rest",),                                    # ScopesTests, PanelsTests
    "MpvfxTheme": ("rest",),                                     # ThemeTests, Panels/Timeline/DesktopCore
    "MpvfxAudioGraph": ("audio-presets", "audio-live", "rest"),  # GraphTests, AudioTests, PanelsTests
    "CSQLite": ("rest",),                                        # CSQLiteTests (+RuntimeTests via Runtime)
    "CMpvfxColorShared": ("rest",),                              # ColorTests, GPU parity tests
    "CGtk3": ("rest",),                                          # CanvasTests (Linux)
    "CPulse": ("audio-live", "rest"),                             # Linux audio output paths
    "CVulkan": ("rest",),                                        # ComputeColorRendererTests (Linux)
    "CMpvfxVulkan": ("rest",),                                   # Vulkan renderer + parity tests
    "MpvfxMetal": ("rest",),                                     # Metal tests (macOS job only)
    "CMediaEngine": ("library", "rest"),                          # import/decode/library tests
    "CKeyframeEngine": ("rest",),                                # keyframe engine tests
}
# Test-target dirs that belong to a leaf's observers (same shard as the module).
TEST_OF = {
    "MpvfxScopesTests": "MpvfxScopes",
    "MpvfxThemeTests": "MpvfxTheme",
    "MpvfxAudioGraphTests": "MpvfxAudioGraph",
}
# Non-code files whose tests are known: DESIGN.md's colour table is checked by
# VisualSpecTests (in the rest shard). Every other doc is unmapped on purpose.
DOC_RULES = [
    (re.compile(r"mpvfx-swift/docs/DESIGN\.md"), ("rest",)),
]


def module_of(path):
    if path.startswith(S):
        return path[len(S):].split("/", 1)[0]
    if path.startswith(T):
        second = path[len(T):].split("/", 1)
        if len(second) == 2:
            return TEST_OF.get(second[0])
        return None  # unknown test layout: run all
    for pattern, shards in DOC_RULES:
        if pattern.fullmatch(path):
            return ("__doc__", shards)
    return None  # unknown: run all


def shards_for(paths):
    wanted, unknown = set(), False
    for path in paths:
        hit = module_of(path)
        if hit is None:
            unknown = True
        elif isinstance(hit, tuple):
            wanted |= set(hit[1])
        elif hit in LEAVES:
            wanted |= set(LEAVES[hit])
        else:
            unknown = True  # fan-in module or unmapped: run everything
    if unknown or not paths:
        return list(ALL)
    return [s for s in ALL if s in wanted] or list(ALL)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        sys.exit(__doc__.split("\n")[0])
    with open(argv[0]) as f:
        paths = [line.strip() for line in f if line.strip()]
    print(f"shards={','.join(shards_for(paths))}")


if __name__ == "__main__":
    main()

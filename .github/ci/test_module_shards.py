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
"""Tests for module_shards.py: leaf changes narrow, shared changes run all."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from module_shards import shards_for

ALL = ["library", "audio-presets", "audio-live", "rest"]
assert shards_for(["mpvfx-swift/Sources/MpvfxScopes/ScopeEngine.swift"]) == ["rest"]
assert shards_for(["mpvfx-swift/Tests/MpvfxScopesTests/ScopeEngineTests.swift"]) == ["rest"]
assert shards_for(["mpvfx-swift/Sources/MpvfxAudioGraph/AudioGraph.swift"]) == \
    ["audio-presets", "audio-live", "rest"]
assert shards_for(["mpvfx-swift/Sources/MpvfxShared/Project/NativeCaptionTrack.swift"]) == ALL
assert shards_for(["mpvfx-swift/Sources/MpvfxPlayer/PreviewCompositor.swift"]) == ALL
assert shards_for(["mpvfx-swift/binaries.lock"]) == ALL
assert shards_for(["mpvfx-swift/Package.swift"]) == ALL
assert shards_for(["mpvfx-swift/docs/GETTING_STARTED.md"]) == ALL  # unmapped doc: safe default
assert shards_for(["mpvfx-swift/docs/DESIGN.md"]) == ["rest"]
assert shards_for([]) == ALL
print("test_module_shards: passed")

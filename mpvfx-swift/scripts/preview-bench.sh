#!/usr/bin/env sh
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
# Preview playback benchmark (tools/MpvfxPreviewBench): one 1080p30 H.264 clip, one 4K30 clip, two 1080p clips
# stacked, a graded clip, and random seeks, each through the compositor, engine decode and canvas paint in its own
# process. Results: one JSON line per scenario appended to the results file (fps, ms per frame per stage, peak RSS).
#
# Usage: scripts/preview-bench.sh <work dir> [results file]
#   The clips are made once in <work dir> by the bench itself (MpvfxPreviewBench --make-clips), through the media
#   engine's own H.264 encoder; clips already in <work dir> are kept.
#   Fetch the engine libraries first (python3 scripts/fetch-binaries.py).
set -eu
cd "$(dirname "$0")/.."
dir="${1:?usage: scripts/preview-bench.sh <work dir> [results file]}"
out="${2:-$dir/results.jsonl}"
mkdir -p "$dir"
swift build -c release --product MpvfxPreviewBench
bench="$(swift build -c release --show-bin-path)/MpvfxPreviewBench"
"$bench" --make-clips "$dir"
for s in 1080p 4k stacked graded scrub; do "$bench" "$s" "$dir" "$out"; done
echo "results appended to $out"

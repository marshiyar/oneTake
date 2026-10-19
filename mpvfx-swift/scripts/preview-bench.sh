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
# Usage: FFMPEG=<ffmpeg> scripts/preview-bench.sh <work dir> [results file]
#   The clips are made once in <work dir> by an FFmpeg binary used as a black box (FFMPEG, outside the repository);
#   the app and its tests never run it. Without FFMPEG the clips must already be in <work dir>.
#   Fetch the engine libraries first (python3 scripts/fetch-binaries.py).
set -eu
cd "$(dirname "$0")/.."
dir="${1:?usage: FFMPEG=<ffmpeg> scripts/preview-bench.sh <work dir> [results file]}"
out="${2:-$dir/results.jsonl}"
mkdir -p "$dir"
make_clip() { # name size seconds source
  [ -f "$dir/$1" ] && return 0
  [ -n "${FFMPEG:-}" ] || { echo "missing $dir/$1 and FFMPEG is not set"; exit 2; }
  "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "$4=size=$2:rate=30,noise=alls=4:allf=t+u" -t "$3" \
    -c:v libx264 -preset medium -crf 21 -pix_fmt yuv420p "$dir/$1"
}
make_clip clip1080.mp4 1920x1080 10 testsrc2
make_clip clip1080b.mp4 1920x1080 10 mandelbrot
make_clip clip2160.mp4 3840x2160 6 testsrc2
swift build -c release --product MpvfxPreviewBench
bench="$(swift build -c release --show-bin-path)/MpvfxPreviewBench"
for s in 1080p 4k stacked graded scrub; do "$bench" "$s" "$dir" "$out"; done
echo "results appended to $out"

#!/bin/sh
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
# Captures the images of docs/GETTING_STARTED.md: the Linux shell on a copy of samples/getting-started, 1440x900
# on a virtual display (Xvfb), each state set up by the app's MPVFX_SMOKE_* hooks and written by its own snapshot.
# Every run starts from fresh user data with the timeline at 500% zoom. Usage: sh scripts/capture-getting-started.sh
set -eu
cd "$(dirname "$0")/.."
bin=.build/out/Products/Debug-linux-x86_64/MpVFX
[ -x "$bin" ] || { echo "build first: python3 scripts/fetch-binaries.py && swift build"; exit 2; }
out=docs/images/getting-started
mkdir -p "$out"
work=$(mktemp -d)

# shot <name> <inspector group or -> [VAR=value ...]
shot() {
  name=$1; group=$2; shift 2
  mkdir -p "$work/$name/userData"
  cp -R samples/getting-started "$work/$name/project"
  echo '{"timelineManualZoomPercent":500,"timelineZoomMode":"manual"}' > "$work/$name/userData/timeline-ui.json"
  if [ "$group" != - ]; then echo "{\"openInspectorGroup\":\"$group\"}" > "$work/$name/userData/panel-layout.json"; fi
  env MPVFX_USER_DATA_DIR="$work/$name/userData" MPVFX_PROJECT="$work/$name/project" MPVFX_AUDIO_OUTPUT=null \
    MPVFX_SMOKE_SNAPSHOT="$PWD/$out/$name.png" MPVFX_SMOKE_SEEK=2 "$@" \
    xvfb-run -a -s "-screen 0 1440x900x24" "$PWD/$bin" > "$work/$name.log" 2>&1
  echo "wrote $out/$name.png"
}

shot open - MPVFX_SMOKE_DELAY_MS=6000
shot cut - MPVFX_SMOKE_RAZOR=466,100 MPVFX_SMOKE_DELAY_MS=6000
shot grade grade MPVFX_SMOKE_SELECT=clip:1 MPVFX_SMOKE_DELAY_MS=6000
shot export - MPVFX_SMOKE_EXPORT=1 MPVFX_SMOKE_DELAY_MS=20000
rm -rf "$work"

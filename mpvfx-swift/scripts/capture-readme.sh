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
# Captures the README image: the Linux shell with the built-in demo timeline on a 1440x900 virtual display
# (Xvfb), after a fresh `swift build`. Synthetic data only (the demo document; its media files do not exist, so
# the preview shows the empty frame). Usage: sh scripts/capture-readme.sh
set -eu
cd "$(dirname "$0")/.."
bin=.build/out/Products/Debug-linux-x86_64/MpVFX
[ -x "$bin" ] || { echo "build first: python3 scripts/fetch-binaries.py && swift build"; exit 2; }
home=$(mktemp -d)
out=docs/images/readme/editor-demo-1440x900@1x.png
cat > "$home/run.sh" <<RUN
#!/bin/sh
MPVFX_DEMO=1 MPVFX_AUDIO_OUTPUT=null HOME="$home" "$PWD/$bin" > "$home/app.log" 2>&1 &
pid=\$!
sleep 12
import -window root "$PWD/$out"
kill \$pid
RUN
xvfb-run -a -s "-screen 0 1440x900x24" sh "$home/run.sh"
rm -rf "$home"
echo "wrote $out"

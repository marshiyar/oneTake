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
# Claude Code SessionStart hook. Two steps, both optional, neither fails the session:
#   1. Maintainer setup: when a maintainer checkout provides .maintainer/setup.sh (git-ignored, not part of this
#      repository), run it; it may install extra instructions and hooks into git-ignored paths.
#   2. Engine libraries: fetch the prebuilt engines pinned in mpvfx-swift/binaries.lock, so `swift build` works.
# Contributors without the maintainer setup get step 2 only. Output goes to stderr (shown in the session log).
root=${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}

setup="$root/.maintainer/setup.sh"
if [ -f "$setup" ]; then
  sh "$setup" "$root" 1>&2 || echo "session-start: $setup failed (exit $?); continuing without it" >&2
fi

if command -v python3 >/dev/null 2>&1 && [ -f "$root/mpvfx-swift/binaries.lock" ]; then
  (cd "$root/mpvfx-swift" && python3 -I -B scripts/fetch-binaries.py 1>&2) ||
    echo "session-start: engine libraries not fetched (see above); swift build needs them" >&2
fi
exit 0

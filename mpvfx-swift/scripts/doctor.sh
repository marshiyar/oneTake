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
# Check prerequisites: names every tool and library a full `scripts/check.sh` run needs that this machine lacks,
# with the fix. Usage: scripts/doctor.sh     Exit 0 = ready, 2 = something is missing (the check is UNAVAILABLE
# here, not FAILED). Without it a missing prerequisite surfaced only after a long build, as build or Vulkan test
# failures.
set -u
cd "$(dirname "$0")/.." || exit 2
missing=0
need() { echo "MISSING: $1"; echo "  fix: $2"; missing=1; }

command -v python3 >/dev/null 2>&1 ||
  need "python3" "install Python 3 (scripts/fetch-binaries.py downloads the engine libraries)"
command -v swift >/dev/null 2>&1 ||
  need "swift" "install the Swift toolchain from https://www.swift.org/install"

if [ "$(uname -s)" = "Linux" ]; then
  for pc in gtk+-3.0 sqlite3; do
    pkg-config --exists "$pc" 2>/dev/null ||
      need "pkg-config module $pc" "apt-get install pkg-config libgtk-3-dev libsqlite3-dev"
  done
  # Optional, as in Package.swift: audio output builds only with the PulseAudio headers.
  pkg-config --exists libpulse-simple 2>/dev/null ||
    echo "note: no libpulse-simple; the app builds without audio output (apt-get install libpulse-dev)"
  # Vulkan is built only when its header exists; then the GPU grade tests need a device (Mesa's llvmpipe is one).
  if [ -f /usr/include/vulkan/vulkan.h ]; then
    icd=no
    for f in /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json; do [ -f "$f" ] && icd=yes; done
    [ "$icd" = yes ] ||
      need "a Vulkan driver (ICD)" "apt-get install mesa-vulkan-drivers"
  fi
fi

if [ $missing -ne 0 ]; then echo "doctor: NOT READY"; exit 2; fi
echo "doctor: ready"

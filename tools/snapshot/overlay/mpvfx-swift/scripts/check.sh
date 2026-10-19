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
# check.sh [--fast]: the checks a contributor runs before pushing (CI runs the same and more).
#   engine libraries fetched and verified (binaries.lock), fetch script tests, copyright blocks,
#   generated GPU shaders current (when glslangValidator and spirv-opt are installed),
#   swift build and swift test (skipped with --fast).
# Exit 0 when every check passed.
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0
run() { echo "== $*"; "$@" || { echo "FAILED: $*"; fail=1; }; }

run python3 -I -B scripts/fetch-binaries.py
run python3 -I -B scripts/test_fetch_binaries.py
run sh -c "cd .. && python3 -I -B mpvfx-swift/scripts/copyright.py"
if command -v glslangValidator >/dev/null 2>&1 && command -v spirv-opt >/dev/null 2>&1; then
  run python3 -I -B scripts/gpu/gen-compute-shaders.py --check
else
  echo "== generated shader check skipped: glslangValidator / spirv-opt not installed"
fi
if [ "${1:-}" != "--fast" ]; then
  run swift build
  run swift test
fi

if [ $fail -ne 0 ]; then echo "check: FAILED"
elif [ "${1:-}" = "--fast" ]; then echo "check: passed (--fast: swift build and swift test not run)"
else echo "check: passed"; fi
exit $fail

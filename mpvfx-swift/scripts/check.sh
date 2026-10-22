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
# check.sh [--fast|--build]: the checks a contributor runs before pushing (CI runs the same and more).
#   engine libraries fetched and verified (binaries.lock), fetch script tests, copyright blocks,
#   generated GPU shaders current (when glslangValidator and spirv-opt are installed),
#   swift build (with CI's -warnings-as-errors -Werror) and swift test; --fast skips both, --build skips the tests.
#   SWIFT names the swift driver (default swift; /opt/swift/swiftq on the shared agent machine).
# Exit 0 when every check passed, 1 when one failed, 2 = UNAVAILABLE: a full run's prerequisites are missing
# (scripts/doctor.sh names them).
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0
run() { echo "== $*"; "$@" || { echo "FAILED: $*"; fail=1; }; }
# a full run needs its prerequisites; without one the verdict is UNAVAILABLE in seconds, not FAILED after the build
if [ "${1:-}" != "--fast" ]; then
  sh scripts/doctor.sh || { echo "check: UNAVAILABLE (prerequisites missing; see doctor above)"; exit 2; }
fi

run python3 -I -B scripts/fetch-binaries.py
run python3 -I -B scripts/test_fetch_binaries.py
run python3 -I -B scripts/check-design-wording.py
run python3 -I -B scripts/test_design_wording.py
run sh -c "cd .. && python3 -I -B mpvfx-swift/scripts/copyright.py"
if command -v glslangValidator >/dev/null 2>&1 && command -v spirv-opt >/dev/null 2>&1; then
  run python3 -I -B scripts/gpu/gen-compute-shaders.py --check
else
  echo "== generated shader check skipped: glslangValidator / spirv-opt not installed"
fi
# The same strict flags as CI's build jobs, so a warning fails here before it fails a push.
strict="-Xswiftc -warnings-as-errors -Xcc -Werror"
if [ "${1:-}" != "--fast" ]; then
  run ${SWIFT:-swift} build --build-tests $strict
  [ "${1:-}" = "--build" ] || run ${SWIFT:-swift} test $strict
fi

if [ $fail -ne 0 ]; then echo "check: FAILED"
elif [ "${1:-}" = "--fast" ]; then echo "check: passed (--fast: swift build and swift test not run)"
elif [ "${1:-}" = "--build" ]; then echo "check: passed (--build: strict build, swift test not run)"
else echo "check: passed"; fi
exit $fail

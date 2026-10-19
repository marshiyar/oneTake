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
# metal-toolchain.sh: make `xcrun metal` runnable on a macOS runner. Since Xcode 26 the Metal compiler is a separate
# component that the runner images do not include. Downloaded with sudo it stays unusable for the runner user (run
# 39201481367: "Done downloading: Metal Toolchain 27A266a", then "cannot execute tool 'metal' due to missing Metal
# Toolchain"), so it is fetched as the runner user, and imported from an export when the plain download leaves it
# unregistered (the route Apple's developer forums give for command-line builds).
set -eu
ok() { xcrun -sdk macosx metal --version >/dev/null 2>&1; }
ok && { xcrun -sdk macosx metal --version | head -1; exit 0; }
for i in 1 2 3; do
  xcodebuild -downloadComponent MetalToolchain && ok && break
  echo "metal-toolchain: download attempt $i left metal unusable"; sleep 10
done
if ! ok; then
  export_dir="${RUNNER_TEMP:-/tmp}/metal-toolchain-export"
  rm -rf "$export_dir"
  xcodebuild -downloadComponent MetalToolchain -exportPath "$export_dir"
  for bundle in "$export_dir"/*.exportedBundle; do
    xcodebuild -importComponent MetalToolchain -importPath "$bundle"
  done
fi
ok || { echo "metal-toolchain: xcrun metal still unusable after download and import" >&2; exit 1; }
xcrun -sdk macosx metal --version | head -1

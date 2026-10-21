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
"""Reject title-case Design control labels without inspecting document identifiers."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1] / "Sources" / "MpvfxPanels"
# Coordinate names and established abbreviations retain their spelling.
PROPER = {"ASCII", "CRT", "LUT", "RGB", "FX", "X", "Y", "Z", "3D"}
PATTERNS = [r'\("[a-z][a-zA-Z0-9-]*", "([^"\\]+)"',r'(?:label|masterLabel|title): "([^"\\]+)"',
            r'(?:row|slider|field|percent|degrees)\("[^"\\]+", "([^"\\]+)"']


def violations(root=ROOT):
    failures = []
    files = sorted(root.glob("InspectorPanel*.swift")) + [root / "EffectSpecs.swift", root / "ColorGrading.swift"]
    for path in files:
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("//") or '.init(id:' in line:
                continue  # Named presets are proper names, e.g. Warm Daylight.
            labels = {label for pattern in PATTERNS for label in re.findall(pattern, line)}
            for label in sorted(labels):
                for word in label.split()[1:]:
                    if word.strip("…:()") not in PROPER and word[:1].isupper():
                        failures.append(f"{path.name}:{line_number}: {label}")
                        break
    return failures


if __name__ == "__main__":
    errors = violations()
    print("\n".join(errors) if errors else "Design labels use sentence case")
    sys.exit(bool(errors))

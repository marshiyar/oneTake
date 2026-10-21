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
"""Regression tests for the Design display-label scanner."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("wording", Path(__file__).with_name("check-design-wording.py"))
wording = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wording)


class DesignWordingScannerTests(unittest.TestCase):
    def scan(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["InspectorPanel.swift", "EffectSpecs.swift", "ColorGrading.swift"]:
                (root / name).write_text(source if name == "InspectorPanel.swift" else "")
            return wording.violations(root)

    def test_rejects_title_case_for_direct_and_positional_labels(self):
        self.assertEqual(len(self.scan('row("whitePoint", "White Point")\nlabel: "Use Source Color"')), 2)

    def test_allows_sentence_case_acronyms_and_preset_names(self):
        source = 'label: "Import LUT…"\nlabel: "Tilt X"\nrow("waveFrequency", "Wave frequency")\n.init(id: "warm-daylight", label: "Warm Daylight")'
        self.assertEqual(self.scan(source), [])

    def test_current_design_labels(self):
        self.assertEqual(wording.violations(), [])


if __name__ == "__main__":
    unittest.main()

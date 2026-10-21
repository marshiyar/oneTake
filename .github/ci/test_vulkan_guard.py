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
"""Tests for vulkan-guard.py and the workflow that builds the package without the Vulkan headers (issue #78)."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
spec = importlib.util.spec_from_file_location("vulkan_guard", os.path.join(HERE, "vulkan-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class Scan(unittest.TestCase):
    def test_use_under_os_linux_is_a_finding(self):
        text = "#if os(Linux)\nlet r = try VulkanColorRenderer(allowSoftware: true)\n#endif\n"
        self.assertEqual(guard.scan(text), [2])

    def test_use_under_can_import_is_allowed(self):
        text = "#if canImport(CMpvfxVulkan)\nimport CMpvfxVulkan\nlet r = try VulkanColorRenderer()\nvkDestroyDevice(d, nil)\n#endif\n"
        self.assertEqual(guard.scan(text), [])

    def test_else_branch_of_can_import_is_not_guarded(self):
        text = "#if canImport(CMpvfxVulkan)\nlet a = 1\n#else\nlet r = VulkanColorRenderer()\n#endif\n"
        self.assertEqual(guard.scan(text), [4])

    def test_negated_can_import_is_not_guarded(self):
        text = "#if !canImport(CMpvfxVulkan)\nlet r = VulkanColorRenderer()\n#endif\n"
        self.assertEqual(guard.scan(text), [2])

    def test_nested_inside_can_import_is_allowed(self):
        text = "#if canImport(CMpvfxVulkan)\n#if os(Linux)\nlet r = VulkanColorRenderer()\n#endif\n#endif\n"
        self.assertEqual(guard.scan(text), [])

    def test_or_condition_does_not_guard(self):
        # `canImport(CMpvfxVulkan) || os(Windows)` is true on Windows too, where the type does not exist.
        text = "#if canImport(CMpvfxVulkan) || os(Windows)\nlet r = VulkanColorRenderer()\n#endif\n"
        self.assertEqual(guard.scan(text), [2])

    def test_and_followed_by_or_does_not_guard(self):
        # `&&` binds tighter: the condition is true on Windows without CMpvfxVulkan.
        text = "#if canImport(CMpvfxVulkan) && os(Linux) || os(Windows)\nlet r = VulkanColorRenderer()\n#endif\n"
        self.assertEqual(guard.scan(text), [2])

    def test_and_alone_guards(self):
        text = "#if canImport(CMpvfxVulkan) && os(Linux)\nlet r = VulkanColorRenderer()\n#endif\n"
        self.assertEqual(guard.scan(text), [])

    def test_comments_and_strings_are_ignored(self):
        text = '/// `VulkanColorRenderer` on Linux\nlet s = "VulkanColorRenderer"  // VulkanColorRenderer\n'
        self.assertEqual(guard.scan(text), [])


    def test_elseif_can_import_branch_is_guarded(self):
        text = "#if os(macOS)\nlet a = 1\n#elseif canImport(CMpvfxVulkan)\nlet r = VulkanColorRenderer()\n#else\nlet v = VulkanColorRenderer()\n#endif\n"
        self.assertEqual(guard.scan(text), [6])

    def test_block_comment_after_code_spanning_lines_is_ignored(self):
        text = "let a = 1 /* VulkanColorRenderer\n   vkCreateDevice /* nested */ VulkanColorRenderer\n*/ let b = 2\nlet r = VulkanColorRenderer()\n"
        self.assertEqual(guard.scan(text), [4])

    def test_raw_and_multiline_strings_are_ignored(self):
        text = 'let j = #"{"a":"VulkanColorRenderer"}"#\nlet m = """\nVulkanColorRenderer\n"""\nlet r = VulkanColorRenderer()\n'
        self.assertEqual(guard.scan(text), [5])


class Tree(unittest.TestCase):
    def test_no_vulkan_type_outside_can_import_in_sources_or_tools(self):
        """Acceptance: no Sources/ or tools/ file uses a Vulkan type outside canImport(CMpvfxVulkan)."""
        self.assertEqual(guard.findings(os.path.join(ROOT, "mpvfx-swift")), [])


class Workflow(unittest.TestCase):
    def test_ci_builds_the_package_without_the_vulkan_headers(self):
        """Acceptance: a CI job hides the Vulkan headers, builds every target and runs the bench CPU-only."""
        with open(os.path.join(ROOT, ".github", "workflows", "linux-no-vulkan.yml")) as f:
            text = f.read()
        installs = [l for l in text.splitlines() if "libvulkan-dev" in l and not l.lstrip().startswith("#")]
        self.assertEqual(installs, [])
        self.assertIn("test ! -e /usr/include/vulkan/vulkan.h", text)
        self.assertIn("swift build --build-tests", text)
        self.assertIn("MpvfxColorBench", text)
        self.assertIn("vulkan-guard.py", text)


if __name__ == "__main__":
    unittest.main()

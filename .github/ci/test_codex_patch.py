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
"""Tests for codex_patch.py: the one diff is taken, anything risky is refused."""
import importlib.util, os, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("codex_patch", os.path.join(HERE, "codex_patch.py"))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)


def diff(path, extra=""):
    return (f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1 +1 @@\n-old\n+new{extra}")


def reply(*blocks):
    return "### Summary\n\nDone.\n\n" + "\n\n".join(f"```diff\n{b}\n```" for b in blocks) + "\n"


class Extract(unittest.TestCase):
    def test_one_docs_diff_is_taken(self):
        patch, reason = cp.extract(reply(diff("mpvfx-swift/docs/STATUS.md")))
        self.assertIsNone(reason)
        self.assertTrue(patch.startswith("diff --git a/mpvfx-swift/docs/STATUS.md"))

    def test_none_or_two_blocks_are_refused(self):
        self.assertIn("found 0", cp.extract("no patch here")[1])
        self.assertIn("found 2", cp.extract(reply(diff("a.md"), diff("b.md")))[1])

    def test_workflows_token_scripts_policy_and_lock_are_refused(self):
        for p in (".github/workflows/mpvfx-ci.yml", ".github/ci/codex_patch.py", ".github/sentinel.toml",
                  "mpvfx-swift/binaries.lock", ".claude/settings.json", ".codex/hooks.json"):
            self.assertIsNotNone(cp.extract(reply(diff(p)))[1], p)

    def test_traversal_binary_and_size_are_refused(self):
        self.assertIn("leaves", cp.extract(reply(diff("../x.md")))[1])
        self.assertIn("binary", cp.extract(reply(diff("a.png") + "\nGIT binary patch\nliteral 3"))[1])
        self.assertIn("bytes", cp.extract(reply(diff("a.md", "x" * cp.MAX_BYTES)))[1])

    def test_a_plain_text_block_without_git_headers_is_refused(self):
        self.assertIn("not a unified git diff", cp.extract("```diff\n-old\n+new\n```")[1])


if __name__ == "__main__":
    unittest.main()

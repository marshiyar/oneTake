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
        for p in (".github/workflows/mpvfx-ci.yml", ".github/ci/codex_patch.py", ".github/ci/codacy_to_codex.py",
                  ".github/sentinel.toml",
                  "mpvfx-swift/binaries.lock", ".claude/settings.json", ".codex/hooks.json",
                  ".github/ci/publish.sh", ".github/ci/metal-toolchain.sh", "mpvfx-swift/packaging/macos/package.sh",
                  "mpvfx-swift/packaging/macos/import-cert.sh", "mpvfx-swift/packaging/macos/check-signing.sh",
                  "mpvfx-swift/scripts/fetch-binaries.py"):
            self.assertIsNotNone(cp.extract(reply(diff(p)))[1], p)

    def test_traversal_binary_and_size_are_refused(self):
        self.assertIn("leaves", cp.extract(reply(diff("../x.md")))[1])
        self.assertIn("binary", cp.extract(reply(diff("a.png") + "\nGIT binary patch\nliteral 3"))[1])
        self.assertIn("bytes", cp.extract(reply(diff("a.md", "x" * cp.MAX_BYTES)))[1])

    def test_a_plain_text_block_without_git_headers_is_refused(self):
        self.assertIn("not a unified git diff", cp.extract("```diff\n-old\n+new\n```")[1])

    def test_a_section_without_its_own_header_is_refused(self):
        hidden = "--- a/.github/workflows/mpvfx-ci.yml\n+++ b/.github/workflows/mpvfx-ci.yml\n@@ -1 +1 @@\n-a\n+b"
        self.assertIn("not the file", cp.extract(reply(diff("a.md") + "\n" + hidden))[1])
        other = "diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/.github/workflows/x.yml\n@@ -1 +1 @@\n-a\n+b"
        self.assertIn("not the file", cp.extract(reply(other))[1])
        renamed = "diff --git a/a.md b/a.md\nsimilarity index 90%\nrename from a.md\nrename to .github/workflows/x.yml"
        self.assertIn("not the file", cp.extract(reply(renamed))[1])

    def test_hunks_are_read_by_their_counts(self):
        body = "diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -1,3 +1,3 @@\n ctx\n--- a dash line\n+++ kept\n end"
        self.assertIsNone(cp.extract(reply(body))[1])
        short = "diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -1,3 +1,3 @@\n ctx"
        self.assertIn("line counts", cp.extract(reply(short))[1])
        two = diff("a.md") + "\n" + diff("b.md")
        self.assertIsNone(cp.extract(reply(two))[1])


if __name__ == "__main__":
    unittest.main()

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
"""Tests for pr_hygiene.py: each limit warns past its threshold only, exclusions apply, bug fixes need a test."""
import contextlib, importlib.util, io, os, subprocess, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pr_hygiene", os.path.join(HERE, "pr_hygiene.py"))
ph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ph)

REPO = "marshiyar/oneTake"


def f(name, add=0, delete=0, prev=None):
    d = {"filename": name, "additions": add, "deletions": delete}
    if prev:
        d["previous_filename"] = prev
    return d


def warn(files, body="", labels=None):
    labels = labels or {}
    return ph.assess(files, body, REPO, lambda n: labels.get(n))[0]


class Size(unittest.TestCase):
    def test_lines_at_and_over_the_limit(self):
        self.assertEqual(warn([f("mpvfx-swift/Sources/MpvfxTimeline/A.swift", 300, 100)]), [])
        w = warn([f("mpvfx-swift/Sources/MpvfxTimeline/A.swift", 300, 101)])
        self.assertEqual(len(w), 1)
        self.assertIn("401 changed lines", w[0])

    def test_tests_fixtures_generated_do_not_count_as_lines(self):
        files = [f("mpvfx-swift/Sources/MpvfxTimeline/A.swift", 10),
                 f("mpvfx-swift/Tests/MpvfxTimelineTests/ATests.swift", 5000),
                 f(".github/ci/test_x.py", 900),
                 f("mpvfx-swift/Tests/MpvfxSharedTests/Export/Fixtures/x.json", 9000),
                 f("mpvfx-swift/Sources/MpvfxMetal/Generated/grade.comp", 3000),
                 f(".github/ci/crash-constructs-baseline.json", 600)]
        self.assertEqual([x for x in warn(files) if "lines" in x], [])

    def test_files_limit_counts_tests_but_not_fixtures(self):
        src = [f(f"mpvfx-swift/Sources/MpvfxTimeline/F{i}.swift", 1) for i in range(10)]
        tests = [f(f"mpvfx-swift/Tests/MpvfxTimelineTests/T{i}.swift", 1) for i in range(5)]
        fixtures = [f(f"mpvfx-swift/Tests/EngineFixtures/fixtures/x{i}.bin") for i in range(50)]
        self.assertEqual(warn(src + tests + fixtures), [])
        w = warn(src + tests + fixtures + [f("README.md", 1)])
        self.assertEqual(len(w), 1)
        self.assertIn("16 changed files", w[0])


class Areas(unittest.TestCase):
    def test_one_area_is_fine_two_warn(self):
        self.assertEqual(warn([f("mpvfx-swift/Sources/MpvfxTimeline/A.swift", 1),
                               f("mpvfx-swift/Sources/MpvfxTimeline/Sub/B.swift", 1),
                               f("mpvfx-swift/Tests/MpvfxPlayerTests/C.swift", 1), f(".github/x.yml", 1)]), [])
        w = warn([f("mpvfx-swift/Sources/MpvfxTimeline/A.swift", 1), f("mpvfx-swift/Sources/MpvfxPlayer/B.swift", 1)])
        self.assertEqual(len(w), 1)
        self.assertIn("MpvfxPlayer (1), MpvfxTimeline (1)", w[0])

    def test_rename_counts_both_areas(self):
        w = warn([f("mpvfx-swift/Sources/MpvfxPlayer/A.swift", prev="mpvfx-swift/Sources/MpvfxTimeline/A.swift")])
        self.assertEqual(len(w), 1)


class BugFix(unittest.TestCase):
    SRC = [f("mpvfx-swift/Sources/MpvfxTimeline/A.swift", 3)]

    def test_closing_keywords(self):
        body = "Fixes #12. closes #13, Resolved: #14 and fix marshiyar/oneTake#15; other/repo#16; see #17; Closes #12"
        self.assertEqual(ph.closed_issues(body, REPO), [12, 13, 14, 15])
        self.assertEqual(ph.closed_issues(None, REPO), [])

    def test_bug_without_test_warns(self):
        w = warn(self.SRC, "Closes #5", {5: ["bug", "timeline"]})
        self.assertEqual(len(w), 1)
        self.assertIn("#5", w[0])

    def test_bug_with_test_is_fine(self):
        self.assertEqual(warn(self.SRC + [f("mpvfx-swift/Tests/MpvfxTimelineTests/A.swift", 9)], "Closes #5",
                              {5: ["bug"]}), [])

    def test_not_a_bug_or_not_an_issue(self):
        self.assertEqual(warn(self.SRC, "Closes #5", {5: ["enhancement"]}), [])
        self.assertEqual(warn(self.SRC, "Closes #6", {}), [])      # a pull request or a missing issue: None
        self.assertEqual(warn(self.SRC, "Refs #5", {5: ["bug"]}), [])


class NeverFails(unittest.TestCase):
    def test_api_failure_is_a_warning_and_exit_zero(self):
        err = subprocess.CalledProcessError(1, ["gh"], stderr="HTTP 403")
        out = io.StringIO()
        with mock.patch.object(ph, "fetch", side_effect=err), contextlib.redirect_stdout(out), \
                mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}):
            self.assertEqual(ph.main(["--repo", REPO, "--pr", "1"]), 0)
        self.assertIn("::warning title=PR hygiene::could not read the pull request from the API: HTTP 403", out.getvalue())

    def test_issue_lookup_failure_is_an_api_warning(self):
        err = subprocess.CalledProcessError(1, ["gh"], stderr="API rate limit exceeded")
        responses = [[f("mpvfx-swift/Sources/MpvfxTimeline/A.swift", 1)], [{"body": "Fixes #5"}]]
        out = io.StringIO()
        with mock.patch.object(ph, "gh_json_lines", side_effect=[*responses, err]), contextlib.redirect_stdout(out), \
                mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}):
            self.assertEqual(ph.main(["--repo", REPO, "--pr", "1"]), 0)
        text = out.getvalue()
        self.assertIn("::warning title=PR hygiene::could not read the pull request from the API: API rate limit", text)
        self.assertIn("Not assessed: the API could not be read.", text)

    def test_warnings_become_annotations(self):
        files = [f("mpvfx-swift/Sources/MpvfxTimeline/A.swift", 500)]
        out = io.StringIO()
        with mock.patch.object(ph, "fetch", return_value=(files, "", lambda n: None)), \
                contextlib.redirect_stdout(out), mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}):
            self.assertEqual(ph.main(["--repo", REPO, "--pr", "1"]), 0)
        self.assertIn("::warning title=PR hygiene::500 changed lines", out.getvalue())
        self.assertIn("| Changed lines (no tests, fixtures, generated) | 500 | 400 |", out.getvalue())


if __name__ == "__main__":
    unittest.main()

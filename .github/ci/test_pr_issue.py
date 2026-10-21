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
"""Tests for pr_issue.py: a pull request without an open issue fails, the exempt ones pass, the API is read only."""
import contextlib
import importlib.util
import io
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pr_issue", os.path.join(HERE, "pr_issue.py"))
pr_issue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pr_issue)

REPO = "marshiyar/oneTake"
OPEN = {"number": 108, "state": "open"}


def pr(body="", labels=(), author="marshiyar", head="ci/108-pr-names-issue", head_repo=REPO):
    return {"body": body, "labels": [{"name": n} for n in labels], "user": {"login": author},
            "head": {"ref": head, "repo": {"full_name": head_repo}}, "base": {"repo": {"full_name": REPO}}}


def issues(**by_number):
    table = {int(k[1:]): v for k, v in by_number.items()}
    return lambda n: table.get(n)


CODE = [".github/ci/pr_issue.py"]


class MustNameAnOpenIssue(unittest.TestCase):
    def test_body_without_closing_keyword_fails(self):
        passed, lines = pr_issue.judge(pr("Adds a check. See #108."), CODE, issues(n108=OPEN))
        self.assertFalse(passed)
        self.assertIn("Closes #<issue>", lines[0])

    def test_empty_or_missing_body_fails(self):
        self.assertFalse(pr_issue.judge(pr(None), CODE, issues())[0])
        self.assertFalse(pr_issue.judge(pr(""), CODE, issues())[0])

    def test_every_closing_keyword_github_links_is_accepted(self):
        for word in ("close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved",
                     "Closes:", "CLOSES", "FIXES:"):
            with self.subTest(word=word):
                self.assertEqual(pr_issue.judge(pr(f"text\n\n{word} #108\n"), CODE, issues(n108=OPEN))[0], True)

    def test_closed_issue_fails(self):
        passed, lines = pr_issue.judge(pr("Closes #7"), CODE, issues(n7={"state": "closed"}))
        self.assertFalse(passed)
        self.assertIn("#7 is closed", lines[0])

    def test_missing_issue_fails(self):
        passed, lines = pr_issue.judge(pr("Fixes #9999"), CODE, issues())
        self.assertFalse(passed)
        self.assertIn("not an issue in this repository", lines[0])

    def test_pull_request_number_fails(self):
        passed, lines = pr_issue.judge(pr("Resolves #76"), CODE,
                                       issues(n76={"state": "open", "pull_request": {"url": "x"}}))
        self.assertFalse(passed)
        self.assertIn("is a pull request", lines[0])

    def test_every_named_issue_must_be_open(self):
        passed, lines = pr_issue.judge(pr("Closes #108, closes #7"), CODE,
                                       issues(n108=OPEN, n7={"state": "closed"}))
        self.assertFalse(passed)
        self.assertEqual(lines, ["- #7 is closed, not an open issue"])

    def test_open_issue_passes(self):
        passed, lines = pr_issue.judge(pr("Closes #108"), CODE, issues(n108=OPEN))
        self.assertTrue(passed)
        self.assertIn("#108", lines[0])

    def test_other_repository_and_non_keyword_references_do_not_count(self):
        for body in ("Closes octo/repo#108", "Discloses #108", "prefix-fixes #108", "Closes ##108", "Closes#108"):
            with self.subTest(body=body):
                self.assertEqual(pr_issue.referenced_issues(body), [])

    def test_references_are_deduplicated_in_order(self):
        self.assertEqual(pr_issue.referenced_issues("Fixes #3\nCloses #1\nresolves #3"), [3, 1])

    def test_too_many_references_fail_without_reading_them(self):
        body = "\n".join(f"Closes #{n}" for n in range(1, 30))
        passed, _ = pr_issue.judge(pr(body), CODE, lambda n: self.fail("read an issue"))
        self.assertFalse(passed)


class Exemptions(unittest.TestCase):
    def assert_exempt(self, the_pr, files=CODE):
        passed, lines = pr_issue.judge(the_pr, files, lambda n: self.fail("read an issue"))
        self.assertTrue(passed)
        self.assertTrue(lines[0].startswith("Exempt:"), lines)

    def test_no_issue_label(self):
        self.assert_exempt(pr("", labels=("bug", "no-issue")))

    def test_dependabot_and_codex(self):
        self.assert_exempt(pr("", author="dependabot[bot]"))
        self.assert_exempt(pr("", author="chatgpt-codex-connector[bot]"))

    def test_merge_train_branch_of_this_repository(self):
        self.assert_exempt(pr("", head="train/4"))

    def test_train_named_branch_from_a_fork_is_not_exempt(self):
        self.assertFalse(pr_issue.judge(pr("", head="train/4", head_repo="someone/fork"), CODE, issues())[0])
        self.assertFalse(pr_issue.judge(pr("", head="train/4-extra"), CODE, issues())[0])
        deleted_fork = pr("", head="train/4")
        deleted_fork["head"]["repo"] = None
        deleted_fork["base"] = None
        self.assertFalse(pr_issue.judge(deleted_fork, CODE, issues())[0])

    def test_documentation_only(self):
        self.assert_exempt(pr(""), ["README.md", "mpvfx-swift/docs/STATUS.md", "mpvfx-swift/docs/a.png", "LICENSE"])

    def test_documentation_filter_matches_the_changes_job(self):
        for files in ([], ["README.md", ".github/ci/pr_issue.py"], ["LICENSE.txt"], None,
                      ["x.md"] * pr_issue.DOCS_MAX_FILES):
            with self.subTest(files=None if files is None else files[:2]):
                self.assertFalse(pr_issue.docs_only(files))
        with open(os.path.join(HERE, "..", "workflows", "mpvfx-ci.yml"), encoding="utf-8") as f:
            self.assertIn(pr_issue.DOCS_FILE.pattern, f.read())


class FakeApi:
    def __init__(self, responses):
        self.responses, self.paths = responses, []

    def __call__(self, path):
        self.paths.append(path)
        return self.responses.get(path)


class Run(unittest.TestCase):
    def test_reads_pull_files_and_issues(self):
        get = FakeApi({"pulls/5": pr("Closes #108"), "pulls/5/files?per_page=100&page=1": [{"filename": "a.py"}],
                       "issues/108": OPEN})
        self.assertEqual(pr_issue.run(5, get)[0], True)
        self.assertEqual(get.paths, ["pulls/5", "pulls/5/files?per_page=100&page=1", "issues/108"])

    def test_rename_from_code_to_markdown_is_not_documentation_only(self):
        files = [{"filename": "notes.md", "previous_filename": "mpvfx-swift/Sources/A.swift"}]
        get = FakeApi({"pulls/5": pr(""), "pulls/5/files?per_page=100&page=1": files})
        self.assertFalse(pr_issue.run(5, get)[0])

    def test_files_are_paged(self):
        page1 = [{"filename": f"d{i}.md"} for i in range(100)]
        get = FakeApi({"pulls/5": pr(""), "pulls/5/files?per_page=100&page=1": page1,
                       "pulls/5/files?per_page=100&page=2": [{"filename": "a.swift"}]})
        self.assertFalse(pr_issue.run(5, get)[0])
        self.assertIn("pulls/5/files?per_page=100&page=2", get.paths)

    def test_unreadable_file_list_is_not_documentation_only(self):
        self.assertIsNone(pr_issue.changed_files(FakeApi({}), 5))

    def test_missing_pull_request_is_an_api_error(self):
        with self.assertRaises(pr_issue.ApiError):
            pr_issue.run(5, FakeApi({}))


class Main(unittest.TestCase):
    def call(self, argv, env):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = pr_issue.main(argv, env)
        return code, out.getvalue()

    def test_bad_arguments_exit_2(self):
        env = {"GITHUB_REPOSITORY": REPO, "GITHUB_TOKEN": "t"}
        for argv, e in (([], env), (["x"], env), (["1", "2"], env), (["1"], {"GITHUB_TOKEN": "t"}),
                        (["1"], {"GITHUB_REPOSITORY": "a/b/../c?x", "GITHUB_TOKEN": "t"}),
                        (["1"], {"GITHUB_REPOSITORY": REPO})):
            with self.subTest(argv=argv, env=e):
                self.assertEqual(self.call(argv, e)[0], 2)

    def test_verdicts_and_exit_codes(self):
        env = {"GITHUB_REPOSITORY": REPO, "GITHUB_TOKEN": "t"}
        real = pr_issue.run
        try:
            pr_issue.run = lambda number, get: (False, ["- #7 is closed, not an open issue"])
            code, out = self.call(["5"], env)
            self.assertEqual(code, 1)
            self.assertIn("FAIL", out)
            self.assertIn("::error::#7 is closed", out)
            pr_issue.run = lambda number, get: (True, ["Exempt: labelled `no-issue`."])
            self.assertEqual(self.call(["5"], env), (0, "### Pull request names its issue: pass\n\n"
                                                        "Exempt: labelled `no-issue`.\n"))

            def boom(number, get):
                raise pr_issue.ApiError("GET pulls/5: HTTP 500")
            pr_issue.run = boom
            code, out = self.call(["5"], env)
            self.assertEqual(code, 2)
            self.assertIn("::error::", out)
        finally:
            pr_issue.run = real


if __name__ == "__main__":
    unittest.main()

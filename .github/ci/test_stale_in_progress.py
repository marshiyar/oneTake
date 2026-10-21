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
"""Unit tests of the stale in-progress job (stale_in_progress.py) against a fake GitHub.

Run: python3 -I -B .github/ci/test_stale_in_progress.py
"""
import datetime
import importlib
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sip = importlib.import_module("stale_in_progress")

REPO = "owner/app"
NOW = datetime.datetime(2026, 10, 21, 12, 0, tzinfo=datetime.timezone.utc)
OLD = "2026-10-18T12:00:00Z"      # 72 h before NOW
RECENT = "2026-10-20T12:00:00Z"   # 24 h before NOW


def issue(n, *labels, created=OLD):
    return sip.Issue(n, {sip.IN_PROGRESS, *labels}, created)


class FakeGitHub:
    """The read and write calls run() makes, recorded."""

    def __init__(self, issues, pulls=(), changes=None):
        self.repo, self.issues, self.pulls = REPO, list(issues), list(pulls)
        self.changes, self.applied, self.rechecked = changes or {}, [], []

    def in_progress_issues(self):
        return self.issues

    def get_issue(self, n):
        self.rechecked.append(n)
        return next((i for i in self.issues if i.number == n), None)

    def open_pulls(self):
        return self.pulls

    def last_label_change(self, n):
        return self.changes.get(n, OLD)

    def apply(self, action):
        self.applied.append(action)


class Planning(unittest.TestCase):
    def one(self, i, pulls=(), last=OLD):
        return sip.plan([i], list(pulls), {i.number: last}, NOW, 48, REPO)

    def test_unlinked_stale_issue_goes_back_to_buildable(self):
        [a] = self.one(issue(7))
        self.assertEqual((a.issue, a.remove, a.add), (7, (sip.IN_PROGRESS,), sip.BUILDABLE))
        self.assertIn("48 hours", a.comment)
        self.assertIn("added `buildable`", a.comment)

    def test_linked_by_closing_reference_is_left_alone(self):
        self.assertEqual(self.one(issue(7), [sip.Pull(1, "x", "Closes #7")]), [])

    def test_linked_by_plain_reference_title_url_or_branch_is_left_alone(self):
        for pull in (sip.Pull(1, body="see #7."), sip.Pull(1, title="Fix the thing (#7)"),
                     sip.Pull(1, body=f"https://github.com/{REPO}/issues/7"), sip.Pull(1, body=f"{REPO}#7"),
                     sip.Pull(1, head_ref="ci/7-stale"), sip.Pull(1, head_ref="7-fix")):
            self.assertEqual(self.one(issue(7), [pull]), [], pull)

    def test_repository_names_match_in_any_case(self):
        for pull in (sip.Pull(1, body="OWNER/App#7"), sip.Pull(1, body="https://GitHub.com/Owner/APP/issues/7")):
            self.assertEqual(self.one(issue(7), [pull]), [], pull)

    def test_other_numbers_and_other_repositories_do_not_link(self):
        for pull in (sip.Pull(1, body="Closes #70"), sip.Pull(1, body="Closes #17"),
                     sip.Pull(1, body="other/app#7"), sip.Pull(1, body="https://github.com/other/app/issues/7"),
                     sip.Pull(1, body=f"https://github.com/{REPO}/pull/7"), sip.Pull(1, head_ref="ci/70-x")):
            self.assertEqual(len(self.one(issue(7), [pull])), 1, pull)

    def test_recent_label_change_is_left_alone(self):
        self.assertEqual(self.one(issue(7), last=RECENT), [])

    def test_no_label_event_falls_back_to_creation_time(self):
        self.assertEqual(self.one(issue(7, created=RECENT), last=""), [])
        self.assertEqual(len(self.one(issue(7), last="")), 1)

    def test_exactly_at_the_limit_is_stale(self):
        self.assertEqual(len(self.one(issue(7), last="2026-10-19T12:00:00Z")), 1)
        self.assertEqual(self.one(issue(7), last="2026-10-19T12:00:01Z"), [])

    def test_blocked_issue_loses_in_progress_but_does_not_gain_buildable(self):
        [a] = self.one(issue(7, sip.BLOCKED))
        self.assertEqual((a.remove, a.add), ((sip.IN_PROGRESS,), ""))
        self.assertIn("did not add `buildable`, because it is `blocked`", a.comment)

    def test_blocked_issue_that_was_buildable_leaves_the_ready_queue(self):
        [a] = self.one(issue(7, sip.BLOCKED, sip.BUILDABLE))
        self.assertEqual((a.remove, a.add), ((sip.BUILDABLE, sip.IN_PROGRESS), ""))
        self.assertIn("and `buildable`, because it is `blocked`", a.comment)

    def test_already_buildable_issue_only_loses_in_progress(self):
        [a] = self.one(issue(7, sip.BUILDABLE))
        self.assertEqual(a.add, "")
        self.assertIn("keeps `buildable`", a.comment)

    def test_launch_blocker_and_needs_owner_are_never_touched(self):
        for label in ("launch-blocker", "needs-owner"):
            self.assertEqual(self.one(issue(7, label)), [], label)

    def test_comment_claims_no_assistant_credit(self):
        [a] = self.one(issue(7))
        for word in ("Claude", "Generated", "Co-Authored", "assistant", "AI"):
            self.assertNotIn(word, a.comment)
        self.assertTrue(a.comment.startswith(sip.MARKER))

    def test_plan_orders_by_issue_number(self):
        acts = sip.plan([issue(9), issue(3), issue(5)], [sip.Pull(1, body="Fixes #5")], {}, NOW, 48, REPO)
        self.assertEqual([a.issue for a in acts], [3, 9])


class Running(unittest.TestCase):
    def setUp(self):
        self.gh = FakeGitHub(
            [issue(1), issue(2), issue(3, sip.BLOCKED), issue(4, "needs-owner"), issue(5, "launch-blocker")],
            [sip.Pull(50, body="Closes #2")], {1: OLD, 3: OLD})

    def test_dry_run_writes_nothing_and_lists_the_changes(self):
        lines = sip.run(self.gh, NOW, dry_run=True)
        self.assertEqual(self.gh.applied, [])
        self.assertEqual(lines[1:], ["would #1: add buildable, comment, remove in-progress",
                                     "would #3: comment, remove in-progress"])
        self.assertTrue(lines[0].startswith("3 in-progress issue(s) checked"))

    def test_live_run_applies_each_change_once(self):
        lines = sip.run(self.gh, NOW, dry_run=False)
        self.assertEqual([(a.issue, a.add) for a in self.gh.applied], [(1, sip.BUILDABLE), (3, "")])
        self.assertEqual(self.gh.rechecked, [1, 3])
        self.assertNotIn("would", "\n".join(lines))

    def test_issue_linked_between_read_and_write_is_left_alone(self):
        gh = self.gh
        first = gh.open_pulls

        def pulls_after_first_read():
            gh.open_pulls = lambda: first() + [sip.Pull(60, body="Closes #1")]
            return first()
        gh.open_pulls = pulls_after_first_read
        lines = sip.run(gh, NOW, dry_run=False)
        self.assertEqual([a.issue for a in gh.applied], [3])
        self.assertIn("#1: changed since it was read; left alone", lines)

    def test_issue_closed_or_relabelled_before_the_write_is_left_alone(self):
        reads = []

        def last_label_change(n):    # #3 gets a label change after the first read
            reads.append(n)
            return RECENT if reads.count(n) > 1 else OLD
        self.gh.get_issue = lambda n: None if n == 1 else issue(3, sip.BLOCKED)    # #1 was closed
        self.gh.last_label_change = last_label_change
        lines = sip.run(self.gh, NOW, dry_run=False)
        self.assertEqual(self.gh.applied, [])
        self.assertEqual([ln for ln in lines if "left alone" in ln], ["#1: changed since it was read; left alone",
                                                                     "#3: changed since it was read; left alone"])

    def test_nothing_in_progress(self):
        self.assertEqual(len(sip.run(FakeGitHub([issue(4, "needs-owner")]), NOW, dry_run=False)), 1)


class GitHubCalls(unittest.TestCase):
    """The REST calls the real client makes, through a fake transport."""

    def make(self, replies=None, fail=None):
        calls = []

        def send(method, path, payload=None):
            calls.append((method, path, payload))
            if fail and fail(method, path):
                return 502, "bad gateway", ""
            for key, (text, link) in (replies or {}).items():
                if key in path:
                    return 200, text, link
            return 200, "", ""
        return sip.GitHub(REPO, send), calls

    def test_reads_follow_pages(self):
        nxt = '<https://api.github.com/repositories/1/issues?labels=x&page=2>; rel="next", <https://x>; rel="last"'
        issues = [{"number": 7, "created_at": OLD, "labels": [{"name": "in-progress"}]},
                  {"number": 8, "created_at": OLD, "labels": [], "pull_request": {}}]
        page2 = [{"number": 9, "created_at": RECENT, "labels": [{"name": "in-progress"}]}]
        events = [{"event": "labeled", "created_at": OLD}, {"event": "unlabeled", "created_at": RECENT},
                  {"event": "commented", "created_at": "2026-10-21T00:00:00Z"}]
        pulls = [{"number": 1, "title": "t", "body": None, "head": {"ref": "ci/7-x"}}]
        gh, calls = self.make({"page=2": (json.dumps(page2), ""), "state=open&labels": (json.dumps(issues), nxt),
                               "/events": (json.dumps(events), ""), "/pulls?": (json.dumps(pulls), "")})
        self.assertEqual(gh.in_progress_issues(), [sip.Issue(7, {"in-progress"}, OLD),
                                                   sip.Issue(9, {"in-progress"}, RECENT)])
        self.assertEqual(calls[1][1], f"/repos/{REPO}/issues?state=open&labels=in-progress&per_page=100&page=2")
        self.assertEqual(gh.last_label_change(7), RECENT)
        self.assertEqual(gh.open_pulls(), [sip.Pull(1, "t", "", "ci/7-x")])
        self.assertTrue(all(c[0] == "GET" and c[2] is None for c in calls))

    def test_next_page_only_follows_the_api_host(self):
        here = "/repos/o/r/pulls?per_page=100&page=2"
        self.assertEqual(sip.next_page('<https://evil.example/x?page=3>; rel="next"', here), "")
        self.assertEqual(sip.next_page('<http://api.github.com/x?page=3>; rel="next"', here), "")
        self.assertEqual(sip.next_page('<https://api.github.com/x?page=abc>; rel="next"', here), "")
        self.assertEqual(sip.next_page('<https://api.github.com/x?page=1>; rel="prev"', here), "")
        self.assertEqual(sip.next_page("", here), "")
        self.assertEqual(sip.next_page('<https://api.github.com/repositories/9/pulls?page=3>; rel="next"', here),
                         "/repos/o/r/pulls?per_page=100&page=3")

    def test_apply_adds_comments_then_removes_in_progress_last(self):
        gh, calls = self.make()
        gh.apply(sip.Action(7, (sip.IN_PROGRESS,), sip.BUILDABLE, "why"))
        self.assertEqual(calls, [("POST", f"/repos/{REPO}/issues/7/labels", {"labels": ["buildable"]}),
                                 ("POST", f"/repos/{REPO}/issues/7/comments", {"body": "why"}),
                                 ("DELETE", f"/repos/{REPO}/issues/7/labels/in-progress", None)])

    def test_apply_without_add_skips_the_label_post(self):
        gh, calls = self.make()
        gh.apply(sip.Action(7, (sip.BUILDABLE, sip.IN_PROGRESS), "", "why"))
        self.assertEqual([c[0] for c in calls], ["POST", "DELETE", "DELETE"])
        self.assertTrue(calls[-1][1].endswith("/labels/in-progress"))

    def test_failed_write_leaves_in_progress_in_place(self):
        gh, calls = self.make(fail=lambda method, path: path.endswith("/comments"))
        with self.assertRaises(sip.Error):
            gh.apply(sip.Action(7, (sip.IN_PROGRESS,), sip.BUILDABLE, "why"))
        self.assertNotIn("DELETE", [c[0] for c in calls])

    def test_get_issue_returns_none_for_closed_issues_and_pull_requests(self):
        for row in ({"number": 7, "state": "closed", "created_at": OLD},
                    {"number": 7, "state": "open", "created_at": OLD, "pull_request": {}}):
            gh, _ = self.make({"/issues/7": (json.dumps(row), "")})
            self.assertIsNone(gh.get_issue(7))
        gh, _ = self.make({"/issues/7": (json.dumps({"number": 7, "state": "open", "created_at": OLD,
                                                     "labels": [{"name": "blocked"}]}), "")})
        self.assertEqual(gh.get_issue(7), sip.Issue(7, {"blocked"}, OLD))

    def test_failed_call_raises(self):
        gh, _ = self.make(fail=lambda method, path: True)
        with self.assertRaises(sip.Error):
            gh.open_pulls()

    def test_bad_repository_name_is_refused(self):
        for repo in ("", "a", "a/b/c", "a/b?x=1", "../x", "a/.."):
            with self.assertRaises(sip.Error):
                sip.GitHub(repo, None)

    def test_bad_arguments_exit(self):
        for argv in (["--repo", "not a repo"], ["--repo", REPO, "--hours", "0"]):
            with self.assertRaises(SystemExit):
                sip.main(argv)


if __name__ == "__main__":
    unittest.main()

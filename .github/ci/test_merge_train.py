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
"""Unit tests of the merge train (merge_train.py) against a fake GitHub and a fake git.

Run: python3 -I -B .github/ci/test_merge_train.py
"""
import hashlib, os, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import merge_train as mt  # noqa: E402

OWNER, APP = "owner", "review-app[bot]"


def sha(text):
    return hashlib.sha1(text.encode()).hexdigest()


class FakeGitHub:
    def __init__(self):
        self.owner, self.app_login = OWNER, APP
        self.prs, self.comments, self.events, self.runs = {}, {}, {}, {}
        self.next, self.allow_actions_prs = 100, True
        self.auto_merge = []

    # helpers for tests
    def add_pr(self, n, head, **kw):
        self.prs[n] = mt.PR(number=n, head_sha=head, head_ref=f"feature/{n}", author="dev", **kw)
        self.comments.setdefault(n, [])
        self.events.setdefault(n, [])
        return self.prs[n]

    def label_event(self, n, action, t, actor=OWNER):
        self.events[n].append((action, t, actor))

    def bodies(self, n):
        return [b for _, b in self.comments.get(n, [])]

    # the interface merge_train uses
    def open_prs(self):
        return [mt.PR(**{**p.__dict__, "labels": set(p.labels)}) for p in self.prs.values() if p.state == "open"]

    def get_pr(self, n):
        p = self.prs[n]
        return mt.PR(**{**p.__dict__, "labels": set(p.labels)})

    def train_prs(self):
        return [self.get_pr(n) for n in sorted(self.prs, reverse=True) if mt.TRAIN in self.prs[n].labels]

    def queue_label_event(self, n):
        return self.events[n][-1] if self.events.get(n) else None

    def app_comments(self, n):
        return [b for who, b in self.comments.get(n, []) if who == APP]

    def comment(self, n, text):
        self.comments.setdefault(n, []).append((APP, text + mt.FOOTER))

    def add_labels(self, n, labels):
        self.prs[n].labels |= set(labels)

    def remove_label(self, n, label):
        self.prs[n].labels.discard(label)

    def set_state(self, n, state):
        self.prs[n].state = state

    def create_pr(self, branch, title, body):
        n, self.next = self.next, self.next + 1
        author = mt.ACTIONS_LOGIN if self.allow_actions_prs else APP
        self.prs[n] = mt.PR(number=n, head_sha=self.git.heads[branch], head_ref=branch, author=author, body=body)
        self.prs[n].title = title
        self.comments[n] = []
        return n, author

    def enable_auto_merge(self, n, head):
        self.auto_merge.append((n, head))
        return True

    def check_runs(self, s):
        return self.runs.get(s, [])

    def run_url(self, s):
        return f"https://example.invalid/runs/{s[:7]}" if s in self.runs else ""

    # test helpers on trains
    def ci(self, n, conclusion, failing=()):
        s = self.prs[n].head_sha
        self.runs[s] = [{"id": 2, "name": "ci-ok", "status": "completed", "conclusion": conclusion,
                         "html_url": "https://example.invalid/ci-ok"}] + [
            {"id": 1, "name": j, "status": "completed", "conclusion": "failure"} for j in failing]

    def merge_train(self, n):
        p = self.prs[n]
        p.state, p.merged = "closed", True
        self.git.main = sha("main+" + p.head_sha)
        self.git.content[self.git.main] = self.git.content[p.head_sha]


class FakeGit:
    """Content is a set of change names; a PR head adds its own. Conflicts are declared between heads."""

    def __init__(self):
        self.main = sha("main")
        self.content = {self.main: frozenset()}
        self.conflicts, self.files, self.heads, self.pr_heads = set(), {}, {}, {}
        self.cur, self.pushed = frozenset(), []

    def head_of(self, n, s):
        self.pr_heads[n] = s
        self.content[s] = frozenset({s})

    def fetch_main(self):
        return self.main

    def fetch_prs(self, numbers):
        return {n: self.pr_heads[n] for n in numbers}

    def fetch_shas(self, shas):
        pass

    def start(self, base):
        self.cur, self.merged = self.content[base], []

    def merge(self, s, message):
        if ("main", s) in self.conflicts or any((m, s) in self.conflicts or (s, m) in self.conflicts
                                                 for m in self.merged):
            return False
        self.merged.append(s)
        self.cur = self.cur | self.content[s]
        return True

    def changed_files(self, base, s):
        return self.files.get(s, ["mpvfx-swift/Sources/x.swift"])

    def tree(self, rev):
        return self.cur if rev == "HEAD" else self.content[rev]

    def head(self):
        return sha("head" + ",".join(sorted(self.cur)))

    def is_ancestor(self, a, b):
        return a in self.content

    def remote_trains(self):
        return list(self.heads)

    def push(self, branch):
        assert branch not in self.heads, "never overwrite a branch"
        h = self.head()
        self.heads[branch] = h
        self.content[h] = self.cur
        self.pushed.append(branch)


class World(unittest.TestCase):
    def setUp(self):
        self.gh, self.git = FakeGitHub(), FakeGit()
        self.gh.git = self.git

    def queue(self, n, t=None, actor=OWNER, extra_labels=()):
        s = sha(f"pr{n}")
        self.gh.add_pr(n, s, labels={mt.QUEUE, *extra_labels})
        self.git.head_of(n, s)
        self.gh.label_event(n, "labeled", t or "", actor)
        mt.record(self.gh, n, s, actor)
        return s

    def step(self):
        return mt.step(self.gh, self.git)

    def open_train(self):
        trains = [p for p in self.gh.prs.values() if mt.TRAIN in p.labels and p.state == "open"]
        self.assertLessEqual(len(trains), 1)
        return trains[0] if trains else None

    def members(self, train):
        return [n for n, _ in mt.parse_state(train.body)["prs"]]

    def assert_footer_everywhere(self):
        for n, cs in self.gh.comments.items():
            for _, body in cs:
                self.assertTrue(body.endswith(mt.FOOTER), f"comment on #{n} lacks the footer: {body!r}")
        for p in self.gh.prs.values():
            if mt.TRAIN in p.labels:
                self.assertTrue(p.body.endswith(mt.FOOTER))


class Ordering(World):
    def test_label_time_then_number(self):
        q = [mt.Queued(5, "a", "2026-01-02"), mt.Queued(3, "b", ""), mt.Queued(9, "c", "2026-01-01"),
             mt.Queued(2, "d", "")]
        self.assertEqual([x.number for x in mt.order_queue(q)], [9, 5, 2, 3])

    def test_batch_follows_label_order(self):
        self.queue(7, "2026-10-01T10:00:00Z")
        self.queue(3, "2026-10-01T12:00:00Z")
        self.queue(5, "2026-10-01T11:00:00Z")
        self.step()
        t = self.open_train()
        self.assertEqual(self.members(t), [7, 5, 3])
        self.assertEqual(t.title, "Merge train: #7, #5, #3")
        self.assertEqual(t.head_ref, "train/1")
        self.assertIn(mt.TRAIN, t.labels)
        self.assertEqual(self.gh.auto_merge, [(t.number, t.head_sha)])
        for n in (7, 5, 3):
            self.assertIn(f"- #{n} at `{sha(f'pr{n}')}`", t.body)
        self.assert_footer_everywhere()

    def test_only_queue_label_same_repo_ready(self):
        self.queue(1, "t1")
        self.queue(2, "t2")
        self.gh.prs[2].draft = True
        self.queue(3, "t3")
        self.gh.prs[3].same_repo = False
        s = sha("pr4")
        self.gh.add_pr(4, s)            # open, no label
        self.git.head_of(4, s)
        self.step()
        self.assertEqual(self.members(self.open_train()), [1])


class OneAtATime(World):
    def test_open_train_blocks_a_new_one(self):
        self.queue(1, "t1")
        self.step()
        first = self.open_train()
        self.queue(2, "t2")
        log = self.step()
        self.assertIs(self.open_train(), first)
        self.assertEqual(self.git.pushed, ["train/1"])
        self.assertTrue(any("waiting" in line for line in log))

    def test_green_train_waits_for_merge(self):
        self.queue(1, "t1")
        self.step()
        self.gh.ci(self.open_train().number, "success")
        self.step()
        self.assertEqual(self.git.pushed, ["train/1"])
        self.assertEqual(self.open_train().state, "open")


class Conflicts(World):
    def test_conflicting_pr_is_skipped_and_stays_queued(self):
        self.queue(1, "t1")
        s2 = self.queue(2, "t2")
        self.queue(3, "t3")
        self.git.conflicts.add((sha("pr1"), s2))
        self.step()
        self.assertEqual(self.members(self.open_train()), [1, 3])
        self.assertIn(mt.QUEUE, self.gh.prs[2].labels)
        c = self.gh.bodies(2)[-1]
        self.assertIn("Not in this batch: conflicts with main or with #1; update it from main", c)
        self.assert_footer_everywhere()

    def test_conflict_with_main_and_no_repeat_comment(self):
        self.queue(1, "t1")
        s2 = self.queue(2, "t2")
        self.git.conflicts.add(("main", s2))
        self.step()
        t = self.open_train()
        self.gh.ci(t.number, "success")
        self.gh.merge_train(t.number)
        self.git.conflicts.add(("main", s2))
        n_before = len(self.gh.bodies(2))
        self.step()          # lands #1, tries #2 alone on the new main: conflicts, one comment
        self.step()          # same main, same head: no second comment
        self.assertEqual(len(self.gh.bodies(2)), n_before + 1)
        self.assertIn("conflicts with main;", self.gh.bodies(2)[-1])

    def test_workflow_changes_leave_the_queue(self):
        self.queue(1, "t1")
        s2 = self.queue(2, "t2")
        self.git.files[s2] = [".github/workflows/x.yml"]
        self.step()
        self.assertEqual(self.members(self.open_train()), [1])
        self.assertNotIn(mt.QUEUE, self.gh.prs[2].labels)


class Cap(World):
    def test_at_most_eight(self):
        for n in range(1, 11):
            self.queue(n, f"2026-10-01T10:{n:02d}:00Z")
        self.step()
        self.assertEqual(self.members(self.open_train()), list(range(1, 9)))


class IssueReferences(World):
    def closing_lines(self, train):
        return [line for line in train.body.splitlines() if line.startswith("Closes #")]

    def test_references_are_deduplicated_in_queue_and_body_order(self):
        for n, t, body in ((3, "t3", "Closes #42\nFixes #8"),
                           (7, "t1", "Fixes #42\nResolves #6\nCloses #042"),
                           (5, "t2", "Closed #6\nCloses #2")):
            self.queue(n, t)
            self.gh.prs[n].body = body
        self.step()
        train = self.open_train()
        self.assertEqual(self.members(train), [7, 5, 3])
        self.assertEqual(self.closing_lines(train), ["Closes #42", "Closes #6", "Closes #2", "Closes #8"])
        self.assertNotIn("no-issue", train.labels)
        self.assert_footer_everywhere()

    def test_closing_keyword_grammar(self):
        self.queue(1)
        words = ("close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved")
        self.gh.prs[1].body = "\n".join(f"{word.upper()}:\t#{n}" for n, word in enumerate(words, 10))
        self.gh.prs[1].body += ("\nSee #90\nDiscloses #91\nprefix-fixes #92\nCloses ##93\nCloses#94"
                               "\nCloses octo/repo#95\nCloses:\n#96\nFixes:\r\n#97\n/foo/fixes #98")
        self.step()
        self.assertEqual(self.closing_lines(self.open_train()), [f"Closes #{n}" for n in range(10, 19)])

    def test_unicode_digits_do_not_introduce_closing_references(self):
        self.queue(1)
        self.gh.prs[1].body = "Fixes #１２\nCloses #٣٤\nResolved #5６\nCloses #７８9\nFixes #90"
        self.step()
        self.assertEqual(self.closing_lines(self.open_train()), ["Closes #90"])

    def test_large_body_under_limit_keeps_every_reference(self):
        self.queue(1)
        self.gh.prs[1].body = "\n".join(f"Fixes #{n}" for n in range(1, 4801))
        self.step()
        train = self.open_train()
        self.assertLessEqual(len(train.body), 65536)
        self.assertEqual(self.closing_lines(train), [f"Closes #{n}" for n in range(1, 4801)])

    def test_oversized_body_is_rejected_before_pushing(self):
        for n in (1, 2):
            self.queue(n)
            self.gh.prs[n].body = "\n".join(f"Fixes #{i}" for i in range((n - 1) * 3000 + 1, n * 3000 + 1))
            self.assertLess(len(self.gh.prs[n].body), 65536)
        for _ in range(2):
            log = self.step()
            self.assertTrue(self.open_train() is None, "oversized body opened a train")
            self.assertEqual(self.git.pushed, [])
            self.assertEqual(self.gh.auto_merge, [])
            self.assertEqual(set(self.gh.prs), {1, 2})
            self.assertTrue(all(mt.QUEUE in p.labels for p in self.gh.prs.values()))
            self.assertTrue(any("65536" in line and "#1, #2" in line for line in log), log)

    def test_all_existing_exemptions_propagate_no_issue(self):
        self.queue(1, extra_labels={"no-issue"})
        for n, author in ((2, "dependabot[bot]"), (3, "chatgpt-codex-connector[bot]")):
            self.queue(n)
            self.gh.prs[n].author = author
        s = self.queue(4)
        self.git.files[s] = ["README.md", "docs/notes.md", "mpvfx-swift/docs/image.png",
                             "LICENSE", "LICENSE-MIT", "LICENSE-APACHE", "NOTICE"]
        self.step()
        self.assertIn("no-issue", self.open_train().labels)
        self.assertEqual(self.closing_lines(self.open_train()), [])

    def test_exemption_does_not_hide_a_carried_reference(self):
        self.queue(1, extra_labels={"no-issue"})
        self.gh.prs[1].body = "Closes #42"
        self.step()
        self.assertEqual(self.closing_lines(self.open_train()), ["Closes #42"])
        self.assertNotIn("no-issue", self.open_train().labels)

    def test_mixed_exempt_and_nonexempt_train_is_not_exempt(self):
        self.queue(1, extra_labels={"no-issue"})
        self.queue(2)
        self.step()
        self.assertNotIn("no-issue", self.open_train().labels)
        self.assertEqual(self.closing_lines(self.open_train()), [])

    def test_docs_exemption_requires_nonempty_bounded_all_docs_files(self):
        for files in ([], ["README.md", "src/code.py"], ["README.md"] * 3000):
            with self.subTest(files_count=len(files)):
                self.setUp()
                s = self.queue(1)
                self.git.files[s] = files
                self.step()
                self.assertNotIn("no-issue", self.open_train().labels)

    def test_skipped_and_over_cap_prs_contribute_no_references(self):
        for n in range(1, 11):
            s = self.queue(n, f"t{n:02d}")
            self.gh.prs[n].body = f"Closes #{n + 40}"
            if n == 2:
                self.git.conflicts.add(("main", s))
        self.step()
        self.assertEqual(self.members(self.open_train()), [1, 3, 4, 5, 6, 7, 8, 9])
        self.assertEqual(self.closing_lines(self.open_train()),
                         [f"Closes #{n + 40}" for n in (1, 3, 4, 5, 6, 7, 8, 9)])

    def test_split_trains_keep_only_their_own_references(self):
        for n in (1, 2, 3, 4):
            self.queue(n, f"t{n}")
            self.gh.prs[n].body = f"Closes #{n + 40}"
        self.step()
        self.gh.ci(self.open_train().number, "failure")
        self.step()
        first = self.open_train()
        self.assertEqual(self.members(first), [1, 2])
        self.assertEqual(self.closing_lines(first), ["Closes #41", "Closes #42"])
        self.gh.merge_train(first.number)
        self.step()
        second = self.open_train()
        self.assertEqual(self.members(second), [3, 4])
        self.assertEqual(self.closing_lines(second), ["Closes #43", "Closes #44"])

    def test_split_exemption_depends_only_on_carried_prs(self):
        self.queue(1, "t1", extra_labels={"no-issue"})
        self.queue(2, "t2")
        self.gh.prs[2].body = "Closes #42"
        self.step()
        self.gh.ci(self.open_train().number, "failure")
        self.step()
        first = self.open_train()
        self.assertEqual(self.members(first), [1])
        self.assertEqual(self.closing_lines(first), [])
        self.assertIn("no-issue", first.labels)
        self.gh.merge_train(first.number)
        self.step()
        second = self.open_train()
        self.assertEqual(self.members(second), [2])
        self.assertEqual(self.closing_lines(second), ["Closes #42"])
        self.assertNotIn("no-issue", second.labels)


class Landing(World):
    def test_merged_train_closes_unchanged_prs_only(self):
        self.queue(1, "t1")
        self.queue(2, "t2")
        self.step()
        t = self.open_train()
        self.gh.prs[2].head_sha = sha("pr2-pushed-after")      # the author pushed after batching
        self.gh.ci(t.number, "success")
        self.gh.merge_train(t.number)
        self.step()
        p1, p2 = self.gh.prs[1], self.gh.prs[2]
        self.assertEqual(p1.state, "closed")
        self.assertNotIn(mt.QUEUE, p1.labels)
        self.assertIn(f"Landed in #{t.number}.", self.gh.bodies(1)[-1])
        self.assertTrue(self.gh.bodies(1)[-1].endswith(mt.FOOTER))
        self.assertEqual(p2.state, "open")
        self.assertFalse(any("Landed" in b for b in self.gh.bodies(2)))
        self.assertIn(mt.DONE, self.gh.prs[t.number].labels)
        self.assert_footer_everywhere()

    def test_author_push_after_batching_is_not_closed_nor_unlabelled_at_landing(self):
        self.queue(1, "t1")
        self.step()
        t = self.open_train()
        self.gh.prs[1].head_sha = sha("pr1-new")
        self.gh.merge_train(t.number)
        mt.land(self.gh, self.gh.get_pr(t.number), [])
        self.assertEqual(self.gh.prs[1].state, "open")
        self.assertIn(mt.QUEUE, self.gh.prs[1].labels)

    def test_handled_once(self):
        self.queue(1, "t1")
        self.step()
        t = self.open_train()
        self.gh.merge_train(t.number)
        self.step()
        n = len(self.gh.bodies(1))
        self.step()
        self.assertEqual(len(self.gh.bodies(1)), n)

    def test_push_after_queueing_leaves_the_queue(self):
        self.queue(1, "t1")
        self.gh.prs[1].head_sha = sha("pr1-new")
        self.git.pr_heads[1] = sha("pr1-new")
        self.step()
        self.assertIsNone(self.open_train())
        self.assertNotIn(mt.QUEUE, self.gh.prs[1].labels)
        self.assertIn("pushed after it was queued", self.gh.bodies(1)[-1])

    def test_label_by_someone_else_is_undone(self):
        s = sha("pr1")
        self.gh.add_pr(1, s, labels={mt.QUEUE})
        self.git.head_of(1, s)
        mt.record(self.gh, 1, s, "stranger")
        self.assertNotIn(mt.QUEUE, self.gh.prs[1].labels)
        self.assertFalse(any(mt.QUEUED_RE.search(b) for b in self.gh.app_comments(1)))


class Bisect(World):
    def test_failure_splits_in_halves(self):
        for n in (1, 2, 3, 4):
            self.queue(n, f"t{n}")
        self.step()
        t1 = self.open_train()
        self.gh.ci(t1.number, "failure", failing=["macos"])
        self.step()
        self.assertEqual(self.gh.prs[t1.number].state, "closed")
        self.assertIn(mt.DONE, self.gh.prs[t1.number].labels)
        self.assertIn("Next: #1, #2 go in the next train; #3, #4 follow", self.gh.bodies(t1.number)[-1])
        t2 = self.open_train()
        self.assertEqual(self.members(t2), [1, 2])
        self.assertEqual(mt.parse_state(t2.body)["pending"], [[3, 4]])
        for n in (1, 2, 3, 4):
            self.assertIn(mt.QUEUE, self.gh.prs[n].labels)
        # the first half is green and lands; the second half goes next even though #5 was queued meanwhile
        self.queue(5, "t5")
        self.gh.ci(t2.number, "success")
        self.gh.merge_train(t2.number)
        self.step()
        self.assertEqual(self.members(self.open_train()), [3, 4])
        self.assert_footer_everywhere()

    def test_single_failure_is_marked(self):
        self.queue(1, "t1")
        self.queue(2, "t2")
        self.step()
        t1 = self.open_train()
        self.gh.ci(t1.number, "failure", failing=["linux test (rest)"])
        self.step()                        # -> [1] then [2]
        t2 = self.open_train()
        self.assertEqual(self.members(t2), [1])
        self.gh.ci(t2.number, "failure", failing=["windows", "macos"])
        self.step()
        p1 = self.gh.prs[1]
        self.assertIn(mt.FAILED, p1.labels)
        self.assertNotIn(mt.QUEUE, p1.labels)
        c = self.gh.bodies(1)[-1]
        self.assertIn("Failing jobs: macos, windows.", c)
        self.assertIn("https://example.invalid/runs/", c)
        self.assertEqual(self.members(self.open_train()), [2])
        self.assert_footer_everywhere()

    def test_closed_unmerged_by_hand_bisects(self):
        for n in (1, 2, 3):
            self.queue(n, f"t{n}")
        self.step()
        t = self.open_train()
        self.gh.set_state(t.number, "closed")
        self.step()
        self.assertEqual(self.members(self.open_train()), [1, 2])

    def test_requeue_clears_train_failed(self):
        self.queue(1, "t1", extra_labels={mt.FAILED})
        self.assertNotIn(mt.FAILED, self.gh.prs[1].labels)

    def test_main_moved_retries_same_set(self):
        self.queue(1, "t1")
        self.queue(2, "t2")
        self.step()
        t = self.open_train()
        self.git.main = sha("someone else landed")
        self.git.content[self.git.main] = frozenset({"other"})
        self.step()
        self.assertIn(mt.RETRY, self.gh.prs[t.number].labels)
        t2 = self.open_train()
        self.assertEqual(self.members(t2), [1, 2])
        self.assertEqual(t2.head_ref, "train/2")


class Verify(World):
    def green_train(self):
        self.queue(1, "t1")
        self.queue(2, "t2")
        self.step()
        t = self.open_train()
        self.gh.ci(t.number, "success")
        return t

    def test_green_train_passes(self):
        t = self.green_train()
        n, problems = mt.verify(self.gh, self.git, t.head_ref, t.head_sha)
        self.assertEqual((n, problems), (t.number, []))

    def test_unqueued_member_fails(self):
        t = self.green_train()
        self.gh.label_event(2, "unlabeled", "later")
        _, problems = mt.verify(self.gh, self.git, t.head_ref, t.head_sha)
        self.assertTrue(any("#2" in p for p in problems))

    def test_label_by_other_fails(self):
        t = self.green_train()
        self.gh.label_event(1, "labeled", "later", "stranger")
        _, problems = mt.verify(self.gh, self.git, t.head_ref, t.head_sha)
        self.assertTrue(any("#1" in p for p in problems))

    def test_extra_content_fails(self):
        t = self.green_train()
        self.git.content[t.head_sha] = self.git.content[t.head_sha] | {"sneaked in"}
        _, problems = mt.verify(self.gh, self.git, t.head_ref, t.head_sha)
        self.assertIn("the train's files differ from main plus the queued commits", problems)

    def test_red_or_app_authored_fails(self):
        t = self.green_train()
        self.gh.ci(t.number, "failure")
        self.gh.prs[t.number].author = APP
        _, problems = mt.verify(self.gh, self.git, t.head_ref, t.head_sha)
        self.assertEqual(len(problems), 2)

    def test_app_fallback_asks_for_no_approval(self):
        self.gh.allow_actions_prs = False
        self.queue(1, "t1")
        self.step()
        t = self.open_train()
        self.assertEqual(self.gh.bodies(t.number), [])
        self.assertEqual(self.gh.auto_merge, [(t.number, t.head_sha)])

    def test_body_promises_no_approval(self):
        b = mt.render_body("train/4", "m" * 40, [mt.Queued(3, "a" * 40)], [])
        self.assertNotIn("approve", b)


class Body(unittest.TestCase):
    def test_round_trip(self):
        b = mt.render_body("train/4", "m" * 40, [mt.Queued(3, "a" * 40)], [[5, 6], [7]])
        self.assertEqual(mt.parse_state(b), {"branch": "train/4", "main": "m" * 40, "prs": [(3, "a" * 40)],
                                             "pending": [[5, 6], [7]]})
        self.assertTrue(b.endswith(mt.FOOTER))

    def test_halves(self):
        self.assertEqual(mt.halves([1, 2, 3]), [[1, 2], [3]])
        self.assertEqual(mt.halves([1]), [[1]])

    def test_ci_ok_newest_wins(self):
        runs = [{"id": 1, "name": "ci-ok", "status": "completed", "conclusion": "failure"},
                {"id": 2, "name": "ci-ok", "status": "in_progress"}]
        self.assertEqual(mt.ci_ok(runs), "pending")
        self.assertEqual(mt.ci_ok([]), "pending")


class Commands(unittest.TestCase):
    """The I/O layer builds the expected gh calls."""

    def test_changed_files_counts_both_sides_of_a_rename(self):
        calls = []

        def run(args, env=None, cwd=None):
            calls.append(args)
            sep = "\0" if "-z" in args else "\n"
            return 0, sep.join(["src/code.py", "README.md", ""]), ""
        files = mt.Git("/x", run=run).changed_files("base", "head")
        self.assertEqual(files, ["src/code.py", "README.md"])
        self.assertIn("--no-renames", calls[0])

    def test_changed_files_preserves_raw_documentation_paths(self):
        with tempfile.TemporaryDirectory() as path:
            def git(*args):
                return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "core.quotePath=true",
                                       "-c", "user.name=Test", "-c", "user.email=test@example.invalid", *args],
                                      cwd=path, check=True, capture_output=True, text=True).stdout.strip()
            git("init", "-q")
            git("commit", "-q", "--allow-empty", "-m", "base")
            base = git("rev-parse", "HEAD")
            names = [" leading.md", "é.md", "mpvfx-swift/docs/é.png", "mpvfx-swift/docs/line\nbreak.png"]
            for name in names:
                filename = os.path.join(path, name)
                os.makedirs(os.path.dirname(filename), exist_ok=True)
                with open(filename, "w") as f:
                    f.write("doc fixture\n")
            git("add", ".")
            git("commit", "-q", "-m", "docs")
            files = mt.Git(path).changed_files(base, "HEAD")
            self.assertCountEqual(files, names)
            self.assertTrue(mt.issue_exempt(mt.PR(number=1), files))
            self.assertEqual(mt.Git(path).changed_files("HEAD", "HEAD"), [])

    def test_comment_and_labels(self):
        calls = []

        def run(args, env=None, cwd=None):
            calls.append(args)
            return 0, "", ""
        gh = mt.GitHub("o/r", OWNER, APP, run=run)
        gh.comment(3, "hi")
        gh.add_labels(3, ["queue"])
        self.assertEqual(calls[0][:5], ["gh", "api", "-X", "POST", "repos/o/r/issues/3/comments"])
        self.assertEqual(calls[0][-1], "body=hi" + mt.FOOTER)
        self.assertEqual(calls[1][-1], "labels[]=queue")

    def test_push_never_forces(self):
        calls = []

        def run(args, env=None, cwd=None):
            calls.append((args, env))
            return 0, "", ""
        mt.Git("/x", push_token="tok", run=run).push("train/1")
        args, env = calls[0]
        self.assertNotIn("--force", args)
        self.assertEqual(args[-1], "HEAD:refs/heads/train/1")
        self.assertNotIn("tok", " ".join(args))
        self.assertEqual(env["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraheader")


if __name__ == "__main__":
    unittest.main(verbosity=2)

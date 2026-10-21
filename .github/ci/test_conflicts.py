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
"""Unit tests of the conflicts bot (conflicts.py) against a fake gh and, for the git part, real temporary repositories.

Run: python3 -I -B .github/ci/test_conflicts.py
"""
import json, os, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import conflicts as cf  # noqa: E402

SHA = "a" * 40
STATUS = "mpvfx-swift/docs/STATUS.md"
SPIRV = "mpvfx-swift/Sources/CMpvfxVulkan/mpvfx_grade_spirv.h"


class FakeGh:
    """A fake `gh`: answers `gh api` from in-memory state and records every write."""

    def __init__(self):
        self.prs, self.comments, self.mergeable, self.writes = {}, {}, {}, []
        self.polls = {}

    def add(self, n, labels=(), draft=False, repo="o/r", base="main", mergeable=True, ref=None, sha=SHA):
        self.prs[n] = {"number": n, "draft": draft, "labels": [{"name": l} for l in labels],
                       "head": {"sha": sha, "ref": ref or f"feature/{n}", "repo": {"full_name": repo}},
                       "base": {"ref": base, "repo": {"full_name": "o/r"}}}
        self.mergeable[n] = mergeable
        self.comments[n] = []

    def __call__(self, args, env=None, cwd=None):
        assert args[:2] == ["gh", "api"], args
        method, path = args[3], args[4]
        fields = [args[i + 1] for i, a in enumerate(args) if a == "-f"]
        jq = args[args.index("--jq") + 1] if "--jq" in args else None
        if method != "GET":
            self.writes.append((method, path, fields))
            if method == "POST" and path.endswith("/comments"):
                n = int(path.split("/")[-2])
                self.comments[n].append(fields[0][len("body="):])
            return 0, "", ""
        if path.startswith("repos/o/r/pulls?"):
            return 0, "".join(json.dumps(p) + "\n" for p in self.prs.values()), ""
        n = int(path.split("/")[4].split("?")[0])
        if path.endswith("/comments?per_page=100"):
            # like gh --jq: a string result prints raw unless the filter ends in tojson
            enc = json.dumps if (jq or "").rstrip().endswith("tojson") else str
            return 0, "".join(enc(b) + "\n" for b in self.comments[n]), ""
        self.polls[n] = self.polls.get(n, 0) + 1
        m = self.mergeable[n]
        if isinstance(m, list):
            m = m[min(self.polls[n] - 1, len(m) - 1)]
        text = {True: "true", False: "false", None: "null"}[m]
        return 0, (self.prs[n]["head"]["sha"] if jq == ".head.sha" else text) + "\n", ""


class FakeGit:
    def __init__(self, outcome=None, error=None):
        self.outcome, self.error, self.calls = outcome or cf.Outcome("pushed"), error, []

    def attempt(self, branch, sha):
        self.calls.append((branch, sha))
        if self.error:
            raise cf.Error(self.error)
        return self.outcome


def make_gh():
    return cf.GitHub("o/r", run=FakeGh(), sleep=lambda s: None)


class Decisions(unittest.TestCase):
    def test_classify_splits_generated_from_manual(self):
        regen, manual = cf.classify([SPIRV, "mpvfx-swift/scripts/gpu/generated/grade.hlsl", STATUS,
                                     "mpvfx-swift/Sources/MpvfxPlayer/A.swift", SPIRV])
        self.assertEqual(regen, [SPIRV, "mpvfx-swift/scripts/gpu/generated/grade.hlsl"])
        self.assertEqual(manual, ["mpvfx-swift/Sources/MpvfxPlayer/A.swift", STATUS])

    def test_generated_paths_are_exact(self):
        self.assertTrue(cf.is_generated("mpvfx-swift/Sources/CMpvfxWin32/mpvfx_grade_hlsl.h"))
        self.assertFalse(cf.is_generated("mpvfx-swift/scripts/gpu/generated/"))
        self.assertFalse(cf.is_generated("mpvfx-swift/scripts/gpu/gen-compute-shaders.py"))
        self.assertFalse(cf.is_generated("mpvfx-swift/Sources/CMpvfxWin32/other.h"))

    def test_nothing_unmerged_classifies_empty(self):
        self.assertEqual(cf.classify([]), ([], []))

    def test_candidates_filter(self):
        mk = lambda n, **k: cf.PR(number=n, **k)  # noqa: E731
        prs = [mk(1), mk(2, draft=True), mk(3, same_repo=False), mk(4, labels={"hold"}), mk(5, base="dev"),
               mk(6, labels={"merge-conflict"})]
        self.assertEqual([p.number for p in cf.candidates(prs)], [1, 6])

    def test_comment_dedupe_is_per_head_sha(self):
        body = cf.comment_text(SHA, ["a.swift"])
        self.assertTrue(cf.already_commented([body], SHA))
        self.assertFalse(cf.already_commented([body], "b" * 40))
        self.assertFalse(cf.already_commented(["unrelated", None], SHA))

    def test_comment_lists_files_and_detail(self):
        body = cf.comment_text(SHA, ["a.swift", "b.swift"], "Push refused: x")
        for part in ("`a.swift`", "`b.swift`", "Push refused: x", cf.marker(SHA)):
            self.assertIn(part, body)

    def test_label_actions(self):
        self.assertEqual(cf.label_action(False, True), "add")
        self.assertIsNone(cf.label_action(True, True))
        self.assertEqual(cf.label_action(True, False), "remove")
        self.assertIsNone(cf.label_action(False, False))


class GitHubApi(unittest.TestCase):
    def test_open_prs_reads_fork_and_labels(self):
        gh = make_gh()
        gh.run.add(1, labels=["hold"])
        gh.run.add(2, repo="fork/r")
        got = {p.number: p for p in gh.open_prs()}
        self.assertTrue(got[1].same_repo)
        self.assertEqual(got[1].labels, {"hold"})
        self.assertFalse(got[2].same_repo)

    def test_mergeable_polls_until_known(self):
        gh = make_gh()
        gh.run.add(1, mergeable=[None, None, False])
        self.assertIs(gh.mergeable(1), False)
        self.assertEqual(gh.run.polls[1], 3)

    def test_mergeable_gives_up(self):
        gh = make_gh()
        gh.run.add(1, mergeable=None)
        self.assertIsNone(gh.mergeable(1))
        self.assertEqual(gh.run.polls[1], cf.POLLS)


class Round(unittest.TestCase):
    def go(self, gh, git):
        return cf.run_round(gh, git)

    def test_conflict_adds_label_and_one_comment(self):
        gh, git = make_gh(), FakeGit(cf.Outcome("conflict", files=["a.swift"]))
        gh.run.add(1, mergeable=False)
        self.go(gh, git)
        methods = [(m, p.split("/")[-1]) for m, p, _ in gh.run.writes]
        self.assertIn(("POST", "labels"), methods)
        self.assertEqual(len(gh.run.comments[1]), 1)
        self.assertIn("`a.swift`", gh.run.comments[1][0])
        # a second round at the same head: label is set by now, comment exists, git is not tried again
        gh.run.prs[1]["labels"] = [{"name": cf.LABEL}]
        self.go(gh, git)
        self.assertEqual(len(gh.run.comments[1]), 1)
        self.assertEqual(len(git.calls), 1)

    def test_new_head_gets_a_new_comment(self):
        gh, git = make_gh(), FakeGit(cf.Outcome("conflict", files=["a.swift"]))
        gh.run.add(1, mergeable=False, labels=[cf.LABEL])
        self.go(gh, git)
        gh.run.prs[1]["head"]["sha"] = "b" * 40
        self.go(gh, git)
        self.assertEqual(len(gh.run.comments[1]), 2)

    def test_resolved_push_removes_label_without_comment(self):
        gh, git = make_gh(), FakeGit(cf.Outcome("pushed"))
        gh.run.add(1, mergeable=False, labels=[cf.LABEL])
        self.go(gh, git)
        self.assertIn(("DELETE", f"repos/o/r/issues/1/labels/{cf.LABEL}", []), gh.run.writes)
        self.assertEqual(gh.run.comments[1], [])

    def test_clean_pr_loses_label_and_git_is_untouched(self):
        gh, git = make_gh(), FakeGit()
        gh.run.add(1, mergeable=True, labels=[cf.LABEL])
        gh.run.add(2, mergeable=True)
        self.go(gh, git)
        self.assertEqual(git.calls, [])
        self.assertEqual([w[0] for w in gh.run.writes], ["DELETE"])

    def test_unknown_mergeability_does_nothing(self):
        gh, git = make_gh(), FakeGit()
        gh.run.add(1, mergeable=None)
        self.assertIn("unknown", self.go(gh, git)[0])
        self.assertEqual((git.calls, gh.run.writes), ([], []))

    def test_hold_draft_and_fork_are_never_touched(self):
        gh, git = make_gh(), FakeGit()
        gh.run.add(1, mergeable=False, labels=["hold"])
        gh.run.add(2, mergeable=False, draft=True)
        gh.run.add(3, mergeable=False, repo="fork/r")
        self.assertEqual(self.go(gh, git), [])
        self.assertEqual((git.calls, gh.run.writes), ([], []))

    def test_comment_bodies_parse_like_gh_prints_them(self):
        gh = make_gh()
        gh.run.add(1)
        gh.run.comments[1] = ["plain text, not JSON", "two\nlines"]
        self.assertEqual(gh.comment_bodies(1), ["plain text, not JSON", "two\nlines"])

    def test_git_error_skips_that_pr_only(self):
        gh, git = make_gh(), FakeGit(error="boom")
        gh.run.add(1, mergeable=False)
        gh.run.add(2, mergeable=True)
        log = self.go(gh, git)
        self.assertIn("skipped (boom)", log[0])
        self.assertEqual(len(log), 2)


def sh(cwd, *args, env=None):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, env=dict(os.environ, **(env or {})))
    assert p.returncode == 0, (args, p.stderr)
    return p.stdout.strip()


class RealGit(unittest.TestCase):
    """The git half against real repositories: a bare origin, a pull request branch and a work checkout of main."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.origin, self.dev, self.work = (os.path.join(t, n) for n in ("origin.git", "dev", "work"))
        sh(t, "git", "init", "-q", "--bare", "-b", "main", self.origin)
        sh(t, "git", "clone", "-q", self.origin, self.dev)
        for k, v in (("user.name", "dev"), ("user.email", "dev@example.com")):
            sh(self.dev, "git", "config", k, v)
        self.write(self.dev, STATUS, "# Status\none\n")
        self.write(self.dev, "src/a.txt", "base\n")
        self.commit(self.dev, "base")
        sh(self.dev, "git", "push", "-q", "origin", "main")
        sh(t, "git", "clone", "-q", self.origin, self.work)

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def write(root, rel, text):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    @staticmethod
    def commit(root, msg):
        sh(root, "git", "add", "-A")
        sh(root, "git", "commit", "-q", "-m", msg)

    def branch(self, name, files):
        sh(self.dev, "git", "checkout", "-q", "-b", name, "main")
        for rel, text in files.items():
            self.write(self.dev, rel, text)
        self.commit(self.dev, name)
        sh(self.dev, "git", "push", "-q", "origin", name)
        sha = sh(self.dev, "git", "rev-parse", "HEAD")
        sh(self.dev, "git", "checkout", "-q", "main")
        return sha

    def main_moves(self, files):
        for rel, text in files.items():
            self.write(self.dev, rel, text)
        self.commit(self.dev, "main moves")
        sh(self.dev, "git", "push", "-q", "origin", "main")

    def bot(self, **kw):
        return cf.Git(self.work, **kw)

    def test_status_md_union_resolves_and_pushes_as_owner(self):
        sha = self.branch("feature/x", {STATUS: "# Status\none\nfrom branch\n"})
        self.main_moves({STATUS: "# Status\none\nfrom main\n"})
        out = self.bot().attempt("feature/x", sha)
        self.assertEqual(out.kind, "pushed", out)
        sh(self.dev, "git", "fetch", "-q", "origin")
        merged = sh(self.dev, "git", "show", "origin/feature/x:" + STATUS)
        self.assertIn("from branch", merged)
        self.assertIn("from main", merged)
        self.assertNotIn("<<<<", merged)
        who = sh(self.dev, "git", "log", "-1", "--format=%an <%ae>|%cn <%ce>|%(trailers:key=Agent-Role,valueonly)",
                 "origin/feature/x")
        self.assertIn(f"{cf.OWNER_NAME} <{cf.OWNER_EMAIL}>|{cf.OWNER_NAME} <{cf.OWNER_EMAIL}>|conflicts-bot", who)
        self.assertEqual(len(sh(self.dev, "git", "log", "-1", "--format=%P", "origin/feature/x").split()), 2)
        self.assertFalse(os.path.exists(os.path.join(self.work, ".git", "info", "attributes")))

    def test_source_conflict_aborts_and_lists_files(self):
        sha = self.branch("feature/y", {"src/a.txt": "branch\n", STATUS: "# Status\none\nb\n"})
        self.main_moves({"src/a.txt": "main\n", STATUS: "# Status\none\nm\n"})
        out = self.bot().attempt("feature/y", sha)
        self.assertEqual((out.kind, out.files), ("conflict", ["src/a.txt"]))
        self.assertEqual(sh(self.work, "git", "status", "--porcelain"), "")
        self.assertEqual(sh(self.dev, "git", "ls-remote", "origin", "refs/heads/feature/y").split()[0], sha)

    def test_generated_conflict_is_left_when_tools_missing(self):
        self.write(self.dev, SPIRV, "base\n")
        self.write(self.dev, cf.GENERATOR, "print(1)\n")
        self.commit(self.dev, "gen")
        sh(self.dev, "git", "push", "-q", "origin", "main")
        sh(self.work, "git", "pull", "-q")
        sha = self.branch("feature/g", {SPIRV: "branch\n"})
        self.main_moves({SPIRV: "main\n"})
        out = self.bot(which=lambda t: None, run=NoApt()).attempt("feature/g", sha)
        self.assertEqual((out.kind, out.files), ("conflict", [SPIRV]))
        self.assertIn("not installable", out.detail)

    def test_generated_conflict_is_regenerated_with_mains_generator(self):
        self.write(self.dev, SPIRV, "base\n")
        self.write(self.dev, cf.GENERATOR, "open('mpvfx-swift/Sources/CMpvfxVulkan/mpvfx_grade_spirv.h','w').write('regen\\n')\n")
        self.commit(self.dev, "gen")
        sh(self.dev, "git", "push", "-q", "origin", "main")
        sha = self.branch("feature/h", {SPIRV: "branch\n"})
        self.main_moves({SPIRV: "main\n"})
        out = self.bot(which=lambda t: "/bin/" + t).attempt("feature/h", sha)
        self.assertEqual(out.kind, "pushed", out)
        sh(self.dev, "git", "fetch", "-q", "origin")
        self.assertEqual(sh(self.dev, "git", "show", "origin/feature/h:" + SPIRV), "regen")

    def test_pr_changed_generator_is_never_run(self):
        self.write(self.dev, SPIRV, "base\n")
        self.write(self.dev, cf.GENERATOR, "print(0)\n")
        self.commit(self.dev, "gen")
        sh(self.dev, "git", "push", "-q", "origin", "main")
        sha = self.branch("feature/i", {SPIRV: "branch\n", cf.GENERATOR: "open('pwned','w')\n"})
        self.main_moves({SPIRV: "main\n"})
        out = self.bot(which=lambda t: "/bin/" + t).attempt("feature/i", sha)
        self.assertEqual(out.kind, "conflict")
        self.assertIn("generator itself", out.detail)
        self.assertFalse(os.path.exists(os.path.join(self.work, "pwned")))

    def test_moved_branch_is_skipped_and_hostile_names_refused(self):
        sha = self.branch("feature/z", {"src/b.txt": "b\n"})
        self.assertEqual(self.bot().attempt("feature/z", "c" * 40).kind, "uptodate")
        for bad in ("--upload-pack=x", "a..b", "a b", ""):
            with self.assertRaises(cf.Error):
                self.bot().attempt(bad, sha)


class NoApt:
    """A runner that fails apt-get/sudo and runs everything else."""

    def __call__(self, args, env=None, cwd=None):
        if args[0] in ("sudo", "apt-get"):
            return 1, "", "no"
        return cf.Runner()(args, env=env, cwd=cwd)


if __name__ == "__main__":
    unittest.main()

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
"""Unit tests of the integrate bot (integrate.py): pure decisions, a fake gh, and real temporary git repositories.

Run: python3 -I -B .github/ci/test_integrate.py
"""
import json, os, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import integrate as ig  # noqa: E402

STATUS = "mpvfx-swift/docs/STATUS.md"
SWIFT = "mpvfx-swift/Sources/MpvfxPlayer/A.swift"
ZED = "Co-authored-by: Zed Saranillo <saranillozed55@gmail.com>"


def item(n, sha=None, title="", body=""):
    return ig.Item(number=n, sha=sha or f"{n:040x}", title=title or f"title {n}", body=body)


class Ordering(unittest.TestCase):
    def test_stacked_pr_follows_its_base_even_with_a_lower_number(self):
        a, b, c = item(5), item(2), item(9)
        stacked = {(a.sha, b.sha)}          # a's head is an ancestor of b's head: b is stacked on a
        got = ig.order_items([b, c, a], lambda x, y: (x, y) in stacked)
        self.assertEqual([i.number for i in got], [5, 2, 9])

    def test_unrelated_prs_go_by_number(self):
        got = ig.order_items([item(7), item(3), item(5)], lambda x, y: False)
        self.assertEqual([i.number for i in got], [3, 5, 7])

    def test_a_chain_and_equal_heads_terminate(self):
        a, b, c, d = item(4), item(3), item(2), item(1, sha=item(2).sha)
        chain = {(a.sha, b.sha), (b.sha, c.sha), (a.sha, c.sha)}
        got = ig.order_items([c, b, a, d], lambda x, y: (x, y) in chain or (x, y) == (c.sha, d.sha))
        self.assertLess(got.index(a), got.index(b))
        self.assertLess(got.index(b), got.index(c))
        self.assertEqual(len(got), 4)

    def test_numbers_input_is_digits_only(self):
        self.assertEqual(ig.parse_numbers(" 12  7 12 "), [12, 7])
        self.assertEqual(ig.parse_numbers(""), [])
        for bad in ("1;rm", "$(x)", "a", "1,2", "-3"):
            with self.assertRaises(ig.Error):
                ig.parse_numbers(bad)


class Mapping(unittest.TestCase):
    LOG = ("/__w/o/o/mpvfx-swift/Sources/MpvfxPlayer/A.swift:10:5: error: cannot find 'x' in scope\n"
           "Sources/MpvfxRuntime/B.swift:3:1: error: boom\n"
           "/__w/o/o/mpvfx-swift/Sources/MpvfxPlayer/A.swift:11:1: warning: not an error\n")

    def test_paths_are_made_repository_relative(self):
        self.assertEqual(ig.error_paths(self.LOG),
                         ["mpvfx-swift/Sources/MpvfxPlayer/A.swift", "mpvfx-swift/Sources/MpvfxRuntime/B.swift"])
        self.assertEqual(ig.error_paths("/w/repo/mpvfx-swift/X.swift:1:1: error: e", root="/w/repo"),
                         ["mpvfx-swift/X.swift"])

    def test_errors_map_to_the_prs_that_changed_the_file(self):
        files = {1: ["mpvfx-swift/Sources/MpvfxPlayer/A.swift"], 2: ["docs/x.md"],
                 3: ["mpvfx-swift/Sources/MpvfxRuntime/B.swift", "other"]}
        self.assertEqual(ig.blame(ig.error_paths(self.LOG), files), [1, 3])
        self.assertEqual(ig.blame(["unrelated.swift"], files), [])

    def test_first_error_line(self):
        self.assertIn("cannot find 'x'", ig.first_error(self.LOG))
        self.assertEqual(ig.first_error("a\nlast line\n"), "last line")
        self.assertEqual(ig.first_error(""), "build failed")


INCLUDED = [{"number": 4, "title": "Fix A", "sha": "a" * 40, "files": [SWIFT]},
            {"number": 6, "title": "Add B", "sha": "b" * 40, "files": ["docs/b.md"]}]


class Texts(unittest.TestCase):
    def test_title_and_body(self):
        items = {4: item(4, body="Closes #11\nand fixes #12"), 6: item(6, body="Closes #11 again; Resolves #13")}
        skipped = [{"number": 8, "reason": "conflicts that need a person", "files": ["a.swift", "b|c.swift"]}]
        dropped = [{"number": 9, "error": "A.swift:1:1: error: boom", "files": ["A.swift"]}]
        body = ig.render_body(INCLUDED, skipped, dropped, items)
        self.assertEqual(ig.pr_title([4, 6]), "Integrate #4 #6")
        self.assertIn("- #4 Fix A\n- #6 Add B\n", body)
        self.assertEqual([l for l in body.splitlines() if l.startswith("Closes")],
                         ["Closes #11", "Closes #12", "Closes #13"])
        self.assertIn("## Skipped", body)
        self.assertIn("| #8 | conflicts that need a person | `a.swift`, `b|c.swift` |", body)
        self.assertIn("| #9 | dropped: the build failed (A.swift:1:1: error: boom) | `A.swift` |", body)

    def test_body_with_nothing_skipped(self):
        body = ig.render_body(INCLUDED, [], [], {})
        self.assertTrue(body.rstrip().endswith("None."))
        self.assertNotIn("Closes", body)

    def test_squash_message_without_audio_has_no_coauthor(self):
        msg = ig.commit_message(INCLUDED, [SWIFT, "docs/b.md"])
        self.assertTrue(msg.startswith("Integrate #4 #6\n\n- #4 Fix A\n- #6 Add B\n"))
        self.assertNotIn("Co-authored-by", msg)
        self.assertTrue(msg.endswith(ig.TRAILER))

    def test_squash_message_with_audio_or_caption_files_has_the_coauthor(self):
        for path in ("mpvfx-swift/Sources/MpvfxAudio/Mixer.swift", "mpvfx-swift/Sources/MpvfxAudioGraph/Bus.swift",
                     "mpvfx-swift/Sources/MpvfxPanels/CaptionsPanel.swift", "mpvfx-swift/docs/captions.md"):
            msg = ig.commit_message(INCLUDED, [SWIFT, path])
            self.assertEqual(msg.count(ZED), 1, path)
            self.assertTrue(msg.endswith(f"{ZED}\n{ig.TRAILER}"), path)

    def test_lookalike_paths_are_not_audio(self):
        self.assertFalse(ig.wants_zed(["mpvfx-swift/Sources/MpvfxAudioX/A.swift", "mpvfx-swift/Tests/MpvfxAudioTests/A.swift"]))


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def sh(cwd, *args):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    assert p.returncode == 0, (args, p.stderr)
    return p.stdout.strip()


class RealGit(unittest.TestCase):
    """A bare origin (with refs/pull/<n>/head like GitHub), a dev clone to write branches, and the bot's checkout."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.origin, self.dev, self.work = (os.path.join(t, n) for n in ("origin.git", "dev", "work"))
        sh(t, "git", "init", "-q", "--bare", "-b", "main", self.origin)
        sh(t, "git", "clone", "-q", self.origin, self.dev)
        for k, v in (("user.name", "dev"), ("user.email", "dev@example.com")):
            sh(self.dev, "git", "config", k, v)
        self.write(STATUS, "# Status\none\n")
        self.write("src/a.txt", "base\n")
        self.write("src/b.txt", "base\n")
        self.commit("base")
        sh(self.dev, "git", "push", "-q", "origin", "main")
        sh(t, "git", "clone", "-q", self.origin, self.work)
        self.base = sh(self.dev, "git", "rev-parse", "HEAD")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, text):
        path = os.path.join(self.dev, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def commit(self, msg):
        sh(self.dev, "git", "add", "-A")
        sh(self.dev, "git", "commit", "-q", "-m", msg)

    def pr(self, n, files, start="main"):
        sh(self.dev, "git", "checkout", "-q", "-b", f"pr{n}", start)
        for rel, text in files.items():
            self.write(rel, text)
        self.commit(f"pr {n}")
        sha = sh(self.dev, "git", "rev-parse", "HEAD")
        sh(self.dev, "git", "push", "-q", "origin", f"HEAD:refs/pull/{n}/head")
        sh(self.dev, "git", "checkout", "-q", "main")
        return sha

    def bot(self):
        g = ig.Git(self.work)
        g.configure_rerere()
        return g

    def items(self, *specs):
        return [item(n, sha=sha) for n, sha in specs]


class Assemble(RealGit):
    def test_fetch_takes_only_main_and_the_pr_heads(self):
        sha = self.pr(3, {"src/a.txt": "three\n"})
        heads = self.bot().fetch([3])
        self.assertEqual(heads, {3: sha})
        self.assertEqual(sh(self.work, "git", "tag", "-l"), "")

    def test_unresolved_pr_is_skipped_with_its_files_and_the_next_one_still_merges(self):
        s1 = self.pr(1, {"src/a.txt": "one\n"})
        s2 = self.pr(2, {"src/a.txt": "two\n"})           # conflicts with #1 on src/a.txt
        s3 = self.pr(3, {"src/b.txt": "three\n"})
        git = self.bot()
        git.fetch([1, 2, 3])
        with git.union_attributes():
            git.start(self.base)
            got = [git.merge_one(i) for i in self.items((1, s1), (2, s2), (3, s3))]
        self.assertEqual([g.kind for g in got], ["merged", "skipped", "merged"])
        self.assertEqual(got[1].files, ["src/a.txt"])
        self.assertIn("need a person", got[1].detail)
        self.assertEqual(sh(self.work, "git", "status", "--porcelain"), "")
        self.assertEqual(read(os.path.join(self.work, "src/a.txt")), "one\n")
        self.assertEqual(read(os.path.join(self.work, "src/b.txt")), "three\n")
        who = sh(self.work, "git", "log", "-1", "--format=%an <%ae>|%(trailers:key=Agent-Role,valueonly)")
        self.assertEqual(who, f"{ig.cf.OWNER_NAME} <{ig.cf.OWNER_EMAIL}>|integrate-bot")
        self.assertFalse(os.path.exists(os.path.join(self.work, ".git", "info", "attributes")))

    def test_status_md_conflict_takes_the_union(self):
        s1 = self.pr(1, {STATUS: "# Status\none\nfrom one\n"})
        s2 = self.pr(2, {STATUS: "# Status\none\nfrom two\n"})
        git = self.bot()
        git.fetch([1, 2])
        with git.union_attributes():
            git.start(self.base)
            kinds = [git.merge_one(i).kind for i in self.items((1, s1), (2, s2))]
        self.assertEqual(kinds, ["merged", "merged"])
        text = read(os.path.join(self.work, STATUS))
        self.assertIn("from one", text)
        self.assertIn("from two", text)
        self.assertNotIn("<<<<", text)

    def test_generated_workflow_conflict_is_regenerated_with_mains_generator(self):
        wf = ".github/workflows/x-source.yml"
        self.write(wf, "base\n")
        self.write(ig.SOURCE_GEN, "open('.github/workflows/x-source.yml','w').write('regen\\n')\n")
        self.commit("gen")
        sh(self.dev, "git", "push", "-q", "origin", "main")
        base = sh(self.dev, "git", "rev-parse", "HEAD")
        s1 = self.pr(1, {wf: "one\n"})
        s2 = self.pr(2, {wf: "two\n"})
        git = self.bot()
        sh(self.work, "git", "pull", "-q")
        git.fetch([1, 2])
        with git.union_attributes():
            git.start(base)
            kinds = [git.merge_one(i).kind for i in self.items((1, s1), (2, s2))]
        self.assertEqual(kinds, ["merged", "merged"])
        self.assertEqual(read(os.path.join(self.work, wf)), "regen\n")

    def test_a_pr_that_changes_the_workflow_generator_is_never_run(self):
        wf = ".github/workflows/x-source.yml"
        self.write(wf, "base\n")
        self.write(ig.SOURCE_GEN, "print(0)\n")
        self.commit("gen")
        sh(self.dev, "git", "push", "-q", "origin", "main")
        base = sh(self.dev, "git", "rev-parse", "HEAD")
        s1 = self.pr(1, {wf: "one\n"})
        s2 = self.pr(2, {wf: "two\n", ig.SOURCE_GEN: "open('pwned','w')\n"})
        git = self.bot()
        sh(self.work, "git", "pull", "-q")
        git.fetch([1, 2])
        with git.union_attributes():
            git.start(base)
            kinds = [(r.kind, r.detail) for r in (git.merge_one(i) for i in self.items((1, s1), (2, s2)))]
        self.assertEqual(kinds[0][0], "merged")
        self.assertEqual(kinds[1][0], "skipped")
        self.assertIn("generator itself", kinds[1][1])
        self.assertFalse(os.path.exists(os.path.join(self.work, "pwned")))

    def test_a_pr_already_in_main_is_contained(self):
        git = self.bot()
        git.start(self.base)
        self.assertEqual(git.merge_one(item(1, sha=self.base)).kind, "contained")

    def test_rerere_is_on_and_the_branch_is_reset_each_start(self):
        git = self.bot()
        self.assertEqual(sh(self.work, "git", "config", "rerere.enabled"), "true")
        self.assertEqual(sh(self.work, "git", "config", "rerere.autoupdate"), "true")
        s1 = self.pr(1, {"src/a.txt": "one\n"})
        git.fetch([1])
        git.start(self.base)
        git.merge_one(item(1, sha=s1))
        git.start(self.base)
        self.assertEqual(git.head(), self.base)
        self.assertEqual(sh(self.work, "git", "branch", "--show-current"), ig.BRANCH)

    def test_ancestor_check_orders_a_stack(self):
        s1 = self.pr(5, {"src/a.txt": "five\n"})
        s2 = self.pr(2, {"src/b.txt": "two\n"}, start="pr5")
        git = self.bot()
        git.fetch([5, 2])
        got = ig.order_items(self.items((2, s2), (5, s1)), git.is_ancestor)
        self.assertEqual([i.number for i in got], [5, 2])


class FakeGate:
    def __init__(self, errors, tests=""):
        self.errors, self.tests_out, self.calls, self.root = list(errors), tests, 0, "/w"

    def build(self):
        self.calls += 1
        return self.errors.pop(0) if self.errors else ""

    def tests(self):
        return self.tests_out


class Batch(RealGit):
    def run_batch(self, gate, specs):
        git = self.bot()
        git.fetch([n for n, _ in specs])
        with git.union_attributes():
            return ig.build_batch(git, gate, self.items(*specs), self.base)

    def test_clean_batch_passes_the_gate_once(self):
        s1 = self.pr(1, {"src/a.txt": "one\n"})
        s2 = self.pr(2, {"src/b.txt": "two\n"})
        gate = FakeGate([])
        res = self.run_batch(gate, [(1, s1), (2, s2)])
        self.assertEqual((res["gate"], gate.calls), ("passed", 1))
        self.assertEqual([i["number"] for i in res["included"]], [1, 2])
        self.assertEqual(res["included"][0]["files"], ["src/a.txt"])

    def test_build_error_drops_the_blamed_pr_and_rebuilds_without_it(self):
        s1 = self.pr(1, {"src/a.txt": "one\n"})
        s2 = self.pr(2, {"src/b.txt": "two\n"})
        gate = FakeGate(["/w/src/b.txt:1:1: error: broken"])
        res = self.run_batch(gate, [(1, s1), (2, s2)])
        self.assertEqual((res["gate"], gate.calls), ("passed", 2))
        self.assertEqual([i["number"] for i in res["included"]], [1])
        self.assertEqual([(d["number"], d["error"]) for d in res["dropped"]], [(2, "/w/src/b.txt:1:1: error: broken")])
        self.assertFalse(os.path.exists(os.path.join(self.work, "src/b.txt")) and
                         read(os.path.join(self.work, "src/b.txt")) == "two\n")

    def test_drops_stop_after_three_rounds(self):
        specs = [(n, self.pr(n, {f"mpvfx-swift/f{n}.txt": "x\n"})) for n in (1, 2, 3, 4, 5)]
        gate = FakeGate([f"mpvfx-swift/f{n}.txt:1:1: error: e{n}" for n in (1, 2, 3, 4)])
        res = self.run_batch(gate, specs)
        self.assertEqual(gate.calls, ig.MAX_DROP_ROUNDS + 1)
        self.assertEqual(res["gate"], "failed")
        self.assertEqual(len(res["dropped"]), ig.MAX_DROP_ROUNDS)

    def test_an_unmappable_error_fails_the_gate_without_dropping(self):
        s1 = self.pr(1, {"src/a.txt": "one\n"})
        gate = FakeGate(["ld: undefined symbol"])
        res = self.run_batch(gate, [(1, s1)])
        self.assertEqual((res["gate"], res["dropped"], gate.calls), ("failed", [], 1))
        self.assertEqual([i["number"] for i in res["included"]], [1])

    def test_unit_test_failure_fails_the_gate(self):
        s1 = self.pr(1, {"src/a.txt": "one\n"})
        res = self.run_batch(FakeGate([], tests="FAIL: test_x\nOK?"), [(1, s1)])
        self.assertEqual(res["gate"], "failed")
        self.assertIn("unit tests", res["gate_detail"])

    def test_every_pr_skipped_never_builds(self):
        s1 = self.pr(1, {"src/a.txt": "one\n"})
        sh(self.dev, "git", "checkout", "-q", "main")
        self.write("src/a.txt", "main\n")
        self.commit("main moves")
        sh(self.dev, "git", "push", "-q", "origin", "main")
        moved = sh(self.dev, "git", "rev-parse", "HEAD")
        git = self.bot()
        git.fetch([1])
        gate = FakeGate([])
        with git.union_attributes():
            res = ig.build_batch(git, gate, self.items((1, s1)), moved)
        self.assertEqual((gate.calls, res["gate"], res["included"], res["tip"]), (0, "none", [], moved))
        self.assertEqual([s["number"] for s in res["skipped"]], [1])


class Gate(unittest.TestCase):
    def test_gate_runs_the_two_swift_builds_then_the_unit_tests(self):
        calls = []

        def run(cmd, env=None, cwd=None):
            calls.append((cmd, cwd))
            return 0, "", ""
        gate = ig.Gate("/repo", run)
        self.assertEqual((gate.build(), gate.tests()), ("", ""))
        swift = [c for c, _ in calls if c[0] == "swift"]
        self.assertEqual(swift, [["swift", "build", "-Xswiftc", "-warnings-as-errors", "-Xcc", "-Werror"],
                                 ["swift", "build", "--build-tests"]])
        self.assertTrue(all(cwd == "/repo/mpvfx-swift" for c, cwd in calls if c[0] in ("swift",)))
        self.assertEqual(calls[-1], (ig.ROOT_TESTS, "/repo"))
        self.assertEqual(ig.ROOT_TESTS[-2:], ["-p", "test_*.py"])

    def test_first_failing_command_stops_the_gate_and_returns_its_output(self):
        def run(cmd, env=None, cwd=None):
            return (1, "out", "A.swift:1:1: error: x") if cmd[:2] == ["swift", "build"] and "-Werror" in cmd else (0, "", "")
        self.assertIn("error: x", ig.Gate("/repo", run).build())


class FakeGh:
    """A fake `gh`: pull requests in memory, every write recorded."""

    def __init__(self):
        self.prs, self.writes, self.batch = {}, [], None

    def add(self, n, labels=(), draft=False, repo="o/r", base="main", ref=None, state="open", sha=None):
        self.prs[n] = {"number": n, "state": state, "draft": draft, "title": f"t{n}", "body": f"Closes #{n + 100}",
                       "labels": [{"name": l} for l in labels],
                       "head": {"sha": sha or f"{n:040x}", "ref": ref or f"feature/{n}", "repo": {"full_name": repo}},
                       "base": {"ref": base, "repo": {"full_name": "o/r"}}}

    def __call__(self, args, env=None, cwd=None):
        method, path = args[3], args[4]
        fields = dict(a.split("=", 1) for i, a in enumerate(args) if i and args[i - 1] == "-f")
        if method != "GET":
            self.writes.append((method, path, fields))
            return 0, ("77\n" if method == "POST" and path.endswith("/pulls") else ""), ""
        if "?state=open&head=" in path:
            return 0, "" if self.batch is None else json.dumps({"number": self.batch}) + "\n", ""
        if path.startswith("repos/o/r/pulls?"):
            return 0, "".join(json.dumps(p) + "\n" for p in self.prs.values() if p["state"] == "open"), ""
        n = int(path.rsplit("/", 1)[1])
        return 0, json.dumps(self.prs[n]), ""


def gh_with(fake):
    return ig.GitHub("o/r", run=fake, sleep=lambda s: None)


class Candidates(unittest.TestCase):
    def test_default_is_every_labelled_pr_drafts_in_holds_forks_and_the_batch_out(self):
        f = FakeGh()
        f.add(1, labels=["merge-conflict"])
        f.add(2, labels=["merge-conflict"], draft=True)
        f.add(3, labels=["merge-conflict", "hold"])
        f.add(4, labels=["merge-conflict"], repo="fork/r")
        f.add(5, labels=["merge-conflict"], base="dev")
        f.add(6, labels=["merge-conflict"], ref=ig.BRANCH)
        f.add(7)
        self.assertEqual([i.number for i in gh_with(f).candidates([])], [1, 2])

    def test_named_prs_ignore_the_label_but_not_hold_or_closed(self):
        f = FakeGh()
        f.add(1)
        f.add(2, labels=["hold"])
        f.add(3, state="closed")
        f.add(4, repo="fork/r")
        self.assertEqual([i.number for i in gh_with(f).candidates([1, 2, 3, 4])], [1])

    def test_item_carries_title_body_and_head(self):
        f = FakeGh()
        f.add(1, labels=["merge-conflict"])
        got = gh_with(f).candidates([])[0]
        self.assertEqual((got.title, got.body, got.sha), ("t1", "Closes #101", f"{1:040x}"))


class FakeGit:
    def __init__(self, ancestors=True):
        self.log, self.ancestors = [], ancestors

    def unbundle(self, path, tip):
        self.log.append(("unbundle", path, tip))

    def is_ancestor(self, a, b):
        return self.ancestors

    def push_batch(self):
        self.log.append(("push",))


class Publish(unittest.TestCase):
    def setUp(self):
        self.f = FakeGh()
        for n in (4, 6, 8, 9):
            self.f.add(n, labels=["merge-conflict"], sha=INCLUDED[0]["sha"] if n == 4 else INCLUDED[1]["sha"] if n == 6 else None)
        self.plan = {"base": "c" * 40, "prs": [item(n, body=f"Closes #{n + 100}", title=f"title {n}").as_json() for n in (4, 6, 8, 9)]}
        self.result = {"base": "c" * 40, "tip": "d" * 40, "gate": "passed", "gate_detail": "", "included": INCLUDED,
                       "skipped": [{"number": 8, "reason": "conflicts that need a person", "files": ["x"]}],
                       "dropped": [{"number": 9, "title": "t", "error": "e", "files": ["y"]}], "contained": []}

    def go(self, merge=True, git=None):
        log = []
        git = git or FakeGit()
        ig.publish(gh_with(self.f), git, self.plan, self.result, merge, "b.bundle", log)
        return git, [(m, p.split("repos/o/r/")[1], fl) for m, p, fl in self.f.writes]

    def test_merge_squashes_closes_and_relabels(self):
        git, w = self.go()
        self.assertEqual(git.log[-1], ("push",))
        merge = next(x for x in w if x[1] == "pulls/77/merge")
        self.assertEqual(merge[2]["merge_method"], "squash")
        self.assertEqual(merge[2]["sha"], "d" * 40)
        self.assertEqual(merge[2]["commit_title"], "Integrate #4 #6 (#77)")
        self.assertNotIn("Co-authored-by", merge[2]["commit_message"])
        self.assertEqual([x[1] for x in w if x[2] == {"state": "closed"}], ["pulls/4", "pulls/6"])
        self.assertIn(("DELETE", "issues/4/labels/merge-conflict", {}), w)
        self.assertIn(("DELETE", "issues/6/labels/merge-conflict", {}), w)
        needs = [x[1] for x in w if x[2] == {"labels[]": ig.NEEDS}]
        self.assertEqual(needs, ["issues/8/labels", "issues/9/labels"])
        create = next(x for x in w if x[1] == "pulls")
        self.assertEqual((create[2]["head"], create[2]["base"], create[2]["title"]), (ig.BRANCH, "main", "Integrate #4 #6"))
        self.assertIn("Closes #104", create[2]["body"])

    def test_audio_change_adds_the_coauthor_to_the_squash_message_only(self):
        self.result["included"][0]["files"] = ["mpvfx-swift/Sources/MpvfxAudio/A.swift"]
        _, w = self.go()
        merge = next(x for x in w if x[1] == "pulls/77/merge")
        self.assertIn(ZED, merge[2]["commit_message"])
        create = next(x for x in w if x[1] == "pulls")
        self.assertNotIn("Zed", create[2]["body"])
        self.result["included"][0]["files"] = [SWIFT]

    def test_existing_batch_pr_is_updated_not_duplicated(self):
        self.f.batch = 50
        _, w = self.go(merge=False)
        self.assertIn("pulls/50", [x[1] for x in w])
        self.assertNotIn("pulls", [x[1] for x in w])

    def test_merge_off_or_failed_gate_opens_but_does_not_merge_or_close(self):
        _, w = self.go(merge=False)
        self.assertFalse([x for x in w if x[1].endswith("/merge") or x[2] == {"state": "closed"}])
        self.f.writes.clear()
        self.result["gate"] = "failed"
        _, w = self.go()
        self.assertFalse([x for x in w if x[1].endswith("/merge") or x[2] == {"state": "closed"}])
        self.assertTrue([x for x in w if x[1] == "pulls"])

    def test_a_head_that_moved_since_the_build_is_not_merged(self):
        self.f.prs[4]["head"]["sha"] = "e" * 40
        _, w = self.go()
        self.assertFalse([x for x in w if x[1].endswith("/merge")])

    def test_a_bundle_without_a_pr_head_is_refused_before_any_push(self):
        git = FakeGit(ancestors=False)
        with self.assertRaises(ig.Error):
            self.go(git=git)
        self.assertNotIn(("push",), git.log)
        self.assertEqual(self.f.writes, [])

    def test_nothing_included_only_labels_the_left_out(self):
        self.result.update(included=[], gate="none")
        git, w = self.go()
        self.assertEqual(git.log, [])
        self.assertEqual([x[1] for x in w if x[2] == {"labels[]": ig.NEEDS}], ["issues/8/labels", "issues/9/labels"])


class Summary(unittest.TestCase):
    def test_table_lists_included_skipped_and_dropped(self):
        res = {"gate": "failed", "gate_detail": "x", "included": INCLUDED,
               "skipped": [{"number": 8, "reason": "r", "files": ["a", "b"]}],
               "dropped": [{"number": 9, "error": "A.swift:1: error: e|f", "files": []}], "contained": [3]}
        text = ig.summary(res, "note")
        for part in ("| #4 Fix A | included |", "| #8 | skipped | r; 2 file(s) |", "| #9 | dropped | A.swift:1: error: e/f |",
                     "| #3 | already in main |", "note"):
            self.assertIn(part, text)


if __name__ == "__main__":
    unittest.main()

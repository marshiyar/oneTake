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
"""Tests for macos_gate.py (which pull requests must pass the macOS build, and the status decision) and for the
mpvfx-ci.yml wiring that makes ci-ok depend on it."""
import importlib.util
import os
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def load():
    spec = importlib.util.spec_from_file_location("macos_gate", os.path.join(HERE, "macos_gate.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


G = load()
S = "mpvfx-swift/Sources/"


class Classify(unittest.TestCase):
    def test_paths(self):
        for p in (S + "MpvfxDesktop/MacCanvasHost.swift", S + "MpvfxMetal/MetalRenderer.swift",
                  S + "MpvfxMetal/Shaders/x.h", "mpvfx-swift/Package.swift"):
            self.assertTrue(G.path_is_macos(p), p)
        self.assertFalse(G.path_is_macos(S + "MpvfxPlayer/Stage.swift"))
        self.assertFalse(G.path_is_macos(".github/ci/Mac.swift"))
        self.assertFalse(G.path_is_macos(S + "MpvfxPlayer/Package.swift"))
        self.assertFalse(G.path_is_macos(S + "MpvfxPlayer/Machine.txt"))

    def test_content_markers(self):
        for t in ("#if os(macOS)\n", "import AppKit\n", "#if canImport(AppKit)\n"):
            self.assertTrue(G.text_is_macos(t))
        self.assertFalse(G.text_is_macos("import Foundation\n#if os(Linux)\n"))

    def test_touches_reads_only_swift_under_the_package(self):
        reads = []

        def read(p):
            reads.append(p)
            return "import AppKit" if p.endswith("Host.swift") else "import Foundation"
        self.assertFalse(G.touches_macos(["README.md", S + "A/Stage.swift", S + "A/data.json"], read))
        self.assertEqual(reads, [S + "A/Stage.swift"])
        self.assertTrue(G.touches_macos([S + "A/Host.swift"], read))
        self.assertTrue(G.touches_macos([S + "A/Foo.swift", S + "A/MacX.swift"], read))

    def test_deleted_file_is_not_macos_and_unreadable_is(self):
        self.assertFalse(G.touches_macos([S + "A/Gone.swift"], lambda p: None))

        def boom(p):
            raise OSError("down")
        self.assertTrue(G.touches_macos([S + "A/Gone.swift"], boom))


class Decide(unittest.TestCase):
    def test_local_success_passes(self):
        self.assertEqual(G.decide("success", "false", "pending")[0], "pass")

    def test_not_sent_and_not_built_fails(self):
        for r in ("skipped", "failure", "cancelled"):
            self.assertEqual(G.decide(r, "false", "pending")[0], "fail")
            self.assertEqual(G.decide(r, "", "success")[0], "fail")

    def test_sent_follows_the_status(self):
        self.assertEqual(G.decide("skipped", "true", "success")[0], "pass")
        self.assertEqual(G.decide("skipped", "true", "failure")[0], "fail")
        self.assertEqual(G.decide("skipped", "true", "error")[0], "fail")
        self.assertEqual(G.decide("skipped", "true", "pending")[0], "wait")

    def test_newest_status_wins_and_other_contexts_are_ignored(self):
        st = [{"context": "other", "state": "failure"}, {"context": G.CONTEXT, "state": "success"},
              {"context": G.CONTEXT, "state": "failure"}]
        self.assertEqual(G.state_of(st), "success")
        self.assertEqual(G.state_of([]), "pending")


class Wait(unittest.TestCase):
    def run_wait(self, seq, minutes=1):
        now = [0.0]
        it = iter(seq)

        def read():
            return [{"context": G.CONTEXT, "state": next(it)}]

        def sleep(s):
            now[0] += s
        return G.wait(read, "true", minutes, 30, sleep, lambda: now[0])

    def test_passes_after_pending(self):
        self.assertEqual(self.run_wait(["pending", "success"])[0], "pass")

    def test_fails_on_failure(self):
        self.assertEqual(self.run_wait(["pending", "failure"])[0], "fail")

    def test_times_out(self):
        v, why = self.run_wait(["pending"] * 10)
        self.assertEqual(v, "fail")
        self.assertIn("did not report", why)


class Workflow(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, ".github", "workflows", "mpvfx-ci.yml"), encoding="utf-8") as f:
            self.jobs = yaml.safe_load(f)["jobs"]

    def test_changes_publishes_macos_code(self):
        self.assertEqual(self.jobs["changes"]["outputs"]["macos_code"], "${{ vars.LINUX_ONLY == 'false' && steps.mac.outputs.macos_code || 'false' }}")
        mac = next(s for s in self.jobs["changes"]["steps"] if s.get("id") == "mac")
        self.assertIn("macos_gate.py classify", mac["run"])

    def test_macos_code_builds_without_the_label(self):
        # Owner ruling 2026-10-22: no macOS in CI at all. Both jobs stay defined but run only
        # when the MACOS_IN_CI repository variable is 'true' (unset skips them); the owner
        # builds macOS locally. macos_code is still published (above) for documentation,
        # but nothing consumes it.
        for name in ("macos-runners", "macos"):
            self.assertEqual(self.jobs[name]["if"], "vars.MACOS_IN_CI == 'true'", name)

    def test_ci_ok_fails_only_on_a_red_macos_build_and_never_waits(self):
        # Owner ruling 2026-10-21: CI never holds a merge back waiting for the remote macOS build.
        gate = self.jobs["ci-ok"]
        self.assertIn("macos", gate["needs"])
        s = next(s for s in gate["steps"] if s.get("name") == "macOS build not red")
        self.assertIn("needs.changes.outputs.macos_code == 'true'", s["if"])
        self.assertEqual(s["env"]["LOCAL"], "${{ needs.macos.result }}")
        self.assertIn('"$LOCAL" != failure', s["run"])
        self.assertNotIn("macos_gate.py wait", s["run"])


if __name__ == "__main__":
    unittest.main()

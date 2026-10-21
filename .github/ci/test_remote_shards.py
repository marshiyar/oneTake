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
"""Tests for the test shards mpvfx-ci.yml sends to OneTake-app/OneTake-actionRunners-1: which shards go (test-shards.py
RUNNERS), that a sent shard never also runs here, that ci-ok requires the remote-shards job, remote_shards.py's
reading of the statuses, and the generated mpvfx-ci-tests-source.yml."""
import importlib.util
import os
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def text(name):
    with open(os.path.join(ROOT, ".github", "workflows", name), encoding="utf-8") as f:
        return f.read()


def step(job, prefix):
    return next(s for s in job["steps"] if s.get("name", "").startswith(prefix) or s.get("uses", "").startswith(prefix))


class Split(unittest.TestCase):
    def test_three_linux_shards_go_and_rest_and_every_windows_shard_stay(self):
        shards = load("test_shards", "test-shards.py")
        names = {s[0] for s in shards.SHARDS}
        self.assertEqual(shards.RUNNERS["linux"], {"library", "audio-presets", "audio-live"})
        self.assertLessEqual(shards.RUNNERS["linux"], names)
        self.assertNotIn("rest", shards.RUNNERS["linux"])   # it saves the debug build cache the local shards restore
        self.assertEqual(shards.RUNNERS["windows"], set())
        self.assertEqual(shards.RUNNERS["macos"], set())


class Plan(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(text("mpvfx-ci.yml"))["jobs"]
        self.pick = step(self.jobs["plan"], "Shards to run")

    def test_remote_only_with_both_secrets_and_never_for_a_fork(self):
        env = self.pick["env"]
        self.assertEqual(env["APP_ID"], "${{ secrets.RUNNERS_APP_ID }}")
        self.assertEqual(env["APP_KEY"], "${{ secrets.RUNNERS_APP_PRIVATE_KEY }}")
        self.assertEqual(env["OWN"], "${{ (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository) && needs.changes.outputs.workflow != 'true' }}")

    def test_a_pull_request_changing_the_moved_test_jobs_runs_every_shard_here(self):
        changes = self.jobs["changes"]
        self.assertEqual(changes["outputs"]["workflow"], "${{ steps.files.outputs.workflow }}")
        run = step(changes, "Changed files")["run"]
        self.assertIn(r"grep -qE '^\.github/(workflows/mpvfx-ci(-tests-source)?\.yml|ci/source_workflows\.py)$'", run)
        self.assertIn('[ "$n" -ge 3000 ]', run)
        self.assertIn('remote_ok = bool(os.environ["APP_ID"]) and bool(os.environ["APP_KEY"]) and os.environ["OWN"] == "true"', self.pick["run"])

    def test_a_sent_shard_is_not_in_the_local_lists(self):
        run = self.pick["run"]
        self.assertIn('remote = {o: [s for s in run if remote_ok and s["runners"]]', run)
        self.assertIn('local = {o: [s for s in run if s not in remote[o]]', run)
        self.assertIn("linux={json.dumps(local['linux'])}", run)
        self.assertIn("windows={json.dumps(local['windows'])}", run)
        outputs = self.jobs["plan"]["outputs"]
        self.assertEqual(outputs["linux_shards"], "${{ steps.pick.outputs.linux }}")
        self.assertEqual(self.jobs["linux-test"]["strategy"]["matrix"]["include"], "${{ fromJSON(needs.plan.outputs.linux_shards) }}")


class RemoteJob(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(text("mpvfx-ci.yml"))["jobs"]
        self.job = self.jobs["remote-shards"]

    def test_runs_only_when_the_plan_sent_a_shard(self):
        self.assertEqual(self.job["needs"], "plan")
        self.assertIn("needs.plan.result == 'success'", self.job["if"])
        self.assertIn("needs.plan.outputs.remote_linux != '[]'", self.job["if"])
        self.assertGreaterEqual(self.job["timeout-minutes"], 30 + 10)   # the longest shard's timeout and a margin

    def test_sends_names_and_waits_for_this_runs_statuses(self):
        send = step(self.job, "Send the shards")
        self.assertIn('"onetake-test-shards"', send["run"])
        self.assertIn('--argjson linux "$LINUX"', send["run"])
        self.assertEqual(send["env"]["SHA"], "${{ github.sha }}")
        wait = step(self.job, "Wait for every shard")
        self.assertEqual(wait["env"]["GITHUB_TOKEN"], "${{ github.token }}")
        self.assertEqual(wait["env"]["RUN"], "${{ github.run_id }}/${{ github.run_attempt }}")
        self.assertIn("remote_shards.py", wait["run"])
        self.assertIn('exit "${PIPESTATUS[0]}"', wait["run"])
        self.assertEqual(self.job["permissions"], {"contents": "read", "statuses": "read"})

    def test_records_a_pass_only_after_the_wait(self):
        names = [s.get("name", "") for s in self.job["steps"]]
        waited = names.index("Wait for every shard's status")
        saves = [i for i, n in enumerate(names) if n.startswith("Record the pass of linux")]
        self.assertEqual(len(saves), 3)
        self.assertTrue(all(i > waited for i in saves))

    def test_ci_ok_requires_it(self):
        gate = self.jobs["ci-ok"]
        self.assertIn("remote-shards", gate["needs"])
        self.assertIn("${{ needs.remote-shards.result }}", gate["steps"][0]["env"]["REQUIRED"])


class Waiter(unittest.TestCase):
    def setUp(self):
        self.mod = load("remote_shards", "remote_shards.py")
        self.expected = self.mod.contexts(["library", "audio-live"], [])

    def st(self, shard, state, run="9/1"):
        return {"context": f"linux test ({shard}) (runners-1)", "state": state, "description": f"x; oneTake run {run}"}

    def test_contexts_refuse_anything_but_a_shard_name(self):
        self.assertEqual(self.expected, ["linux test (library) (runners-1)", "linux test (audio-live) (runners-1)"])
        for bad in ("Library", "a b", "x)", 7, ""):
            with self.assertRaises(ValueError, msg=bad):
                self.mod.contexts([bad], [])

    def test_waits_until_every_shard_passed(self):
        states, done = self.mod.verdict([self.st("library", "success")], self.expected, "9/1")
        self.assertFalse(done)
        self.assertEqual(states["linux test (audio-live) (runners-1)"], "pending")
        states, done = self.mod.verdict([self.st("audio-live", "success"), self.st("library", "success")], self.expected, "9/1")
        self.assertTrue(done)
        self.assertEqual(set(states.values()), {"success"})

    def test_a_failure_or_error_finishes_at_once(self):
        for state in ("failure", "error"):
            _, done = self.mod.verdict([self.st("library", state)], self.expected, "9/1")
            self.assertTrue(done, state)

    def test_statuses_of_another_run_or_attempt_are_ignored_and_the_newest_counts(self):
        old = [self.st("library", "success", "9/0"), self.st("audio-live", "success", "8/1")]
        states, done = self.mod.verdict(old, self.expected, "9/1")
        self.assertFalse(done)
        self.assertEqual(set(states.values()), {"pending"})
        newest_first = [self.st("library", "failure"), self.st("library", "success"), self.st("audio-live", "success")]
        states, done = self.mod.verdict(newest_first, self.expected, "9/1")
        self.assertEqual(states["linux test (library) (runners-1)"], "failure")
        self.assertTrue(done)

    def test_a_shard_that_never_reports_fails_at_the_deadline(self):
        self.mod.statuses = lambda repo, sha, token: []
        self.mod.time.sleep = lambda s: None
        env = {"HEAD": "a" * 40, "RUN": "9/1", "GITHUB_REPOSITORY": "o/r", "GITHUB_TOKEN": "t", "LINUX": '["library"]'}
        saved = dict(os.environ)
        os.environ.update(env)
        try:
            self.assertEqual(self.mod.main(["--minutes", "0"]), 1)
            self.mod.statuses = lambda repo, sha, token: [self.st("library", "success")]
            self.assertEqual(self.mod.main(["--minutes", "0"]), 0)
        finally:
            os.environ.clear()
            os.environ.update(saved)


class Generated(unittest.TestCase):
    def setUp(self):
        self.wf = yaml.safe_load(text("mpvfx-ci-tests-source.yml"))

    def test_is_what_the_generator_writes_from_mpvfx_ci(self):
        gen = load("source_workflows", "source_workflows.py")
        self.assertEqual(text("mpvfx-ci-tests-source.yml"), gen.generate("mpvfx-ci-tests-source.yml", text("mpvfx-ci.yml")),
                         "stale: run python3 -I -B .github/ci/source_workflows.py")

    def test_a_plan_of_names_then_the_linux_shards_without_caches_secrets_or_stored_tokens(self):
        self.assertEqual(set(self.wf["on"]), {"workflow_call"})
        inputs = self.wf["on"]["workflow_call"]["inputs"]
        self.assertIs(inputs["source_ref"]["required"], True)
        self.assertEqual(inputs["linux_shards"]["default"], "[]")
        self.assertEqual(list(self.wf["jobs"]), ["plan", "linux-test"])
        job = self.wf["jobs"]["linux-test"]
        self.assertEqual(job["needs"], "plan")
        self.assertEqual(job["name"], "linux test (${{ matrix.shard }})")   # the runners repository reads this name
        for j in self.wf["jobs"].values():
            self.assertNotIn("permissions", j)
            self.assertFalse([s for s in j["steps"] if s.get("uses", "").startswith("actions/cache/")])
            checkout = step(j, "actions/checkout")
            self.assertEqual(checkout["with"]["ref"], "${{ inputs.source_ref }}")
            self.assertIs(checkout["with"]["persist-credentials"], False)
        self.assertFalse([s for s in job["steps"] if s.get("name", "").startswith("Record the pass")])
        self.assertNotIn("secrets.", text("mpvfx-ci-tests-source.yml"))

    def test_the_plan_takes_names_only_and_refuses_unknown_ones(self):
        pick = step(self.wf["jobs"]["plan"], "The shards asked for")
        self.assertEqual(pick["env"], {"LINUX": "${{ inputs.linux_shards }}"})
        self.assertIn("names a shard test-shards.py does not have", pick["run"])


if __name__ == "__main__":
    unittest.main()

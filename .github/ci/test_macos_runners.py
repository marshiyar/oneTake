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
"""Tests for the macOS hand-off to OneTake-app/OneTake-actionRunners-1 in mpvfx-ci.yml: when it is sent, the local
fallback, the inputs mpvfx-macos.yml takes for it, and ci-ok treating macOS as reported, not required."""
import importlib.util
import os
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def workflow(name):
    with open(os.path.join(ROOT, ".github", "workflows", name), encoding="utf-8") as f:
        return yaml.safe_load(f)


def step(job, name):
    return next(s for s in job["steps"] if s.get("name", "").startswith(name))


class Handoff(unittest.TestCase):
    def setUp(self):
        self.jobs = workflow("mpvfx-ci.yml")["jobs"]

    def test_sent_for_main_pushes_the_nightly_and_labelled_same_repository_pull_requests_only(self):
        cond = self.jobs["macos-runners"]["if"]
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/main'", cond)
        self.assertIn("contains(github.event.pull_request.labels.*.name, 'macos')", cond)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", cond)
        self.assertIn("|| github.event_name == 'schedule'", cond)
        self.assertNotIn("refs/tags", cond)   # a tag builds here: it is the official release

    def test_needs_both_secrets_before_minting_a_token(self):
        job = self.jobs["macos-runners"]
        have = step(job, "Runners App configured")
        self.assertEqual(set(have["env"]), {"APP_ID", "APP_KEY"})
        self.assertIn('[ -n "$APP_ID" ] && [ -n "$APP_KEY" ]', have["run"])
        self.assertEqual(step(job, "Runners App token")["if"], "steps.have.outputs.app == 'true'")

    def test_the_nightly_asks_for_every_shard(self):
        send = step(self.jobs["macos-runners"], "Hand the macOS build")
        self.assertEqual(send["env"]["FULL"], "${{ github.event_name == 'schedule' }}")
        self.assertIn('--arg full "$FULL"', send["run"])
        self.assertIn("full: $full", send["run"])

    def test_dispatch_names_this_repository_and_the_commit(self):
        send = step(self.jobs["macos-runners"], "Hand the macOS build")
        self.assertEqual(send["env"]["SHA"], "${{ github.event.pull_request.head.sha || github.sha }}")
        self.assertIn("repos/OneTake-app/OneTake-actionRunners-1/dispatches", send["run"])
        self.assertIn('--arg repo "$GITHUB_REPOSITORY"', send["run"])

    def test_the_local_job_builds_whenever_nothing_was_sent(self):
        macos = self.jobs["macos"]
        self.assertIn("macos-runners", macos["needs"])
        self.assertTrue(macos["if"].strip().startswith("always()"))
        self.assertIn("needs.macos-runners.outputs.sent != 'true'", macos["if"])
        self.assertEqual(macos["uses"], "./.github/workflows/mpvfx-macos.yml")


class SourceWorkflow(unittest.TestCase):
    """mpvfx-macos-source.yml, the entry point OneTake-actionRunners-1 calls (generated from mpvfx-macos.yml)."""

    def setUp(self):
        self.wf = workflow("mpvfx-macos-source.yml")
        self.steps = [s for j in self.wf["jobs"].values() for s in j["steps"]]

    def test_it_is_what_the_generator_writes(self):
        script = os.path.join(ROOT, ".github", "ci", "macos_source_workflow.py")
        spec = importlib.util.spec_from_file_location("gen", script)
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        with open(gen.SOURCE, encoding="utf-8") as f, open(gen.TARGET, encoding="utf-8") as g:
            self.assertEqual(g.read(), gen.generate(f.read()), "rerun .github/ci/macos_source_workflow.py")

    def test_only_a_call_with_a_named_commit_runs_it(self):
        on = self.wf["on"]   # the generator writes the key quoted, so it reads back as a string, not True
        self.assertEqual(list(on), ["workflow_call"])
        inputs = on["workflow_call"]["inputs"]
        self.assertTrue(inputs["source_repository"]["required"])
        self.assertTrue(inputs["source_ref"]["required"])

    def test_checkouts_take_the_source_and_keep_no_token(self):
        checkouts = [s for s in self.steps if s.get("uses", "").startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 3)
        for s in checkouts:
            self.assertEqual(s["with"], {"repository": "${{ inputs.source_repository }}",
                                         "ref": "${{ inputs.source_ref }}", "persist-credentials": False})

    def test_no_cache_and_no_secret(self):
        self.assertFalse([s for s in self.steps if "actions/cache" in s.get("uses", "")])
        values = [v for s in self.steps for v in (s.get("env") or {}).values() if isinstance(v, str)]
        self.assertFalse([v for v in values if "secrets." in v])

    def test_the_build_number_is_the_source_commit(self):
        package = next(s for s in self.steps if s.get("name", "").startswith("Package"))
        self.assertEqual(package["env"]["MPVFX_BUILD"], "${{ inputs.source_ref }}")

    def test_the_local_workflow_is_left_as_it_was(self):
        local = workflow("mpvfx-macos.yml")[True]["workflow_call"]["inputs"]
        self.assertNotIn("source_ref", local)


class Gate(unittest.TestCase):
    def setUp(self):
        self.gate = workflow("mpvfx-ci.yml")["jobs"]["ci-ok"]
        self.script = self.gate["steps"][0]["run"]

    def test_both_macos_jobs_are_reported_not_required(self):
        self.assertIn("macos-runners", self.gate["needs"])
        env = self.gate["steps"][0]["env"]
        self.assertEqual(env["MACOS"], "${{ needs.macos-runners.result }} ${{ needs.macos.result }}")
        self.assertNotIn("macos", env["REQUIRED"])
        self.assertIn('for r in $MACOS; do', self.script)
        self.assertIn("::warning::a macos job ended", self.script)

    def test_a_required_failure_still_fails(self):
        self.assertIn('for r in $REQUIRED; do', self.script)
        self.assertIn('echo "::error::a required job ended $r"; exit 1', self.script)


if __name__ == "__main__":
    unittest.main()

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

    def test_sent_for_main_pushes_and_labelled_same_repository_pull_requests_only(self):
        cond = self.jobs["macos-runners"]["if"]
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/main'", cond)
        self.assertIn("contains(github.event.pull_request.labels.*.name, 'macos')", cond)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", cond)
        self.assertNotIn("schedule", cond)

    def test_needs_both_secrets_before_minting_a_token(self):
        job = self.jobs["macos-runners"]
        have = step(job, "Runners App configured")
        self.assertEqual(set(have["env"]), {"APP_ID", "APP_KEY"})
        self.assertIn('[ -n "$APP_ID" ] && [ -n "$APP_KEY" ]', have["run"])
        self.assertEqual(step(job, "Runners App token")["if"], "steps.have.outputs.app == 'true'")

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


class Inputs(unittest.TestCase):
    def test_every_checkout_and_the_build_number_follow_the_source_inputs(self):
        wf = workflow("mpvfx-macos.yml")
        inputs = wf[True]["workflow_call"]["inputs"]   # PyYAML reads the key `on` as True
        self.assertEqual(inputs["source_repository"]["default"], "")
        self.assertEqual(inputs["source_ref"]["default"], "")
        checkouts = [s for j in wf["jobs"].values() for s in j.get("steps", [])
                     if "actions/checkout" in s.get("uses", "")]
        self.assertEqual(len(checkouts), 3)
        for s in checkouts:
            self.assertEqual(s["with"]["repository"], "${{ inputs.source_repository || github.repository }}")
            self.assertEqual(s["with"]["ref"], "${{ inputs.source_ref }}")
            self.assertIs(s["with"]["persist-credentials"], False)   # no token is left for the source's scripts
        steps = [s for j in wf["jobs"].values() for s in j.get("steps", [])]
        package = next(s for s in steps if s.get("name", "").startswith("Package"))
        self.assertEqual(package["env"]["MPVFX_BUILD"], "${{ inputs.source_ref || github.sha }}")

    def test_a_call_naming_a_source_gets_no_signing_secret(self):
        envs = [s.get("env") or {} for j in workflow("mpvfx-macos.yml")["jobs"].values() for s in j.get("steps", [])]
        secret = [v for env in envs for v in env.values() if isinstance(v, str) and "secrets." in v]
        self.assertEqual(len(secret), 5)
        for value in secret:
            self.assertIn("inputs.source_ref == '' && secrets.", value)

    def test_cache_keys_follow_the_source_commit(self):
        steps = [s for j in workflow("mpvfx-macos.yml")["jobs"].values() for s in j.get("steps", [])]
        # The build caches (macos27-*); the test-pass records are keyed by their inputs' hash instead.
        keys = [s["with"]["key"] for s in steps
                if "actions/cache" in s.get("uses", "") and s["with"]["key"].startswith("macos27-")]
        self.assertEqual(len(keys), 4)
        for key in keys:
            self.assertTrue(key.endswith("${{ inputs.source_ref || github.sha }}"), key)


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

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
"""Tests for the CodeQL Swift hand-off to OneTake-app/OneTake-actionRunners-1 in codeql.yml: when it is sent, that the
local swift job runs only when nothing was sent, and that the generated codeql-swift-source.yml never uploads,
holds a write token, a secret or a cache."""
import importlib.util
import os
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def workflow(name):
    with open(os.path.join(ROOT, ".github", "workflows", name), encoding="utf-8") as f:
        return yaml.safe_load(f)


def step(job, prefix):
    return next(s for s in job["steps"] if s.get("name", "").startswith(prefix) or s.get("uses", "").startswith(prefix))


class Handoff(unittest.TestCase):
    def setUp(self):
        self.wf = workflow("codeql.yml")
        self.jobs = self.wf["jobs"]

    def test_sent_for_main_pushes_and_same_repository_pull_requests_only(self):
        cond = self.jobs["swift-runners"]["if"]
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/main'", cond)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", cond)
        self.assertNotIn("schedule", cond)
        self.assertNotIn("workflow_dispatch", cond)

    def test_needs_both_secrets_before_minting_a_token(self):
        job = self.jobs["swift-runners"]
        have = step(job, "Runners App configured")
        self.assertEqual(set(have["env"]), {"APP_ID", "APP_KEY"})
        self.assertIn('[ -n "$APP_ID" ] && [ -n "$APP_KEY" ]', have["run"])
        self.assertEqual(step(job, "Runners App token")["if"],
                         "steps.have.outputs.app == 'true' && steps.own.outputs.changed != 'true'")

    def test_a_pull_request_changing_the_swift_job_is_analysed_here(self):
        job = self.jobs["swift-runners"]
        own = step(job, "Workflow files this pull request changes")
        self.assertEqual(own["if"], "github.event_name == 'pull_request'")
        self.assertEqual(own["env"]["WATCH"], r"^\.github/(workflows/codeql(-swift-source)?\.yml|ci/source_workflows\.py)$")
        self.assertIn('echo "changed=true"', own["run"])
        self.assertEqual(job["permissions"]["pull-requests"], "read")

    def test_dispatch_names_the_analysed_commit_its_ref_and_the_status_commit(self):
        send = step(self.jobs["swift-runners"], "Hand the Swift analysis")
        self.assertEqual(send["env"]["SHA"], "${{ github.sha }}")
        self.assertEqual(send["env"]["REF"], "${{ github.ref }}")
        self.assertEqual(send["env"]["HEAD"], "${{ github.event.pull_request.head.sha || github.sha }}")
        self.assertIn('"onetake-codeql-swift"', send["run"])
        self.assertIn("repos/OneTake-app/OneTake-actionRunners-1/dispatches", send["run"])
        self.assertIn('echo "sent=false"', send["run"])

    def test_the_local_swift_job_is_skipped_when_the_analysis_was_sent(self):
        swift = self.jobs["swift"]
        self.assertEqual(swift["needs"], "swift-runners")
        self.assertTrue(swift["if"].strip().startswith("always()"))
        self.assertIn("needs.swift-runners.outputs.sent != 'true'", swift["if"])
        self.assertEqual(swift["runs-on"], "macos-26")

    def test_python_and_actions_stay_local_on_every_event(self):
        job = self.jobs["scripts-and-workflows"]
        self.assertNotIn("if", job)
        self.assertEqual(job["strategy"]["matrix"]["language"], ["python", "actions"])


class Generated(unittest.TestCase):
    def setUp(self):
        self.wf = workflow("codeql-swift-source.yml")
        self.job = self.wf["jobs"]["swift"]

    def test_is_what_the_generator_writes_from_codeql_yml(self):
        spec = importlib.util.spec_from_file_location("source_workflows", os.path.join(HERE, "source_workflows.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        with open(os.path.join(ROOT, ".github", "workflows", "codeql.yml"), encoding="utf-8") as f:
            want = gen.generate("codeql-swift-source.yml", f.read())
        with open(os.path.join(ROOT, ".github", "workflows", "codeql-swift-source.yml"), encoding="utf-8") as f:
            self.assertEqual(f.read(), want, "stale: run python3 -I -B .github/ci/source_workflows.py")

    def test_only_called_with_a_required_source(self):
        on = self.wf["on"]   # the generator writes the key quoted, so PyYAML keeps it a string
        self.assertEqual(set(on), {"workflow_call"})
        for name in ("source_repository", "source_ref"):
            self.assertIs(on["workflow_call"]["inputs"][name]["required"], True)
        self.assertEqual(list(self.wf["jobs"]), ["swift"])
        self.assertNotIn("if", self.job)
        self.assertNotIn("needs", self.job)
        checkout = step(self.job, "actions/checkout")
        self.assertEqual(checkout["with"]["repository"], "${{ inputs.source_repository }}")
        self.assertEqual(checkout["with"]["ref"], "${{ inputs.source_ref }}")
        self.assertIs(checkout["with"]["persist-credentials"], False)

    def test_never_uploads_and_never_holds_a_write_token_a_secret_or_a_cache(self):
        analyze = step(self.job, "github/codeql-action/analyze")
        self.assertEqual(analyze["with"]["upload"], "never")
        self.assertEqual(self.wf["permissions"], {"contents": "read"})
        self.assertNotIn("permissions", self.job)
        self.assertFalse([s for s in self.job["steps"] if s.get("uses", "").startswith("actions/cache/")])
        with open(os.path.join(ROOT, ".github", "workflows", "codeql-swift-source.yml"), encoding="utf-8") as f:
            self.assertNotIn("secrets.", f.read())

    def test_the_sarif_file_is_the_artifact_the_runners_repository_uploads(self):
        art = step(self.job, "actions/upload-artifact")
        self.assertEqual(art["with"]["name"], "sarif-swift")
        self.assertEqual(art["with"]["if-no-files-found"], "error")


if __name__ == "__main__":
    unittest.main()

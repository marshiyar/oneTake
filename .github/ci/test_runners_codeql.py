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
local swift job runs only when nothing was sent, and that codeql-swift.yml never uploads or holds a write token."""
import os
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


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
        self.assertEqual(step(job, "Runners App token")["if"], "steps.have.outputs.app == 'true'")

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
        self.assertEqual(swift["uses"], "./.github/workflows/codeql-swift.yml")

    def test_the_local_upload_follows_the_local_analysis(self):
        up = self.jobs["swift-upload"]
        self.assertEqual(up["needs"], "swift")
        self.assertIn("needs.swift.result == 'success'", up["if"])
        self.assertEqual(up["permissions"]["security-events"], "write")
        sarif = next(s for s in up["steps"] if "upload-sarif" in s.get("uses", ""))
        self.assertEqual(sarif["with"]["category"], "/language:swift")

    def test_python_and_actions_stay_local_on_every_event(self):
        job = self.jobs["scripts-and-workflows"]
        self.assertNotIn("if", job)
        self.assertEqual(job["strategy"]["matrix"]["language"], ["python", "actions"])


class Reusable(unittest.TestCase):
    def setUp(self):
        self.wf = workflow("codeql-swift.yml")
        self.job = self.wf["jobs"]["analyze"]

    def test_only_called_and_follows_the_source_inputs(self):
        on = self.wf[True]   # PyYAML reads the key `on` as True
        self.assertEqual(set(on), {"workflow_call"})
        self.assertEqual(on["workflow_call"]["inputs"]["source_ref"]["default"], "")
        checkout = step(self.job, "actions/checkout")
        self.assertEqual(checkout["with"]["repository"], "${{ inputs.source_repository || github.repository }}")
        self.assertEqual(checkout["with"]["ref"], "${{ inputs.source_ref }}")
        self.assertIs(checkout["with"]["persist-credentials"], False)

    def test_never_uploads_and_never_holds_a_write_token_or_a_secret(self):
        analyze = step(self.job, "github/codeql-action/analyze")
        self.assertEqual(analyze["with"]["upload"], "never")
        self.assertEqual(self.wf["permissions"], {"contents": "read"})
        self.assertNotIn("permissions", self.job)
        with open(os.path.join(ROOT, ".github", "workflows", "codeql-swift.yml"), encoding="utf-8") as f:
            self.assertNotIn("secrets.", f.read())

    def test_the_sarif_file_is_the_artifact_the_uploaders_read(self):
        art = step(self.job, "actions/upload-artifact")
        self.assertEqual(art["with"]["name"], "sarif-swift")
        self.assertEqual(art["with"]["if-no-files-found"], "error")


if __name__ == "__main__":
    unittest.main()

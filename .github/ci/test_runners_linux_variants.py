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
"""Tests for the hand-off of the Linux build variants (linux-no-vulkan, linux-optional-headers) to
OneTake-app/OneTake-actionRunners-1: when it is sent, that the local build is skipped then, and the generated files."""
import importlib.util
import os
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
VARIANTS = {"linux-no-vulkan": "onetake-linux-no-vulkan", "linux-optional-headers": "onetake-linux-optional-headers"}


def text(name):
    with open(os.path.join(ROOT, ".github", "workflows", name), encoding="utf-8") as f:
        return f.read()


def step(job, prefix):
    return next(s for s in job["steps"] if s.get("name", "").startswith(prefix) or s.get("uses", "").startswith(prefix))


class Handoff(unittest.TestCase):
    def test_sent_for_every_event_but_a_fork_pull_request(self):
        for wf in VARIANTS:
            cond = yaml.safe_load(text(f"{wf}.yml"))["jobs"]["runners"]["if"]
            self.assertEqual(cond, "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository", wf)

    def test_needs_both_secrets_and_names_its_own_event(self):
        for wf, event in VARIANTS.items():
            job = yaml.safe_load(text(f"{wf}.yml"))["jobs"]["runners"]
            have = step(job, "Runners App configured")
            self.assertIn('[ -n "$APP_ID" ] && [ -n "$APP_KEY" ]', have["run"], wf)
            self.assertEqual(step(job, "Runners App token")["if"],
                             "steps.have.outputs.app == 'true' && steps.own.outputs.changed != 'true'", wf)
            send = step(job, "Hand the build")
            self.assertIn(f'"{event}"', send["run"], wf)
            self.assertEqual(send["env"]["SHA"], "${{ github.sha }}", wf)
            self.assertIn('echo "sent=false"', send["run"], wf)

    def test_a_pull_request_changing_the_build_builds_here(self):
        for wf in VARIANTS:
            job = yaml.safe_load(text(f"{wf}.yml"))["jobs"]["runners"]
            own = step(job, "Workflow files this pull request changes")
            self.assertEqual(own["if"], "github.event_name == 'pull_request'", wf)
            self.assertEqual(own["env"]["WATCH"], rf"^\.github/(workflows/{wf}(-source)?\.yml|ci/source_workflows\.py)$", wf)
            self.assertEqual(job["permissions"]["pull-requests"], "read", wf)

    def test_the_local_build_is_skipped_when_it_was_sent(self):
        for wf in VARIANTS:
            build = yaml.safe_load(text(f"{wf}.yml"))["jobs"]["build"]
            self.assertEqual(build["needs"], "runners", wf)
            self.assertEqual(build["if"], "${{ !cancelled() && needs.runners.outputs.sent != 'true' }}", wf)

    def test_the_vulkan_guard_stays_local_and_ungated(self):
        guard = yaml.safe_load(text("linux-no-vulkan.yml"))["jobs"]["guard"]
        self.assertNotIn("needs", guard)
        self.assertNotIn("if", guard)

    def test_runs_only_when_the_headerless_graph_can_change(self):
        # Throttle: Swift-only changes reuse mpvfx-ci's headed build; the variants run on the
        # manifest, the lockfile, the C shims, the guard and their own workflow files, plus the
        # nightly/weekly schedule and hand runs. Broad Sources/** or Tests/** globs would fire
        # both variants on every pull request again.
        for wf in VARIANTS:
            on = yaml.safe_load(text(f"{wf}.yml"))[True]
            for event in ("pull_request", "push"):
                paths = on[event]["paths"]
                self.assertIn("mpvfx-swift/Package.swift", paths, f"{wf}/{event}")
                self.assertIn("mpvfx-swift/binaries.lock", paths, f"{wf}/{event}")
                for noise in ("mpvfx-swift/Sources/**", "mpvfx-swift/Tests/**", "mpvfx-swift/tools/**",
                              "**/*.md"):
                    self.assertNotIn(noise, paths, f"{wf}/{event}")
            self.assertIn("schedule", on, wf)
            self.assertIn("workflow_dispatch", on, wf)


class Generated(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("source_workflows", os.path.join(HERE, "source_workflows.py"))
        self.gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.gen)

    def test_each_is_what_the_generator_writes(self):
        for wf in VARIANTS:
            self.assertEqual(text(f"{wf}-source.yml"), self.gen.generate(f"{wf}-source.yml", text(f"{wf}.yml")),
                             f"{wf}-source.yml is stale: run python3 -I -B .github/ci/source_workflows.py")

    def test_build_only_without_gates_caches_secrets_or_stored_tokens(self):
        for wf in VARIANTS:
            doc = yaml.safe_load(text(f"{wf}-source.yml"))
            self.assertEqual(set(doc["on"]), {"workflow_call"}, wf)
            self.assertIs(doc["on"]["workflow_call"]["inputs"]["source_ref"]["required"], True, wf)
            self.assertEqual(list(doc["jobs"]), ["build"], wf)
            job = doc["jobs"]["build"]
            for key in ("if", "needs", "permissions"):
                self.assertNotIn(key, job, wf)
            self.assertFalse([s for s in job["steps"] if s.get("uses", "").startswith("actions/cache/")], wf)
            checkout = step(job, "actions/checkout")
            self.assertEqual(checkout["with"]["repository"], "${{ inputs.source_repository }}", wf)
            self.assertEqual(checkout["with"]["ref"], "${{ inputs.source_ref }}", wf)
            self.assertIs(checkout["with"]["persist-credentials"], False, wf)
            self.assertNotIn("secrets.", text(f"{wf}-source.yml"), wf)


if __name__ == "__main__":
    unittest.main()

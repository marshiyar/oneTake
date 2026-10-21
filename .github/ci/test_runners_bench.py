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
"""Tests for the bench hand-off to OneTake-app/OneTake-actionRunners-1: bench.yml's runners job and the local jobs it
skips, the generated bench-source.yml, and agentbot reading the runners repository's bench runs."""
import importlib.util
import json
import os
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def text(name):
    with open(os.path.join(ROOT, ".github", "workflows", name), encoding="utf-8") as f:
        return f.read()


def step(job, prefix):
    return next(s for s in job["steps"] if s.get("name", "").startswith(prefix) or s.get("uses", "").startswith(prefix))


class Handoff(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(text("bench.yml"))["jobs"]

    def test_sent_for_main_after_ci_weekly_by_hand_and_same_repository_pull_requests(self):
        cond = self.jobs["runners"]["if"]
        self.assertIn("github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push'", cond)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", cond)
        self.assertIn("github.event_name == 'schedule'", cond)
        self.assertIn("github.event_name == 'workflow_dispatch'", cond)

    def test_needs_both_secrets_before_minting_a_token(self):
        job = self.jobs["runners"]
        have = step(job, "Runners App configured")
        self.assertEqual(set(have["env"]), {"APP_ID", "APP_KEY"})
        self.assertIn('[ -n "$APP_ID" ] && [ -n "$APP_KEY" ]', have["run"])
        self.assertEqual(step(job, "Runners App token")["if"],
                         "steps.have.outputs.app == 'true' && steps.own.outputs.changed != 'true'")

    def test_a_pull_request_changing_the_moved_jobs_benchmarks_here(self):
        job = self.jobs["runners"]
        own = step(job, "Workflow files this pull request changes")
        self.assertEqual(own["if"], "github.event_name == 'pull_request'")
        self.assertEqual(own["env"]["WATCH"], r"^\.github/(workflows/bench(-source)?\.yml|ci/source_workflows\.py)$")
        self.assertIn('echo "changed=true"', own["run"])
        self.assertEqual(job["permissions"]["pull-requests"], "read")

    def test_dispatch_carries_the_commit_its_kind_and_the_pull_request(self):
        send = step(self.jobs["runners"], "Hand the benchmarks")
        self.assertEqual(send["env"]["SHA"], "${{ github.sha }}")
        self.assertEqual(send["env"]["HEAD"], "${{ github.event.pull_request.head.sha || github.sha }}")
        self.assertEqual(send["env"]["PR"], "${{ github.event.pull_request.number }}")
        self.assertIn("'pr'", send["env"]["KIND"])
        self.assertIn("github.ref == 'refs/heads/main' && 'main'", send["env"]["KIND"])
        self.assertIn('"onetake-bench"', send["run"])
        self.assertIn('echo "sent=false"', send["run"])

    def test_linux_and_macos_run_here_only_when_nothing_was_sent(self):
        for name in ("linux", "macos"):
            job = self.jobs[name]
            self.assertEqual(job["needs"], "runners", name)
            self.assertTrue(job["if"].strip().startswith("!cancelled() && "), name)
            self.assertIn("needs.runners.outputs.sent != 'true'", job["if"], name)
            # main's own gate is kept: after CI only for this repository's green push to main
            self.assertIn("github.event.workflow_run.head_repository.full_name == github.repository", job["if"], name)

    def test_windows_always_runs_here(self):
        job = self.jobs["windows"]
        self.assertNotIn("needs", job)
        self.assertNotIn("sent", job["if"])


class Generated(unittest.TestCase):
    def setUp(self):
        self.wf = yaml.safe_load(text("bench-source.yml"))

    def test_is_what_the_generator_writes_from_bench_yml(self):
        self.assertEqual(text("bench-source.yml"), load("source_workflows").generate("bench-source.yml", text("bench.yml")),
                         "stale: run python3 -I -B .github/ci/source_workflows.py")

    def test_only_called_with_a_required_source_and_the_bench_inputs(self):
        inputs = self.wf["on"]["workflow_call"]["inputs"]
        self.assertEqual(set(self.wf["on"]), {"workflow_call"})
        self.assertIs(inputs["source_repository"]["required"], True)
        self.assertIs(inputs["source_ref"]["required"], True)
        self.assertEqual(inputs["runs"]["default"], 5)
        self.assertEqual(self.wf["env"]["RUNS"], "${{ inputs.runs || 5 }}")

    def test_linux_and_macos_only_without_gates_caches_secrets_or_stored_tokens(self):
        self.assertEqual(list(self.wf["jobs"]), ["linux", "macos"])
        for name, job in self.wf["jobs"].items():
            self.assertNotIn("if", job, name)
            self.assertNotIn("needs", job, name)
            self.assertNotIn("permissions", job, name)
            self.assertFalse([s for s in job["steps"] if s.get("uses", "").startswith("actions/cache/")], name)
            checkout = step(job, "actions/checkout")
            self.assertEqual(checkout["with"]["ref"], "${{ inputs.source_ref }}")
            self.assertIs(checkout["with"]["persist-credentials"], False)
            self.assertTrue(step(job, "actions/upload-artifact")["with"]["name"].startswith("bench-"))
        self.assertNotIn("secrets.", text("bench-source.yml"))
        self.assertEqual(self.wf["permissions"], {"contents": "read"})


def report(klass, commit="c" * 40, p50=10):
    return {"bench-x.json": json.dumps({"commit": commit, "machine": {"class": klass},
                                        "metrics": {"m": {"unit": "ms", "p50": p50, "p95": p50}}}).encode()}


class Agentbot(unittest.TestCase):
    def setUp(self):
        self.bot = load("agentbot")
        self.posted = []
        self.bot.upsert_comment = lambda pr, marker, body: self.posted.append((pr, marker, body))

    def test_a_run_with_no_bench_results_posts_nothing(self):
        self.bot.api = lambda method, path, body=None: {"pull_requests": [{"number": 7}], "head_sha": "a" * 40}
        self.bot.artifact_files = lambda *a, **k: {}
        self.bot.bench("1")
        self.assertEqual(self.posted, [])

    def test_a_run_whose_linux_and_macos_were_sent_lists_windows_only(self):
        jobs = {"jobs": [{"name": "linux", "conclusion": "skipped"}, {"name": "macos", "conclusion": "skipped"},
                         {"name": "windows", "conclusion": "success"}]}
        self.bot.api = lambda method, path, body=None: jobs if "/jobs" in path else {"pull_requests": [{"number": 7}], "head_sha": "a" * 40}
        self.bot.artifact_files = lambda run, name, suffix, repo=None: report("w") if name == "bench-windows" else {}
        self.bot.bench_baseline = lambda art, klass: None
        self.bot.bench("1")
        (pr, marker, body), = self.posted
        self.assertEqual((pr, marker), (7, "agentbot:bench"))
        self.assertIn("**windows**", body)
        self.assertNotIn("**linux**", body)

    def test_a_local_run_whose_linux_and_macos_failed_still_lists_them(self):
        jobs = {"jobs": [{"name": "linux", "conclusion": "failure"}, {"name": "macos", "conclusion": "failure"},
                         {"name": "windows", "conclusion": "success"}]}
        self.bot.api = lambda method, path, body=None: jobs if "/jobs" in path else {"pull_requests": [{"number": 7}], "head_sha": "a" * 40}
        self.bot.artifact_files = lambda run, name, suffix, repo=None: report("w") if name == "bench-windows" else {}
        self.bot.bench_baseline = lambda art, klass: None
        self.bot.bench("1")
        (_, _, body), = self.posted
        self.assertIn("**linux**: no result on this run", body)
        self.assertIn("**macos**: no result on this run", body)

    def test_bench_runners_refuses_malformed_values_before_any_request(self):
        self.bot.api = lambda *a, **k: self.fail("no request for a malformed payload")
        self.bot.RUNNERS_TOKEN = "t"
        for args in (("1x", "7", "a" * 40), ("1", "7;", "a" * 40), ("1", "7", "A" * 40), ("1", "7", "a" * 39)):
            with self.assertRaises(ValueError, msg=args):
                self.bot.bench_runners(*args)

    def test_bench_runners_posts_linux_and_macos_for_an_open_pull_request_at_that_head(self):
        head = "b" * 40
        calls = []

        def api(method, path, body=None, repo=None, token=None, **_):
            calls.append((path, repo))
            if path == "actions/runs/5":
                return {"path": ".github/workflows/onetake-bench.yml", "display_title": f"onetake-bench pr {'c' * 40} {head}"}
            return {"state": "open", "head": {"sha": head}}
        self.bot.api, self.bot.RUNNERS_TOKEN = api, "t"
        self.bot.artifact_files = lambda run, name, suffix, repo=None: report("l") if repo == self.bot.RUNNERS_REPO else {}
        self.bot.bench_baseline = lambda art, klass: json.loads(report(klass, p50=5)["bench-x.json"])
        self.bot.bench_runners("5", "7", head)
        self.assertEqual(calls[0], ("actions/runs/5", self.bot.RUNNERS_REPO))
        (pr, marker, body), = self.posted
        self.assertEqual((pr, marker), ("7", "agentbot:bench-runners"))
        self.assertIn("**linux**", body)
        self.assertIn("**macos**", body)
        self.assertNotIn("**windows**", body)
        self.assertIn("+100.0%", body)

    def test_bench_runners_ignores_a_main_run_and_a_moved_pull_request(self):
        runs = {"title": f"onetake-bench main {'c' * 40} {'b' * 40}", "head": "b" * 40}

        def api(method, path, body=None, **_):
            if path.startswith("actions/runs/"):
                return {"path": ".github/workflows/onetake-bench.yml", "display_title": runs["title"]}
            return {"state": "open", "head": {"sha": runs["head"]}}
        self.bot.api, self.bot.RUNNERS_TOKEN = api, "t"
        self.bot.artifact_files = lambda *a, **k: self.fail("nothing read")
        self.bot.bench_runners("5", "7", "b" * 40)
        runs.update(title=f"onetake-bench pr {'c' * 40} {'b' * 40}", head="d" * 40)
        self.bot.bench_runners("5", "7", "b" * 40)
        # a run of another head, sent with this pull request's number and head: refused before reading anything
        runs.update(title=f"onetake-bench pr {'c' * 40} {'e' * 40}", head="b" * 40)
        self.bot.bench_runners("5", "7", "b" * 40)
        self.assertEqual(self.posted, [])

    def test_the_baseline_is_the_newer_of_here_and_the_runners_repository(self):
        self.bot.RUNNERS_TOKEN = "t"
        here = {"id": 1, "created_at": "2026-10-20T00:00:00Z"}
        there = {"id": 2, "created_at": "2026-10-21T00:00:00Z"}
        self.bot.latest_main_run = lambda wf, art, accept, events: here if accept(1) else None
        self.bot.latest_runners_main_run = lambda accept: there if accept(2) else None
        self.bot.artifact_files = lambda rid, name, suffix, repo=None: report("k", commit=("t" if repo else "h") * 40)
        self.assertEqual(self.bot.bench_baseline("bench-linux", "k")["commit"], "t" * 40)
        there["created_at"] = "2026-10-19T00:00:00Z"
        self.assertEqual(self.bot.bench_baseline("bench-linux", "k")["commit"], "h" * 40)
        self.assertIsNone(self.bot.bench_baseline("bench-linux", "other class"))

    def test_runners_baselines_are_green_main_runs_only(self):
        runs = [{"id": 3, "conclusion": "success", "created_at": "3", "display_title": f"onetake-bench pr {'c' * 40} {'c' * 40}"},
                {"id": 2, "conclusion": "failure", "created_at": "2", "display_title": f"onetake-bench main {'c' * 40} {'c' * 40}"},
                {"id": 1, "conclusion": "success", "created_at": "1", "display_title": f"onetake-bench main {'c' * 40} {'c' * 40}"}]
        self.bot.api = lambda method, path, body=None, repo=None, token=None: {"workflow_runs": runs}
        self.assertEqual(self.bot.latest_runners_main_run(lambda rid: True)["id"], 1)


class AgentbotWorkflow(unittest.TestCase):
    def test_bench_runners_job_checks_the_payload_and_passes_it_through_env(self):
        wf = yaml.safe_load(text("agentbot.yml"))
        self.assertEqual(wf[True]["repository_dispatch"]["types"], ["runners-bench"])   # PyYAML reads `on` as True
        job = wf["jobs"]["bench-runners"]
        self.assertIn("github.event.action == 'runners-bench'", job["if"])
        check = step(job, "Check the payload")
        self.assertIn('[[ "$RUNNERS_RUN" =~ ^[0-9]{1,20}$ ]]', check["run"])
        self.assertIn('[[ "$SHA" =~ ^[0-9a-f]{40}$ ]]', check["run"])
        last = job["steps"][-1]
        self.assertEqual(last["run"], 'python3 -I -B .github/ci/agentbot.py bench-runners "$RUNNERS_RUN" "$PR" "$SHA"')
        self.assertNotIn("${{", last["run"])
        self.assertEqual(step(job, "Runners repository token")["with"]["permission-actions"], "read")


if __name__ == "__main__":
    unittest.main()

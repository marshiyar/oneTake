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
"""Tests for bench.py's budget check (--budgets, --check, --baseline), its preview record parsing, the committed
bench-budgets.json and bench_base.py's choice of main's report. Offline: nothing is run or fetched."""
import contextlib
import copy
import importlib.util
import io
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bench = load("bench")
bench_base = load("bench_base")

HOSTED = "github-hosted runner"
BUDGETS = {"schema": 1, "class": HOSTED, "regression_pct": 25, "os": {
    "linux": {"metrics": {
        "preview.1080p.realtime_new_frames_per_s": {"unit": "", "min": 29},
        "preview.scrub.seek_p95_ms": {"unit": "ms", "max": 800},
        "preview.scrub.peak_rss_mib": {"unit": "MiB", "max": 900},
        "startup.launch_to_first_frame_ms": {"unit": "ms", "max": 3000, "noisy": True},
    }},
    "windows": {"pending": "#92", "metrics": {}},
}}


def metric(unit, p50):
    return {"unit": unit, "p50": p50, "p95": p50, "max": p50, "n": 5, "samples": [p50] * 5}


def report(os_name="Linux 6.17", klass=HOSTED, benchmarks=("startup", "preview"), **overrides):
    metrics = {"preview.1080p.realtime_new_frames_per_s": metric("", 30),
               "preview.scrub.seek_p95_ms": metric("ms", 770),
               "preview.scrub.peak_rss_mib": metric("MiB", 714),
               "startup.launch_to_first_frame_ms": metric("ms", 1690)}
    for name, value in overrides.items():
        name = name.replace("__", ".")
        if value is None:
            metrics.pop(name)
        else:
            metrics[name] = value
    return {"commit": "ad97ffd0", "machine": {"os": os_name, "class": klass}, "benchmarks": list(benchmarks),
            "metrics": metrics}


def failed(rows):
    return {row[0]: row[4] for row in rows}


class Budgets(unittest.TestCase):
    def test_a_report_within_every_budget_passes(self):
        rows, notes = bench.check_budgets(report(), BUDGETS)
        self.assertEqual(rows, [])
        self.assertIn("linux: 4 budgets", notes[0])

    def test_a_p50_over_a_ceiling_or_under_a_floor_fails(self):
        r = report(preview__scrub__seek_p95_ms=metric("ms", 801), preview__1080p__realtime_new_frames_per_s=metric("", 28.9))
        self.assertEqual(failed(bench.check_budgets(r, BUDGETS)[0]),
                         {"preview.scrub.seek_p95_ms": "over the ceiling",
                          "preview.1080p.realtime_new_frames_per_s": "under the floor"})

    def test_a_p50_exactly_on_its_budget_passes(self):
        r = report(preview__scrub__seek_p95_ms=metric("ms", 800), preview__1080p__realtime_new_frames_per_s=metric("", 29))
        self.assertEqual(bench.check_budgets(r, BUDGETS)[0], [])

    def test_a_budgeted_metric_missing_from_the_results_fails(self):
        rows = bench.check_budgets(report(preview__scrub__peak_rss_mib=None), BUDGETS)[0]
        self.assertEqual(failed(rows), {"preview.scrub.peak_rss_mib": "missing from the results"})
        self.assertIsNone(rows[0][2])

    def test_a_metric_without_a_numeric_p50_counts_as_missing(self):
        r = report(preview__scrub__peak_rss_mib={"unit": "MiB", "p50": "714"})
        self.assertEqual(failed(bench.check_budgets(r, BUDGETS)[0]), {"preview.scrub.peak_rss_mib": "missing from the results"})

    def test_budgets_of_a_benchmark_the_run_left_out_are_not_checked(self):
        r = report(benchmarks=("startup",), preview__scrub__peak_rss_mib=None, preview__scrub__seek_p95_ms=None)
        self.assertEqual(bench.check_budgets(r, BUDGETS)[0], [])

    def test_a_changed_unit_fails(self):
        r = report(preview__scrub__seek_p95_ms=metric("us", 700))
        self.assertIn("unit is 'us'", failed(bench.check_budgets(r, BUDGETS)[0])["preview.scrub.seek_p95_ms"])

    def test_an_os_marked_pending_is_not_checked(self):
        rows, notes = bench.check_budgets(report(os_name="Windows 10", preview__scrub__seek_p95_ms=metric("ms", 9999)), BUDGETS)
        self.assertEqual(rows, [])
        self.assertIn("pending", notes[0])

    def test_another_machine_class_is_not_checked(self):
        rows, notes = bench.check_budgets(report(klass="local machine", preview__scrub__seek_p95_ms=metric("ms", 9999)), BUDGETS)
        self.assertEqual(rows, [])
        self.assertIn("not checked", notes[0])

    def test_a_missing_class_is_an_error_and_strict_refuses_another_class(self):
        for klass in (None, 7, ["x"]):
            with self.assertRaises(bench.BudgetError, msg=klass):
                bench.check_budgets(report(klass=klass), BUDGETS)
        with self.assertRaises(bench.BudgetError):
            bench.check_budgets(report(), dict(BUDGETS, **{"class": None}))
        with self.assertRaises(bench.BudgetError):
            bench.check_budgets(report(klass="local machine"), BUDGETS, strict=True)
        self.assertEqual(bench.check_budgets(report(), BUDGETS, strict=True)[0], [])

    def test_an_os_map_that_is_not_an_object_is_an_error(self):
        for by_os in (["bad"], "linux", 1, None):
            with self.assertRaises(bench.BudgetError, msg=by_os):
                bench.check_budgets(report(), dict(BUDGETS, os=by_os))

    def test_an_os_without_a_block_is_an_error(self):
        with self.assertRaises(bench.BudgetError):
            bench.check_budgets(report(os_name="Darwin 25.0"), BUDGETS)

    def test_a_malformed_budget_entry_is_an_error(self):
        for bad in ({"unit": "ms"}, {"unit": "ms", "min": 1, "max": 2}, {"unit": "ms", "max": "800"},
                    {"unit": "ms", "max": float("nan")}, {"unit": "ms", "max": True}, {"max": 800}, [800]):
            budgets = copy.deepcopy(BUDGETS)
            budgets["os"]["linux"]["metrics"]["preview.scrub.seek_p95_ms"] = bad
            with self.assertRaises(bench.BudgetError, msg=bad):
                bench.check_budgets(report(), budgets)

    def test_a_report_without_metrics_is_an_error(self):
        with self.assertRaises(bench.BudgetError):
            bench.check_budgets({"machine": {"os": "Linux", "class": HOSTED}, "benchmarks": []}, BUDGETS)


class RegressionAgainstMain(unittest.TestCase):
    def test_a_p50_more_than_25_percent_worse_than_main_fails(self):
        main = report(preview__scrub__peak_rss_mib=metric("MiB", 560))  # 714 is 27.5% over 560
        rows = bench.check_budgets(report(), BUDGETS, main)[0]
        self.assertEqual(failed(rows), {"preview.scrub.peak_rss_mib": "28% worse than main"})
        self.assertEqual(rows[0][3], "main 560")

    def test_a_floor_metric_more_than_25_percent_lower_than_main_fails(self):
        main = report(preview__1080p__realtime_new_frames_per_s=metric("", 41))  # 30 is 26.8% under 41
        self.assertIn("preview.1080p.realtime_new_frames_per_s", failed(bench.check_budgets(report(), BUDGETS, main)[0]))

    def test_up_to_25_percent_worse_or_any_better_passes(self):
        main = report(preview__scrub__peak_rss_mib=metric("MiB", 572), preview__scrub__seek_p95_ms=metric("ms", 1500))
        self.assertEqual(bench.check_budgets(report(), BUDGETS, main)[0], [])

    def test_a_noisy_metric_skips_the_rule_but_keeps_its_budget(self):
        main = report(startup__launch_to_first_frame_ms=metric("ms", 1000))
        self.assertEqual(bench.check_budgets(report(), BUDGETS, main)[0], [])
        mine = report(startup__launch_to_first_frame_ms=metric("ms", 3001))
        self.assertEqual(failed(bench.check_budgets(mine, BUDGETS, main)[0]), {"startup.launch_to_first_frame_ms": "over the ceiling"})

    def test_a_missing_main_value_a_changed_unit_or_a_zero_main_floor_is_not_compared(self):
        main = report(preview__scrub__seek_p95_ms=None, preview__1080p__realtime_new_frames_per_s=metric("fps", 60))
        self.assertEqual(bench.check_budgets(report(), BUDGETS, main)[0], [])
        main = report(preview__1080p__realtime_new_frames_per_s=metric("", 0))
        self.assertEqual(bench.check_budgets(report(), BUDGETS, main)[0], [])

    def test_a_ceiling_metric_above_a_zero_main_value_fails(self):
        main = report(preview__scrub__peak_rss_mib=metric("MiB", 0))
        rows = bench.check_budgets(report(), BUDGETS, main)[0]
        self.assertEqual(failed(rows), {"preview.scrub.peak_rss_mib": "above main's 0"})
        both_zero = report(preview__scrub__peak_rss_mib=metric("MiB", 0))
        self.assertEqual(bench.check_budgets(both_zero, BUDGETS, main)[0], [])

    def test_a_main_report_of_another_class_or_os_is_not_used(self):
        for main in (report(klass="local machine", preview__scrub__peak_rss_mib=metric("MiB", 100)),
                     report(os_name="Darwin 25.0", preview__scrub__peak_rss_mib=metric("MiB", 100))):
            rows, notes = bench.check_budgets(report(), BUDGETS, main)
            self.assertEqual(rows, [])
            self.assertIn("not applied", notes[1])

    def test_without_a_baseline_the_rule_is_skipped_with_a_note(self):
        self.assertIn("no main baseline", bench.check_budgets(report(), BUDGETS)[1][1])

    def test_a_bad_regression_pct_is_an_error(self):
        budgets = dict(BUDGETS, regression_pct="25")
        with self.assertRaises(bench.BudgetError):
            bench.check_budgets(report(), budgets, report())


class CommandLine(unittest.TestCase):
    def run_main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = bench.main(list(argv))
        return code, out.getvalue()

    def write(self, d, name, doc):
        path = os.path.join(d, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(doc if isinstance(doc, str) else json.dumps(doc))
        return path

    def test_check_exits_1_and_prints_a_table_of_failed_metrics(self):
        with tempfile.TemporaryDirectory() as d:
            mine = self.write(d, "mine.json", report(preview__scrub__seek_p95_ms=metric("ms", 950), preview__scrub__peak_rss_mib=None))
            code, out = self.run_main("--check", mine, "--budgets", self.write(d, "b.json", BUDGETS))
        self.assertEqual(code, 1)
        self.assertIn("**2 failed**", out)
        self.assertIn("| `preview.scrub.seek_p95_ms` | ms | 950 | ≤ 800 | over the ceiling |", out)
        self.assertIn("| `preview.scrub.peak_rss_mib` | MiB | - | ≤ 900 | missing from the results |", out)

    def test_check_exits_0_when_every_budget_holds(self):
        with tempfile.TemporaryDirectory() as d:
            code, out = self.run_main("--check", self.write(d, "mine.json", report()), "--budgets", self.write(d, "b.json", BUDGETS),
                                      "--baseline", os.path.join(d, "absent.json"))
        self.assertEqual(code, 0)
        self.assertIn("Every budget held.", out)
        self.assertIn("no main baseline", out)

    def test_check_uses_the_baseline_file(self):
        with tempfile.TemporaryDirectory() as d:
            main = self.write(d, "main.json", report(preview__scrub__peak_rss_mib=metric("MiB", 500)))
            code, out = self.run_main("--check", self.write(d, "mine.json", report()), "--budgets", self.write(d, "b.json", BUDGETS),
                                      "--baseline", main)
        self.assertEqual(code, 1)
        self.assertIn("43% worse than main", out)

    def test_unusable_inputs_exit_2(self):
        with tempfile.TemporaryDirectory() as d:
            good, budgets = self.write(d, "mine.json", report()), self.write(d, "b.json", BUDGETS)
            for argv in (("--check", self.write(d, "bad.json", "{not json"), "--budgets", budgets),
                         ("--check", good, "--budgets", self.write(d, "list.json", "[]")),
                         ("--check", good, "--budgets", os.path.join(d, "absent.json")),
                         ("--check", good, "--budgets", budgets, "--baseline", self.write(d, "cut.json", '{"metrics": ')),
                         ("--check", self.write(d, "local.json", report(klass="local machine")), "--budgets", budgets, "--strict")):
                code, out = self.run_main(*argv)
                self.assertEqual(code, 2, argv)
                self.assertIn("::error::bench budgets:", out)

    def test_check_needs_budgets_and_a_run_needs_out(self):
        for argv in (["--check", "x.json"], []):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as e:
                bench.parse_args(argv)
            self.assertEqual(e.exception.code, 2)


class CommittedBudgetFile(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(HERE, "bench-budgets.json"), encoding="utf-8") as f:
            self.doc = json.load(f)

    def test_linux_and_macos_have_valid_budgets_and_windows_is_pending_92(self):
        self.assertEqual(self.doc["class"], HOSTED)
        self.assertEqual(self.doc["regression_pct"], 25)
        for key in ("linux", "macos"):
            metrics = self.doc["os"][key]["metrics"]
            self.assertGreater(len(metrics), 50, key)
            for name, e in metrics.items():
                bench.budget_entry(name, e)
        self.assertIn("#92", self.doc["os"]["windows"]["pending"])
        self.assertEqual(self.doc["os"]["windows"]["metrics"], {})

    def test_it_cites_the_bench_run_it_comes_from(self):
        self.assertIn("actions/runs/39517931817", self.doc["source"]["base_run"])

    def test_the_issue_examples_hold(self):
        linux = self.doc["os"]["linux"]["metrics"]
        self.assertEqual(linux["preview.1080p.realtime_new_frames_per_s"], {"unit": "", "min": 29})
        for key in ("linux", "macos"):
            for scenario in ("1080p", "4k", "stacked", "graded", "scrub"):
                self.assertIn("max", self.doc["os"][key]["metrics"][f"preview.{scenario}.peak_rss_mib"])


class PreviewRecords(unittest.TestCase):
    def test_numbers_become_metrics_with_units_and_text_and_frames_are_left_out(self):
        r = bench.Results()
        bench.preview_record({"scenario": "4k", "fps": "29.9", "decode_ms": "8.5", "peak_rss_mib": "2000", "stalls": "0",
                              "frames": "300", "display": "headless", "lag": "nan"}, r)
        metrics = r.finish()
        self.assertEqual({k: m["unit"] for k, m in metrics.items()},
                         {"preview.4k.fps": "fps", "preview.4k.decode_ms": "ms", "preview.4k.peak_rss_mib": "MiB",
                          "preview.4k.stalls": ""})
        self.assertEqual(metrics["preview.4k.fps"]["p50"], 29.9)


class MainBaseline(unittest.TestCase):
    def test_the_report_inside_an_artifact_is_found(self):
        doc = {"machine": {"class": HOSTED}}
        self.assertEqual(bench_base.report_in({"preview.jsonl": b"{}", "bench-linux.json": json.dumps(doc).encode()}), doc)
        self.assertIsNone(bench_base.report_in({"bench.log": b""}))

    def test_the_newest_full_main_run_of_the_same_class_is_chosen_from_every_event(self):
        full = list(bench_base.ALL_BENCHMARKS)

        def art(commit, klass=HOSTED, benchmarks=None):
            if benchmarks is None:
                benchmarks = full
            return {"bench-linux.json": json.dumps({"commit": commit, "benchmarks": benchmarks,
                                                    "machine": {"class": klass}}).encode()}

        own = {"full_name": "o/r"}
        runs = {"workflow_run": [{"id": 5, "event": "workflow_run", "created_at": "2026-10-25", "head_repository": {"full_name": "fork/r"}},
                                 {"id": 4, "event": "workflow_run", "created_at": "2026-10-24", "head_repository": own},
                                 {"id": 1, "event": "workflow_run", "created_at": "2026-10-21", "head_repository": own}],
                "schedule": [{"id": 3, "event": "schedule", "created_at": "2026-10-23", "head_repository": own}],
                "workflow_dispatch": [{"id": 2, "event": "workflow_dispatch", "created_at": "2026-10-22", "head_repository": own}]}
        artifacts = {5: art("fork"), 4: art("laptop", klass="local machine"), 3: art("partial", benchmarks=["audio"]),
                     2: art("dispatch-full"), 1: art("older")}
        asked = []

        def pages(path, key):
            asked.append(path)
            self.assertEqual(key, "workflow_runs")
            return runs[path.split("event=")[1].split("&")[0]]

        saved = bench_base.bot.artifact_files, bench_base.bot.pages, bench_base.bot.REPO
        bench_base.bot.artifact_files = lambda rid, name, suffix: artifacts[rid]
        bench_base.bot.pages, bench_base.bot.REPO = pages, "o/r"
        try:
            run, doc = bench_base.main_report("bench-linux", HOSTED)
            self.assertEqual((run["id"], doc["commit"]), (2, "dispatch-full"))
            self.assertEqual(bench_base.main_report("bench-linux", "a laptop"), (None, None))
        finally:
            bench_base.bot.artifact_files, bench_base.bot.pages, bench_base.bot.REPO = saved
        self.assertTrue(all("branch=main" in p and "status=success" in p for p in asked))
        self.assertEqual({p.split("event=")[1].split("&")[0] for p in asked}, set(bench_base.EVENTS))


if __name__ == "__main__":
    unittest.main()

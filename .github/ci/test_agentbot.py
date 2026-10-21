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
"""Tests for agentbot.py's offline parts: failure lines, test names, PNG decode and compare, bench rows, flake state."""
import importlib.util, json, os, struct, unittest, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("agentbot", os.path.join(HERE, "agentbot.py"))
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

XCTEST = """2026-10-19T17:22:06.1Z Test Case 'A.testOne' started at 2026-10-19
2026-10-19T17:22:06.1Z /__w/x/Tests/A.swift:118: error: A.testOne : XCTAssertEqual failed: ("1") is not equal to ("2") -
2026-10-19T17:22:06.1Z /__w/x/Tests/A.swift:119: error: A.testOne : XCTAssertTrue failed -
2026-10-19T17:22:06.1Z Test Case 'A.testOne' failed (0.007 seconds)
2026-10-19T17:22:06.1Z Test Case 'A.testTwo' started at 2026-10-19
2026-10-19T17:22:06.1Z ##[error]batch 6 exited with 1
2026-10-19T17:22:07.1Z ##[error]Process completed with exit code 1.
"""
SWIFT_TESTING = """✘ Test exportRefusesHDR() recorded an issue at Export.swift:40:9: Expectation failed: (r == nil)
✘ Test exportRefusesHDR() failed after 0.012 seconds with 1 issue.
"""
COMPILE = """[12/440] Compiling MpvfxRuntime A.swift
/__w/x/Sources/A.swift:3:5: warning: var never mutated
/__w/x/Sources/B.swift:9:14: error: cannot find 'foo' in scope
 9 |     let x = foo()
/__w/x/Sources/B.swift:9:14: error: cannot find 'foo' in scope
##[error]Process completed with exit code 1.
"""
SCRIPT = """##[group]Run python3 -I -B scripts/fetch-binaries.py
\x1b[36;1mpython3 -I -B scripts/fetch-binaries.py\x1b[0m
shell: /usr/bin/bash -e {0}
env:
  XCODE_VERSION: 27.0
##[endgroup]
fetch-binaries: binaries.lock pins no SHA-256 for keyframes 1.0.0
##[error]Process completed with exit code 1.
"""


def png(w, h, pixels, ctype=6):
    """An 8-bit PNG with filter 0 rows; pixels: list of rows of channel bytes."""
    raw = b"".join(b"\0" + bytes(r) for r in pixels)
    chunk = lambda k, b: struct.pack(">I", len(b)) + k + b + struct.pack(">I", zlib.crc32(k + b) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class FailureLines(unittest.TestCase):
    def test_xctest_failures_without_progress_noise(self):
        lines = bot.failure_lines(XCTEST)
        self.assertEqual(len([l for l in lines if ": error: " in l]), 2)
        self.assertIn("Test Case 'A.testOne' failed (0.007 seconds)", lines)
        self.assertFalse(any("started" in l for l in lines))
        self.assertFalse(any("Process completed" in l for l in lines))
        self.assertEqual(bot.failed_tests(XCTEST), ["A.testOne"])

    def test_swift_testing_failures(self):
        self.assertTrue(bot.failure_lines(SWIFT_TESTING)[0].startswith("✘ Test exportRefusesHDR()"))
        self.assertEqual(bot.failed_tests(SWIFT_TESTING), ["exportRefusesHDR"])

    def test_compile_error_once_with_its_source_line_and_no_warnings(self):
        lines = bot.failure_lines(COMPILE)
        self.assertEqual(lines, ["/__w/x/Sources/B.swift:9:14: error: cannot find 'foo' in scope", " 9 |     let x = foo()"])

    def test_a_script_failure_shows_the_step_output_not_its_command_or_environment(self):
        self.assertEqual(bot.failure_lines(SCRIPT), ["fetch-binaries: binaries.lock pins no SHA-256 for keyframes 1.0.0",
                                                     "##[error]Process completed with exit code 1."])


class TestNames(unittest.TestCase):
    def test_objc_style_xctest_names_keep_the_method(self):
        log = ("Test Case '-[Module.FooTests testOne]' failed (0.1 seconds).\n"
               "Test Case '-[Module.FooTests testTwo]' failed (0.1 seconds).\n"
               "Test Case 'Module.BarTests.testThree' failed (0.1 seconds)\n")
        self.assertEqual(bot.failed_tests(log), ["Module.FooTests.testOne", "Module.FooTests.testTwo", "Module.BarTests.testThree"])


class Png(unittest.TestCase):
    def test_decode_rgb_and_rgba_and_compare(self):
        a = bot.png_decode(png(2, 1, [[10, 20, 30, 255, 40, 50, 60, 255]]))
        b = bot.png_decode(png(2, 1, [[10, 20, 30, 40, 50, 99]], ctype=2))
        self.assertEqual((a[0], a[1]), (2, 1))
        share, mean, rows = bot.png_compare(a, b)
        self.assertEqual(share, 0.5)
        self.assertGreater(mean, 0)
        w, h, back = bot.png_decode(bot.png_encode(2, 1, rows))
        self.assertEqual(back, rows)

    def test_size_change_and_limits(self):
        a, b = bot.png_decode(png(1, 1, [[0, 0, 0, 255]])), bot.png_decode(png(2, 1, [[0] * 8]))
        self.assertEqual(bot.png_compare(a, b), (1.0, 255.0, None))
        with self.assertRaises(ValueError):
            bot.png_decode(png(5000, 4000, [[0, 0, 0, 255]]))   # header says 20 M pixels: refused before decoding
        with self.assertRaises(ValueError):
            bot.png_decode(b"GIF89a")

    def test_malformed_pngs_are_value_errors(self):
        sig = b"\x89PNG\r\n\x1a\n"
        good = png(2, 1, [[10, 20, 30, 255, 40, 50, 60, 255]])
        bad = [sig,                                  # no IHDR
               sig + b"\0\0\0",                      # chunk header cut short
               sig + b"\0\0\0\x0dIHDR\0\0",           # IHDR longer than the file
               good[:len(good) - 20],                # IDAT cut short
               good.replace(b"IDAT", b"IDAX"),       # no image data
               good[:25] + b"\x05" + good[26:],      # colour type 5 does not exist
               png(1, 1, [[7]], ctype=3)]            # palette PNG without PLTE
        for data in bad:
            with self.assertRaises(ValueError, msg=data[:40]):
                bot.png_decode(data)


class Bench(unittest.TestCase):
    def test_rows_flag_a_p50_move_over_15_percent(self):
        main = {"metrics": {"a": {"unit": "ms", "p50": 10, "p95": 12}, "b": {"unit": "fps", "p50": 30, "p95": 31}}}
        pr = {"metrics": {"a": {"unit": "ms", "p50": 12, "p95": 15}, "b": {"unit": "fps", "p50": 31, "p95": 32},
                          "new": {"unit": "ms", "p50": 1, "p95": 1}}}
        rows, flagged = bot.bench_compare(pr, main)
        self.assertEqual(flagged, 1)
        self.assertEqual(len(rows), 2)
        self.assertIn("+20.0% **⚑**", rows[0])

    def test_a_changed_unit_is_not_compared(self):
        main = {"metrics": {"a": {"unit": "ms", "p50": 10, "p95": 12}}}
        pr = {"metrics": {"a": {"unit": "us", "p50": 10000, "p95": 12000}}}
        self.assertEqual(bot.bench_compare(pr, main), ([], 0))

    def test_a_zero_baseline_stays_visible_when_unchanged(self):
        report = {"metrics": {"grade.max_diff": {"unit": "levels", "p50": 0, "p95": 0}}}
        rows, flagged = bot.bench_compare(report, report)
        self.assertEqual(flagged, 0)
        self.assertEqual(rows, ["| `grade.max_diff` | levels | 0 → 0 | 0 → 0 | +0.0% |"])

    def test_a_move_from_zero_is_flagged_without_a_percentage(self):
        main = {"metrics": {"grade.max_diff": {"unit": "levels", "p50": 0, "p95": 0}}}
        for value in (1, -1):
            with self.subTest(value=value):
                pr = {"metrics": {"grade.max_diff": {"unit": "levels", "p50": value, "p95": value}}}
                rows, flagged = bot.bench_compare(pr, main)
                self.assertEqual(flagged, 1)
                self.assertEqual(rows, [f"| `grade.max_diff` | levels | 0 → {value} | 0 → {value} | from zero **⚑** |"])

    def test_a_missing_baseline_value_is_not_compared(self):
        pr = {"metrics": {"a": {"unit": "ms", "p50": 1, "p95": 2}}}
        for baseline in ({"unit": "ms", "p95": 2}, {"unit": "ms", "p50": None, "p95": 2}):
            with self.subTest(baseline=baseline):
                self.assertEqual(bot.bench_compare(pr, {"metrics": {"a": baseline}}), ([], 0))

    def test_a_move_to_zero_keeps_its_percentage(self):
        main = {"metrics": {"a": {"unit": "ms", "p50": 1, "p95": 2}}}
        pr = {"metrics": {"a": {"unit": "ms", "p50": 0, "p95": 0}}}
        self.assertEqual(bot.bench_compare(pr, main), (["| `a` | ms | 1 → 0 | 2 → 0 | -100.0% **⚑** |"], 1))


class Flakes(unittest.TestCase):
    def test_a_failure_is_scanned_once_across_reruns(self):
        # attempt 1 failed, 2 passed (recorded then), 3 is a rerun of the passing run: nothing new to scan.
        c = {1: "failure", 2: "success"}
        self.assertEqual(bot.failed_attempts(3, c.get), [])
        self.assertEqual(bot.failed_attempts(2, c.get), [1])
        # two failures in a row before the pass are both scanned
        c = {1: "failure", 2: "failure"}
        self.assertEqual(bot.failed_attempts(3, c.get), [1, 2])


    def test_counts_accumulate_and_survive_the_issue_body(self):
        state = bot.record_flakes({}, ["A.testOne"], "https://x/1", "2026-10-19T00:00:00Z")
        body = bot.flakes_body(bot.record_flakes(state, ["A.testOne", "job: linux"], "https://x/2", "2026-10-20T00:00:00Z"))
        back = json.loads(bot.STATE.search(body).group(1))
        self.assertEqual(back["A.testOne"]["count"], 2)
        self.assertEqual(back["job: linux"]["count"], 1)
        self.assertIn("| `A.testOne` | 2 | 2026-10-20 |", body)


class MainRun(unittest.TestCase):
    def test_a_forks_pull_request_from_its_main_is_never_the_baseline(self):
        runs = {"workflow_run": [{"id": 1, "event": "workflow_run", "conclusion": "success", "created_at": "2026-10-19",
                                  "head_repository": {"full_name": "o/app"}}],
                "pull_request": [{"id": 2, "event": "pull_request", "conclusion": "success", "created_at": "2026-10-20",
                                  "head_repository": {"full_name": "fork/app"}}],
                "schedule": [{"id": 3, "event": "schedule", "conclusion": "success", "created_at": "2026-10-21",
                              "head_repository": {"full_name": "fork/app"}}]}
        asked = []

        def api(method, path, body=None):
            if "/runs?" in path:
                event = path.split("event=")[1].split("&")[0]
                asked.append(event)
                return {"workflow_runs": runs.get(event, []) + runs["pull_request"]}   # a lax filter: still refused
            return {"artifacts": [{"name": "bench-linux"}]}
        saved = bot.api, bot.REPO
        bot.api, bot.REPO = api, "o/app"
        try:
            r = bot.latest_main_run("bench.yml", "bench-linux", events=("workflow_run", "schedule", "workflow_dispatch"))
        finally:
            bot.api, bot.REPO = saved
        self.assertEqual(r["id"], 1)
        self.assertEqual(asked, ["workflow_run", "schedule", "workflow_dispatch"])

if __name__ == "__main__":
    unittest.main()

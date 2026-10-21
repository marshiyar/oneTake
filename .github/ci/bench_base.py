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
"""bench_base.py: main's latest bench report of the same runner class, the baseline of bench.py --baseline.

  python3 .github/ci/bench_base.py <artifact> <this run's bench-<os>.json> <out file>

Finds the newest green bench run of this repository's main (bench.yml has no push trigger: workflow_run after green
CI, schedule and workflow_dispatch) whose artifact <artifact> holds a report measured on the same machine class as this
run's, and writes that report to <out file>. Writes nothing when main has none yet; bench.py then skips the regression
rule and says so. Talks to the REST API through agentbot.py's helpers ($GITHUB_TOKEN with actions: read,
$GITHUB_REPOSITORY); stdlib only. Never fails the job over an API problem (exit 0 with a ::warning::); exit 2 on bad
arguments.
"""
import importlib.util
import json
import os
import sys
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("agentbot", os.path.join(HERE, "agentbot.py"))
bot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bot)

EVENTS = ("workflow_run", "schedule", "workflow_dispatch")


def report_in(files):
    """The bench-<os>.json report among an artifact's {name: bytes}, or None."""
    for name, data in files.items():
        if name.startswith("bench-") and name.endswith(".json"):
            return json.loads(data)
    return None


def main_report(artifact, klass):
    """(main's run, its report) for the newest green main run of `artifact` measured on `klass`; (None, None)."""
    loaded = {}

    def same_class(run_id):
        loaded[run_id] = report_in(bot.artifact_files(run_id, artifact, ".json"))
        return isinstance(loaded[run_id], dict) and (loaded[run_id].get("machine") or {}).get("class") == klass

    run = bot.latest_main_run("bench.yml", artifact, same_class, events=EVENTS)
    return (run, loaded[run["id"]]) if run else (None, None)


def fetch(artifact, mine_path, out_path):
    with open(mine_path, encoding="utf-8") as f:
        klass = (json.load(f).get("machine") or {}).get("class")
    run, report = main_report(artifact, klass)
    if not run:
        print(f"bench_base: main has no green bench run with {artifact} measured on a {klass!r} yet")
        return
    with open(out_path + ".part", "w", encoding="utf-8") as f:  # whole or absent: bench.py reads a missing file as none
        json.dump(report, f, indent=1, sort_keys=True)
    os.replace(out_path + ".part", out_path)
    print(f"bench_base: main's run {run['id']} (commit {str(report.get('commit', ''))[:7]}) -> {out_path}")


def main(argv):
    if len(argv) != 4:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    if not bot.REPO or not bot.TOKEN:
        print("bench_base: GITHUB_REPOSITORY and GITHUB_TOKEN are required", file=sys.stderr)
        return 2
    try:
        fetch(*argv[1:])
    except (urllib.error.URLError, OSError, ValueError, KeyError, AttributeError) as e:
        print(f"::warning::bench_base: no main baseline ({e}); the regression rule is skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

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
"""run-shard.py: run one test shard (env FILTER and SKIP, from test-shards.py) of the built tests (run from mpvfx-swift).

On Linux and Windows SwiftPM hands the XCTest runner every selected test in one comma-joined argument. For a shard
that selects most of the suite (shard "rest") that argument is longer than a Windows command line may be: run
39216086983 stopped with "The file name is invalid" (Windows error 206) before running a test. So this lists the
built tests, selects the shard's tests with the same regular expressions, and runs them in batches of whole classes
(or the selected tests of a class) whose argument stays far below that limit. Every selected test runs once. A listed
name this script cannot parse (a Swift Testing test, say) fails the shard rather than being left out of every shard.
Exit code: 0 when every batch passed, otherwise 1 (a batch's own code can reach bash on Windows truncated to 8 bits).
"""
import os, re, subprocess, sys

LIMIT = 12000   # characters of test names per batch; Windows allows 32767 for the whole command line
SPEC = re.compile(r"^(\w+)\.(\w+)/(\w+)$")


def main():
    flt, skip = os.environ.get("FILTER", ""), os.environ.get("SKIP", "")
    listed = subprocess.run(["swift", "test", "list", "--skip-build"], capture_output=True, text=True)
    if listed.returncode != 0:
        print(listed.stdout + listed.stderr)
        return listed.returncode
    names = [t.strip() for t in listed.stdout.splitlines() if t.strip()]
    tests = [t for t in names if SPEC.match(t)]
    odd = [t for t in names if not SPEC.match(t)]
    if odd:
        print(f"::error::{len(odd)} listed tests are not Module.Class/test names, so no shard would run them: {odd[:5]}")
        return 1
    chosen = [t for t in tests if (not flt or re.search(flt, t)) and not (skip and re.search(skip, t))]
    if not chosen:
        print(f"::error::no test matches filter {flt!r} skip {skip!r} among {len(tests)} listed tests")
        return 1
    by_class = {}
    for t in tests:
        by_class.setdefault(t.split("/")[0], []).append(t)
    picked = {}
    for t in chosen:
        picked.setdefault(t.split("/")[0], []).append(t)
    batches, size = [[]], 0
    for cls, ts in picked.items():
        n = sum(len(t) + 1 for t in ts)
        if batches[-1] and size + n > LIMIT:
            batches.append([])
            size = 0
        batches[-1].append((cls, ts))
        size += n
    print(f"shard: {len(chosen)} of {len(tests)} tests, {len(picked)} classes, {len(batches)} batches", flush=True)
    code = 0
    for i, batch in enumerate(batches, 1):
        parts = []
        for cls, ts in batch:
            whole = len(ts) == len(by_class[cls])
            parts.append(re.escape(cls) + "/" if whole else
                         re.escape(cls) + "/(" + "|".join(re.escape(t.split("/")[1]) for t in ts) + ")$")
        pattern = "^(" + "|".join(parts) + ")"
        print(f"--- batch {i}/{len(batches)}: {sum(len(ts) for _, ts in batch)} tests", flush=True)
        r = subprocess.run(["swift", "test", "--skip-build", "--filter", pattern])
        if r.returncode != 0:
            print(f"::error::batch {i} exited with {r.returncode}", flush=True)
            code = 1
    return code


if __name__ == "__main__":
    sys.exit(main())

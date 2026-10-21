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
"""remote_shards.py [--minutes N] [--every S]: waits for the test shards mpvfx-ci.yml sent to
OneTake-app/OneTake-actionRunners-1 (job remote-shards) and exits 0 only when every one of them passed.

Reads from the environment: LINUX and WINDOWS (JSON lists of shard names), HEAD (the commit carrying the statuses), RUN
(this run's "<run id>/<attempt>"), GITHUB_REPOSITORY and GITHUB_TOKEN (statuses: read). Each shard reports the commit
status `<os> test (<shard>) (runners-1)`, whose description ends with "oneTake run <RUN>"; a status naming another
run (an earlier attempt, a run of another merge commit with the same head) is not this run's and is ignored. Reads
the statuses once every S seconds (default 60) and exits 1 as soon as one shard failed or errored, or when one has not
passed after N minutes (default 45). Talks to the REST API with urllib; stdlib only.
"""
import argparse, json, os, re, sys, time, urllib.error, urllib.request

API = "https://api.github.com"
SHARD = re.compile(r"^[a-z][a-z-]{0,30}$")


def contexts(linux, windows):
    """The status context of each shard sent, in the order sent."""
    out = []
    for os_name, names in (("linux", linux), ("windows", windows)):
        for name in names:
            if not isinstance(name, str) or not SHARD.match(name):
                raise ValueError(f"not a shard name: {name!r}")
            out.append(f"{os_name} test ({name}) (runners-1)")
    return out


def verdict(statuses, expected, run):
    """({context: state}, finished) for this run: state is that context's newest status naming `run` (pending when it
    has none yet). statuses: the API's list, newest first. Finished when one failed or errored, or none is pending."""
    mark = f"oneTake run {run}"
    states = {c: "pending" for c in expected}
    seen = set()
    for st in statuses:
        c = st.get("context")
        if c in states and c not in seen and (st.get("description") or "").endswith(mark):
            seen.add(c)
            states[c] = st.get("state", "pending")
    failed = any(s in ("failure", "error") for s in states.values())
    return states, failed or all(s == "success" for s in states.values())


def statuses(repo, sha, token):
    """Every status of the commit, newest first (up to 300: three pages)."""
    out = []
    for page in (1, 2, 3):
        req = urllib.request.Request(f"{API}/repos/{repo}/commits/{sha}/statuses?per_page=100&page={page}", headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "mpvfx-remote-shards"})
        with urllib.request.urlopen(req, timeout=60) as r:
            got = json.loads(r.read())
        out += got
        if len(got) < 100:
            break
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--minutes", type=float, default=45)
    ap.add_argument("--every", type=float, default=60)
    a = ap.parse_args(argv)
    env = os.environ
    sha, run, repo, token = env.get("HEAD", ""), env.get("RUN", ""), env.get("GITHUB_REPOSITORY", ""), env.get("GITHUB_TOKEN", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not re.fullmatch(r"[0-9]+/[0-9]+", run) or not repo or not token:
        print("remote_shards: HEAD, RUN, GITHUB_REPOSITORY and GITHUB_TOKEN are required", file=sys.stderr)
        return 2
    expected = contexts(json.loads(env.get("LINUX") or "[]"), json.loads(env.get("WINDOWS") or "[]"))
    deadline = time.monotonic() + a.minutes * 60
    states = {c: "pending" for c in expected}
    while True:
        try:
            states, finished = verdict(statuses(repo, sha, token), expected, run)
        except (urllib.error.URLError, OSError, ValueError) as e:   # one failed read is retried, not fatal
            print(f"::warning::statuses not read: {e}")
            finished = False
        if finished or time.monotonic() >= deadline:
            break
        time.sleep(a.every)
    print("| shard | state |\n|---|---|")
    for c, s in states.items():
        print(f"| `{c}` | {s} |")
    bad = [c for c, s in states.items() if s != "success"]
    for c in bad:
        what = "did not report" if states[c] == "pending" else f"ended {states[c]}"
        print(f"::error::{c} {what} (OneTake-app/OneTake-actionRunners-1, oneTake run {run})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

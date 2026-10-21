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
"""stale_in_progress.py [--dry-run] [--hours N]: stale `in-progress` issues go back to the ready queue.

An open issue labelled `in-progress` is stale when no open pull request links it and none of its labels changed for
`--hours` (48 by default). A pull request links it when its title or body names it (`#n`, `owner/repo#n` or the
issue's URL, closing keyword or not) or its head branch names it (`<n>-...` or `.../<n>-...`).

For each stale issue: `in-progress` is removed, `buildable` is added unless `blocked` is set, and one comment says
why. Issues labelled `launch-blocker` or `needs-owner` are never touched. With --dry-run (or DRY_RUN=true) it prints
what it would change and writes nothing.

Standard library only; GitHub is reached through the `gh` CLI via `Runner`, which tests replace.
"""
import argparse
import dataclasses
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.parse

IN_PROGRESS, BUILDABLE, BLOCKED = "in-progress", "buildable", "blocked"
SKIP = frozenset({"launch-blocker", "needs-owner"})
HOURS = 48
MARKER = "<!-- stale-in-progress -->"


class Error(Exception):
    pass


@dataclasses.dataclass
class Issue:
    number: int
    labels: set
    created_at: str = ""


@dataclasses.dataclass
class Pull:
    number: int
    title: str = ""
    body: str = ""
    head_ref: str = ""


@dataclasses.dataclass
class Action:
    issue: int
    remove: str
    add: str      # "" when nothing is added
    comment: str


# ---- planning (pure) -------------------------------------------------------------------------------------------

def parse_time(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def links(pull, number, repo):
    """True when the pull request names issue `number` in its title, body or head branch."""
    own = re.escape(repo or "-")
    text = f"{pull.title}\n{pull.body}"
    ref = rf"(?:(?<![\w/#])|(?<={own}))#{number}(?!\d)"
    url = rf"github\.com/{own}/issues/{number}(?!\d)"
    branch = rf"(?:^|/){number}(?:-|$)"
    return bool(re.search(ref, text) or re.search(url, text, re.I) or re.search(branch, pull.head_ref))


def comment_text(hours, labels):
    if BLOCKED in labels:
        then = f" and left `{BUILDABLE}` off because it is `{BLOCKED}`"
    elif BUILDABLE in labels:
        then = f"; it keeps `{BUILDABLE}`"
    else:
        then = f" and added `{BUILDABLE}`"
    return (f"{MARKER}\nNo open pull request links this issue and its labels have not changed for {hours} hours, "
            f"so the stale-in-progress job removed `{IN_PROGRESS}`{then}. To pick it up again, add `{IN_PROGRESS}` "
            "and open a pull request that says `Closes #<this issue>`.")


def plan_one(issue, pulls, last_change, now, hours, repo):
    """The Action for one issue, or None when it is left alone."""
    if IN_PROGRESS not in issue.labels or issue.labels & SKIP:
        return None
    if any(links(p, issue.number, repo) for p in pulls):
        return None
    since = last_change or issue.created_at
    if since and now - parse_time(since) < datetime.timedelta(hours=hours):
        return None
    add = "" if issue.labels & {BLOCKED, BUILDABLE} else BUILDABLE
    return Action(issue.number, IN_PROGRESS, add, comment_text(hours, issue.labels))


def plan(issues, pulls, last_change, now, hours=HOURS, repo=""):
    """Actions for every stale issue; last_change maps an issue number to its newest label event time."""
    out = []
    for issue in sorted(issues, key=lambda i: i.number):
        action = plan_one(issue, pulls, last_change.get(issue.number, ""), now, hours, repo)
        if action:
            out.append(action)
    return out


# ---- GitHub ----------------------------------------------------------------------------------------------------

class Runner:
    """Runs a command; returns (returncode, stdout, stderr). Tests pass their own callable instead."""

    def __call__(self, args):
        p = subprocess.run(args, capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr


class GitHub:
    def __init__(self, repo, run=None):
        self.repo, self.run = repo, run or Runner()

    def _api(self, path, method="GET", fields=(), paginate=False, jq=None):
        args = ["gh", "api", "-X", method, path]
        for k, v in fields:
            args += ["-f", f"{k}={v}"]
        if paginate:
            args.append("--paginate")
        if jq:
            args += ["--jq", jq]
        rc, out, err = self.run(args)
        if rc != 0:
            raise Error(f"gh api {method} {path}: {err.strip()[:500]}")
        return out

    def _lines(self, path, jq):
        out = self._api(path, paginate=True, jq=jq)
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def in_progress_issues(self):
        jq = ".[] | select(.pull_request == null) | {number, created_at, labels: [.labels[].name]}"
        rows = self._lines(f"repos/{self.repo}/issues?state=open&labels={IN_PROGRESS}&per_page=100", jq)
        return [Issue(r["number"], set(r["labels"]), r["created_at"]) for r in rows]

    def open_pulls(self):
        jq = ".[] | {number, title, body, head: .head.ref}"
        rows = self._lines(f"repos/{self.repo}/pulls?state=open&per_page=100", jq)
        return [Pull(r["number"], r["title"] or "", r["body"] or "", r["head"] or "") for r in rows]

    def last_label_change(self, number):
        jq = '.[] | select(.event == "labeled" or .event == "unlabeled") | .created_at'
        out = self._api(f"repos/{self.repo}/issues/{number}/events?per_page=100", paginate=True, jq=jq)
        times = [t.strip() for t in out.splitlines() if t.strip()]
        return max(times, key=parse_time) if times else ""

    def apply(self, action):
        label = urllib.parse.quote(action.remove, safe="")
        self._api(f"repos/{self.repo}/issues/{action.issue}/labels/{label}", method="DELETE")
        if action.add:
            self._api(f"repos/{self.repo}/issues/{action.issue}/labels", method="POST",
                      fields=[("labels[]", action.add)])
        self._api(f"repos/{self.repo}/issues/{action.issue}/comments", method="POST",
                  fields=[("body", action.comment)])


def describe(action):
    added = f", add {action.add}" if action.add else ""
    return f"#{action.issue}: remove {action.remove}{added}, comment"


def run(gh, now, hours=HOURS, dry_run=True):
    """One pass; returns the report lines."""
    issues = [i for i in gh.in_progress_issues() if not i.labels & SKIP]
    if not issues:
        return ["no open issue is labelled in-progress (outside launch-blocker and needs-owner)"]
    pulls = gh.open_pulls()
    last = {i.number: gh.last_label_change(i.number) for i in issues}
    actions = plan(issues, pulls, last, now, hours, gh.repo)
    lines = [f"{len(issues)} in-progress issue(s) checked, {len(pulls)} open pull request(s), "
             f"{len(actions)} stale"]
    for a in actions:
        if not dry_run:
            gh.apply(a)
        lines.append(("would " if dry_run else "") + describe(a))
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="print what would change; write nothing")
    ap.add_argument("--hours", type=int, default=HOURS, help="hours without a label change (default 48)")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""), help="owner/name")
    a = ap.parse_args(argv)
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", a.repo or ""):
        raise SystemExit("--repo (or GITHUB_REPOSITORY) must be owner/name")
    if a.hours < 1:
        raise SystemExit("--hours must be at least 1")
    dry = a.dry_run or os.environ.get("DRY_RUN", "").lower() == "true"
    now = datetime.datetime.now(datetime.timezone.utc)
    print(("dry run: " if dry else "") + f"{a.repo}, stale after {a.hours} h")
    print("\n".join(run(GitHub(a.repo), now, a.hours, dry)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

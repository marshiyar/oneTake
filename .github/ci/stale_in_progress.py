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
issue's URL, closing keyword or not; owner and repository in any case) or its head branch names it (`<n>`,
`<n>-...`, `.../<n>` or `.../<n>-...`).

For each stale issue: `buildable` is added unless `blocked` is set (a `blocked` issue loses `buildable` instead), one
comment says why, and `in-progress` is removed last, so a failed call leaves the issue in progress to retry. Issues
labelled `launch-blocker` or `needs-owner` are never touched. With --dry-run (or DRY_RUN=true) it prints what it
would change and writes nothing.

Standard library only; it talks to the GitHub REST API at api.github.com (token in GH_TOKEN or GITHUB_TOKEN) through
`Transport`, which tests replace. No subprocess is run.
"""
import argparse
import dataclasses
import datetime
import http.client
import json
import os
import re
import ssl
import sys
import urllib.parse

IN_PROGRESS, BUILDABLE, BLOCKED = "in-progress", "buildable", "blocked"
SKIP = frozenset({"launch-blocker", "needs-owner"})
HOURS = 48
MARKER = "<!-- stale-in-progress -->"
API_HOST = "api.github.com"
REPO_RE = re.compile(r"[A-Za-z0-9-]+/(?!\.\.?$)[A-Za-z0-9_.-]+")   # owner/name; never . or ..


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
    remove: tuple    # labels removed, in-progress last
    add: str         # "" when nothing is added
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
    found = re.search(ref, text, re.IGNORECASE) or re.search(url, text, re.IGNORECASE)
    return bool(found or re.search(branch, pull.head_ref))


def comment_text(hours, labels):
    if BLOCKED in labels and BUILDABLE in labels:
        then = f" and `{BUILDABLE}`, because it is `{BLOCKED}`"
    elif BLOCKED in labels:
        then = f" and did not add `{BUILDABLE}`, because it is `{BLOCKED}`"
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
    return reset(issue, hours)


def reset(issue, hours):
    """The label changes for a stale issue: back to buildable, or out of the ready queue when it is blocked."""
    blocked = BLOCKED in issue.labels
    add = "" if blocked or BUILDABLE in issue.labels else BUILDABLE
    remove = (BUILDABLE, IN_PROGRESS) if blocked and BUILDABLE in issue.labels else (IN_PROGRESS,)
    return Action(issue.number, remove, add, comment_text(hours, issue.labels))


def plan(issues, pulls, last_change, now, hours=HOURS, repo=""):
    """Actions for every stale issue; last_change maps an issue number to its newest label event time."""
    out = []
    for issue in sorted(issues, key=lambda i: i.number):
        action = plan_one(issue, pulls, last_change.get(issue.number, ""), now, hours, repo)
        if action:
            out.append(action)
    return out


# ---- GitHub ----------------------------------------------------------------------------------------------------

class Transport:
    """One HTTPS request to api.github.com (through HTTPS_PROXY when it is set); returns (status, text, Link).
    Tests pass their own callable instead."""

    def __init__(self, token):
        self.token = token

    def _connect(self):
        ctx = ssl.create_default_context()
        proxy = urllib.parse.urlsplit(os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or "")
        if not proxy.hostname:
            return http.client.HTTPSConnection(API_HOST, 443, timeout=60, context=ctx)
        conn = http.client.HTTPSConnection(proxy.hostname, proxy.port or 80, timeout=60, context=ctx)
        conn.set_tunnel(API_HOST, 443)
        return conn

    def __call__(self, method, path, payload=None):
        headers = {"Accept": "application/vnd.github+json", "Authorization": f"Bearer {self.token}",
                   "User-Agent": "stale-in-progress", "X-GitHub-Api-Version": "2022-11-28"}
        body = None if payload is None else json.dumps(payload).encode()
        if body is not None:
            headers["Content-Type"] = "application/json"
        conn = self._connect()
        try:
            conn.request(method, path, body=body, headers=headers)
            r = conn.getresponse()
            return r.status, r.read().decode("utf-8", "replace"), r.getheader("Link") or ""
        finally:
            conn.close()


def next_page(link):
    """The path of the rel="next" page in a Link header, or "" (only api.github.com pages are followed)."""
    for part in link.split(","):
        m = re.fullmatch(r'\s*<([^>]+)>\s*;\s*rel="next"\s*', part)
        if m:
            u = urllib.parse.urlsplit(m.group(1))
            if u.scheme == "https" and u.hostname == API_HOST:
                return u.path + (f"?{u.query}" if u.query else "")
    return ""


class GitHub:
    def __init__(self, repo, send):
        if not REPO_RE.fullmatch(repo or ""):
            raise Error(f"not a repository name: {repo!r}")
        self.repo, self.send = repo, send

    def _call(self, method, path, payload=None):
        status, text, link = self.send(method, path, payload)
        if not 200 <= status < 300:
            raise Error(f"{method} {path}: HTTP {status}: {text.strip()[:500]}")
        return (json.loads(text) if text.strip() else None), link

    def _pages(self, path):
        rows = []
        while path:
            page, link = self._call("GET", path)
            rows += page or []
            path = next_page(link)
        return rows

    def in_progress_issues(self):
        rows = self._pages(f"/repos/{self.repo}/issues?state=open&labels={IN_PROGRESS}&per_page=100")
        return [Issue(r["number"], {lb["name"] for lb in r.get("labels", [])}, r["created_at"])
                for r in rows if "pull_request" not in r]

    def open_pulls(self):
        rows = self._pages(f"/repos/{self.repo}/pulls?state=open&per_page=100")
        return [Pull(r["number"], r.get("title") or "", r.get("body") or "", r["head"]["ref"] or "") for r in rows]

    def last_label_change(self, number):
        rows = self._pages(f"/repos/{self.repo}/issues/{int(number)}/events?per_page=100")
        times = [r["created_at"] for r in rows if r.get("event") in ("labeled", "unlabeled")]
        return max(times, key=parse_time) if times else ""

    def apply(self, action):
        """Add first, then comment, then remove (in-progress last): a failure part way leaves it in progress."""
        base = f"/repos/{self.repo}/issues/{int(action.issue)}"
        if action.add:
            self._call("POST", f"{base}/labels", {"labels": [action.add]})
        self._call("POST", f"{base}/comments", {"body": action.comment})
        for label in action.remove:
            self._call("DELETE", f"{base}/labels/{urllib.parse.quote(label, safe='')}")


def describe(action):
    added = f"add {action.add}, " if action.add else ""
    return f"#{action.issue}: {added}comment, remove {', '.join(action.remove)}"


def run(gh, now, hours=HOURS, dry_run=True):
    """One pass; returns the report lines."""
    issues = [i for i in gh.in_progress_issues() if not i.labels & SKIP]
    if not issues:
        return ["no open issue is labelled in-progress (outside launch-blocker and needs-owner)"]
    pulls = gh.open_pulls()
    last = {i.number: gh.last_label_change(i.number) for i in issues}
    actions = plan(issues, pulls, last, now, hours, gh.repo)
    summary = f"{len(issues)} in-progress issue(s) checked, {len(pulls)} open pull request(s), {len(actions)} stale"
    lines = [summary]
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
    if not REPO_RE.fullmatch(a.repo or ""):
        raise SystemExit("--repo (or GITHUB_REPOSITORY) must be owner/name")
    if a.hours < 1:
        raise SystemExit("--hours must be at least 1")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if not token:
        raise SystemExit("GH_TOKEN (or GITHUB_TOKEN) must hold a token")
    dry = a.dry_run or os.environ.get("DRY_RUN", "").lower() == "true"
    now = datetime.datetime.now(datetime.timezone.utc)
    print(("dry run: " if dry else "") + f"{a.repo}, stale after {a.hours} h")
    print("\n".join(run(GitHub(a.repo, Transport(token)), now, a.hours, dry)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

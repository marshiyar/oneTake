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
"""codacy_to_codex.py <event.json>: hand the important Codacy findings on a pull request to Codex.

Run by .github/workflows/codacy-to-codex.yml when `codacy-production[bot]` posts a review or a review comment. The
event only names the pull request: every run reads all of Codacy's top-level review comments on it, so a run that
the per-PR concurrency group dropped loses nothing. A finding is handed to Codex, as one pull request comment by the
review App, when all of these hold:
  - it is important: its severity badge is `:red_circle:` / HIGH RISK (or CRITICAL), or it is a Security finding;
    yellow, white, MEDIUM and LOW findings are left alone;
  - it is still on the diff (GitHub gives an outdated comment no line) and its path is a plain repository path;
  - its thread is not resolved and nobody but Codacy has replied in it (a reply means it was fixed or answered);
  - no App comment already carries its marker `<!-- codacy-to-codex:<id> -->` (one task per Codacy comment);
  - fewer than RATE_LIMIT tasks were posted on the pull request in the last hour (so a fix-review loop cannot run
    away); the rest wait for Codacy's next comment on the pull request.
The finding text is untrusted: it is reduced to plain text (no HTML, no `@` mentions, no backticks), capped at
MAX_TEXT characters and quoted. Codex answers with a diff, which .github/workflows/codex-apply.yml applies.

Exit 0 when the run did what it should (posting nothing is a normal outcome); 1 when GitHub could not be read or
written (nothing is posted on a failed read); 2 on bad arguments. Standard library only; GitHub is reached over HTTPS
at api.github.com only, through `Transport`, which tests replace.
"""
import datetime
import http.client
import json
import os
import re
import ssl
import sys

CODACY = "codacy-production[bot]"
RATE_LIMIT = 5            # Codex tasks per pull request per hour
WINDOW = datetime.timedelta(hours=1)
MAX_TEXT = 600            # characters of finding text quoted to Codex
MARKER = "<!-- codacy-to-codex:{} -->"
MARKER_RE = re.compile(r"<!-- codacy-to-codex:(\d+) -->")
BADGE = re.compile(r"\A\s*<sub>(.*?)</sub>", re.DOTALL)
HIGH = re.compile(r":red_circle:|\bHIGH RISK\b|\bCRITICAL\b", re.IGNORECASE)
SECURITY = re.compile(r"\bsecurity\b", re.IGNORECASE)
CATEGORY_LINE = re.compile(r"^\W*category\W*security\b", re.IGNORECASE | re.MULTILINE)
SAFE_PATH = re.compile(r"\A[A-Za-z0-9_][A-Za-z0-9_./+-]*\Z")
TASK = ("@codex Fix this Codacy finding on this PR: `{path}:{line}` —\n\n> {text}\n\n"
        "Change only what the fix needs, keep every test, follow the repo's AGENTS.md rules. End your reply with the "
        "complete change as one unified diff (git diff against the PR head) in a single diff fenced block.\n\n{marker}")


class Error(Exception):
    pass


# ---- decisions (pure) ---------------------------------------------------------------------------------------------

def pr_from_event(event, repo):
    """(number, None) when the event is Codacy's on an open pull request from this repository, else (None, why)."""
    pr = event.get("pull_request") or {}
    author = ((event.get("comment") or event.get("review") or {}).get("user") or {}).get("login")
    head_repo = ((pr.get("head") or {}).get("repo") or {}).get("full_name")
    if author != CODACY:
        return None, f"posted by {author}, not {CODACY}"
    if head_repo != repo:
        return None, f"the pull request comes from {head_repo}, not {repo}"
    if pr.get("state") != "open":
        return None, f"the pull request is {pr.get('state')}"
    return pr.get("number"), None


def is_important(body):
    """HIGH / CRITICAL severity, or a Security finding (whatever its severity)."""
    m = BADGE.match(body or "")
    badge = m.group(1) if m else ""
    if HIGH.search(badge):
        return True
    return bool(SECURITY.search(badge) or CATEGORY_LINE.search(body or ""))


def finding_text(body):
    """The finding as one line of plain text: badge, links section and HTML gone; no `@`, backticks or angle
    brackets left to mention anyone, open a code span or a tag; at most MAX_TEXT characters."""
    text = BADGE.sub("", body or "", count=1)
    text = re.split(r"^[ \t]*##[ \t]*$", text, maxsplit=1, flags=re.MULTILINE)[0]
    text = re.sub(r"<!--.*?(-->|\Z)", " ", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]*>", " ", text)
    text = re.sub(r"[@`<>]", "", text)
    text = " ".join(text.split())
    if len(text) > MAX_TEXT:
        text = text[:MAX_TEXT - 3].rstrip() + "..."
    return text


def task_body(comment):
    return TASK.format(path=comment["path"], line=comment["line"], text=finding_text(comment["body"]),
                       marker=MARKER.format(comment["id"]))


def finding_problem(comment):
    """Why the finding itself gets no task (not important, outdated, odd path, empty), or None."""
    if not is_important(comment.get("body")):
        return "not HIGH and not Security"
    line = comment.get("line")
    if not isinstance(line, int) or line < 1:
        return "outdated (no line on the current diff)"
    path = comment.get("path") or ""
    if not SAFE_PATH.match(path) or ".." in path.split("/"):
        return "path is not a plain repository path"
    if not finding_text(comment.get("body")):
        return "no finding text"
    return None


def skip_reason(comment, answered, resolved, done):
    """Why this Codacy comment gets no task, or None when it should get one."""
    for ids, why in ((resolved, "thread resolved"), (answered, "thread already has a reply"),
                     (done, "task already posted")):
        if comment["id"] in ids:
            return why
    return finding_problem(comment)


def recent_tasks(app_comments, now):
    """How many App task comments were posted in the last WINDOW."""
    count = 0
    for c in app_comments:
        when = datetime.datetime.fromisoformat(c["created_at"].replace("Z", "+00:00"))
        if MARKER_RE.search(c.get("body") or "") and now - when < WINDOW:
            count += 1
    return count


def login(c):
    return (c.get("user") or {}).get("login")


def codacy_threads(review_comments):
    """(Codacy's top-level comments oldest first, ids of the threads someone other than Codacy replied in)."""
    roots = sorted((c for c in review_comments if login(c) == CODACY and not c.get("in_reply_to_id")),
                   key=lambda c: c["id"])
    answered = {c["in_reply_to_id"] for c in review_comments if c.get("in_reply_to_id") and login(c) != CODACY}
    return roots, answered


def plan(review_comments, resolved, issue_comments, app_login, now):
    """([(codacy comment, task body)], [(id, reason)]): the tasks to post now, oldest finding first. Only the App's
    own issue comments count as tasks, so nobody else can suppress a finding by pasting its marker."""
    app_comments = [c for c in issue_comments if login(c) == app_login]
    codacy, answered = codacy_threads(review_comments)
    done = {int(i) for c in app_comments for i in MARKER_RE.findall(c.get("body") or "")}
    budget = RATE_LIMIT - recent_tasks(app_comments, now)
    post, skipped = [], []
    for c in codacy:
        why = skip_reason(c, answered, resolved, done)
        if why is None and budget <= 0:
            why = f"rate limit: {RATE_LIMIT} tasks in the last hour"
        if why:
            skipped.append((c["id"], why))
        else:
            post.append((c, task_body(c)))
            budget -= 1
    return post, skipped


# ---- GitHub -------------------------------------------------------------------------------------------------------

THREADS = """query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    reviewThreads(first: 100, after: $after) { pageInfo { hasNextPage endCursor }
      nodes { isResolved comments(first: 1) { nodes { databaseId } } } } } } }"""
HOST = "api.github.com"
NEXT = re.compile(r'<https://api\.github\.com(/[^>]*)>;\s*rel="next"')
MAX_PAGES = 30


class Transport:
    """One HTTPS request to the fixed host api.github.com; returns (status, Link header, decoded JSON body).
    Tests pass their own callable instead."""

    def __init__(self, token):
        self.token = token

    def __call__(self, method, path, body=None):
        # The certificate and host name are verified explicitly (ssl.create_default_context), not by relying on the
        # interpreter's default, which is what the Semgrep audit rule below warns about; the host is fixed.
        tls = ssl.create_default_context()
        conn = http.client.HTTPSConnection(HOST, timeout=30, context=tls)  # nosemgrep: python.lang.security.audit.httpsconnection-detected.httpsconnection-detected
        try:
            conn.request(method, path, body=None if body is None else json.dumps(body),
                         headers={"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                                  "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "codacy-to-codex"})
            resp = conn.getresponse()
            raw = resp.read()
            return resp.status, resp.getheader("Link") or "", json.loads(raw) if raw else None
        finally:
            conn.close()


class GitHub:
    def __init__(self, repo, app_login, transport):
        self.repo, self.app_login, self.http = repo, app_login, transport

    def _call(self, method, path, body=None):
        try:
            status, link, data = self.http(method, path, body)
        except (OSError, http.client.HTTPException, ValueError) as e:
            raise Error(f"{method} {path.split('?')[0]}: {e}") from e
        if not 200 <= status < 300:
            raise Error(f"{method} {path.split('?')[0]}: HTTP {status}")
        return link, data

    def _pages(self, path):
        rows = []
        for _ in range(MAX_PAGES):
            link, data = self._call("GET", path)
            rows += data or []
            m = NEXT.search(link)
            if not m:
                return rows
            path = m.group(1)
        raise Error(f"more than {MAX_PAGES} pages at {path.split('?')[0]}")

    def review_comments(self, n):
        return self._pages(f"/repos/{self.repo}/pulls/{n}/comments?per_page=100")

    def issue_comments(self, n):
        return self._pages(f"/repos/{self.repo}/issues/{n}/comments?per_page=100")

    def resolved_roots(self, n):
        owner, name = self.repo.split("/", 1)
        variables, roots = {"owner": owner, "name": name, "number": n, "after": None}, set()
        for _ in range(MAX_PAGES):
            _, data = self._call("POST", "/graphql", {"query": THREADS, "variables": variables})
            if not isinstance(data, dict) or data.get("errors") or not data.get("data"):
                raise Error(f"review threads: {str((data or {}).get('errors'))[:300]}")
            threads = data["data"]["repository"]["pullRequest"]["reviewThreads"]
            roots |= {t["comments"]["nodes"][0]["databaseId"] for t in threads["nodes"]
                      if t["isResolved"] and t["comments"]["nodes"]}
            if not threads["pageInfo"]["hasNextPage"]:
                return roots
            variables["after"] = threads["pageInfo"]["endCursor"]
        raise Error(f"more than {MAX_PAGES} pages of review threads")

    def comment(self, n, body):
        self._call("POST", f"/repos/{self.repo}/issues/{n}/comments", {"body": body})


def run(event, repo, gh, now=None):
    """Hand the pull request's important Codacy findings to Codex; returns the lines to log."""
    n, why = pr_from_event(event, repo)
    if n is None:
        return [f"nothing to do: {why}"]
    post, skipped = plan(gh.review_comments(n), gh.resolved_roots(n), gh.issue_comments(n), gh.app_login,
                         now or datetime.datetime.now(datetime.timezone.utc))
    log = [f"#{n}: Codacy comment {i} skipped: {reason}" for i, reason in skipped]
    for c, body in post:
        gh.comment(n, body)
        log.append(f"#{n}: Codex task posted for Codacy comment {c['id']} ({c['path']}:{c['line']})")
    return log


def main(argv):
    repo, app_login, token = (os.environ.get(k, "") for k in ("REPO", "APP_LOGIN", "GH_TOKEN"))
    if len(argv) != 2 or not re.fullmatch(r"[\w.-]+/[\w.-]+", repo) or not app_login or not token:
        print("usage: REPO=<owner/name> APP_LOGIN=<app>[bot] GH_TOKEN=<token> codacy_to_codex.py <event.json>",
              file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        event = json.load(f)
    try:
        for line in run(event, repo, GitHub(repo, app_login, Transport(token))):
            print(line)
    except Error as e:
        print(f"::error::{e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

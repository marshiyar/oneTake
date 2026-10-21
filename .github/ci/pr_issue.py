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
"""pr_issue.py: a pull request names the open issue it closes.

  python3 -I -B .github/ci/pr_issue.py <pull request number>

Run by .github/workflows/pr-issue.yml from the base commit; it never reads the pull request's code. It reads the pull
request, its changed files and the issues its body names through the REST API ($GITHUB_TOKEN, read-only;
$GITHUB_REPOSITORY names the repository; stdlib only).

The check passes when the body has a closing keyword with an issue number of this repository (`Closes #12`,
`fixes: #12`, `Resolves #12`; the keyword forms GitHub links, see
https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue,
read 2026-10-21) and every number so named is an open issue here, not a pull request. Exempt: the label `no-issue`,
Dependabot and the Codex reviewer, merge-train branches `train/<n>`, and documentation-only changes (the same filter
as the `changes` job of mpvfx-ci.yml: Markdown anywhere, mpvfx-swift/docs/, the licence files).

Prints a Markdown verdict; exit 0 pass or exempt, 1 the check fails, 2 bad arguments or the API could not be read.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API_HOST = "api.github.com"
EXEMPT_LABEL = "no-issue"
EXEMPT_AUTHORS = {"dependabot[bot]", "chatgpt-codex-connector[bot]"}
TRAIN_BRANCH = re.compile(r"train/\d+")
# Kept equal to the docs filter of the `changes` job in .github/workflows/mpvfx-ci.yml.
DOCS_FILE = re.compile(r"\.md$|^mpvfx-swift/docs/|^(LICENSE|LICENSE-MIT|LICENSE-APACHE|NOTICE)$")
DOCS_MAX_FILES = 3000
CLOSING = re.compile(r"(?<![\w/#-])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d+)\b", re.IGNORECASE)
MAX_REFERENCES = 20


class ApiError(Exception):
    pass


def https_opener():
    """An opener that speaks HTTPS only: any other scheme (file://, ftp://, http://) is a URLError; no redirects."""
    opener = urllib.request.OpenerDirector()
    for handler in (urllib.request.HTTPSHandler(), urllib.request.UnknownHandler(),
                    urllib.request.HTTPDefaultErrorHandler(), urllib.request.HTTPErrorProcessor()):
        opener.add_handler(handler)
    return opener


def api(repo, token, path, opener=None):
    """GET https://api.github.com/repos/<repo>/<path>: the JSON, None on 404, ApiError otherwise."""
    req = urllib.request.Request(f"https://{API_HOST}/repos/{repo}/{path}", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "mpvfx-pr-issue"})
    if req.type != "https" or req.host != API_HOST:
        raise ApiError(f"GET {path}: refusing {req.type}://{req.host}, only https://{API_HOST}")
    try:
        with (opener or https_opener()).open(req, timeout=60) as r:
            return json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise ApiError(f"GET {path}: HTTP {e.code}") from e
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise ApiError(f"GET {path}: {e}") from e


def changed_files(get, number):
    """Both sides of a rename, as the `changes` job counts them; None when the list cannot be complete."""
    names, page = [], 1
    while page <= 30:
        got = get(f"pulls/{number}/files?per_page=100&page={page}")
        if not isinstance(got, list):
            return None
        for f in got:
            names += [n for n in (f.get("filename"), f.get("previous_filename")) if n]
        if len(got) < 100:
            return names
        page += 1
    return None


def docs_only(files):
    return files is not None and 0 < len(files) < DOCS_MAX_FILES and all(DOCS_FILE.search(f) for f in files)


def referenced_issues(body):
    seen = []
    for m in CLOSING.finditer(body or ""):
        n = int(m.group(1))
        if n not in seen:
            seen.append(n)
    return seen


def field(obj, *keys):
    """obj[k1][k2]..., or "" where any level is missing or not an object."""
    for k in keys:
        obj = obj.get(k) if isinstance(obj, dict) else None
    return obj if isinstance(obj, str) else ""


def train_branch(pr):
    """The head branch when it is a merge-train branch of this repository (never a fork's), else ""."""
    head_repo, base_repo = field(pr, "head", "repo", "full_name"), field(pr, "base", "repo", "full_name")
    ref = field(pr, "head", "ref")
    return ref if head_repo and head_repo == base_repo and TRAIN_BRANCH.fullmatch(ref) else ""


def exemption(pr, files):
    """Why this pull request needs no issue, or None."""
    labels = {lab.get("name") for lab in pr.get("labels") or [] if isinstance(lab, dict)}
    author = field(pr, "user", "login")
    if EXEMPT_LABEL in labels:
        return f"labelled `{EXEMPT_LABEL}`"
    if author in EXEMPT_AUTHORS:
        return f"opened by `{author}`"
    if train_branch(pr):
        return f"merge-train branch `{train_branch(pr)}`"
    if docs_only(files):
        return f"documentation only ({len(files)} files)"
    return None


def issue_problem(n, issue):
    """What is wrong with `#n` as the issue a pull request closes, or None."""
    if not isinstance(issue, dict):
        return f"#{n} is not an issue in this repository"
    if "pull_request" in issue:
        return f"#{n} is a pull request, not an issue"
    if issue.get("state") != "open":
        return f"#{n} is {issue.get('state', 'not open')}, not an open issue"
    return None


def judge(pr, files, get_issue):
    """(passed, Markdown lines). get_issue(n) returns the issue's JSON, or None when there is none."""
    why = exemption(pr, files)
    if why:
        return True, [f"Exempt: {why}."]
    numbers = referenced_issues(pr.get("body"))
    if not numbers:
        return False, [("The body names no issue: add `Closes #<issue>` (or `Fixes`/`Resolves`), "
                        f"or label the pull request `{EXEMPT_LABEL}` when no issue applies.")]
    if len(numbers) > MAX_REFERENCES:
        return False, [f"The body names {len(numbers)} issues; at most {MAX_REFERENCES} are checked."]
    problems = [p for p in (issue_problem(n, get_issue(n)) for n in numbers) if p]
    if problems:
        return False, [f"- {p}" for p in problems]
    return True, ["Closes " + ", ".join(f"#{n}" for n in numbers) + ": open issues of this repository."]


def run(number, get):
    pr = get(f"pulls/{number}")
    if not isinstance(pr, dict):
        raise ApiError(f"pull request #{number} not found")
    return judge(pr, changed_files(get, number), lambda n: get(f"issues/{n}"))


def main(argv, env):
    repo, token = env.get("GITHUB_REPOSITORY", ""), env.get("GITHUB_TOKEN", "")
    if len(argv) != 1 or not argv[0].isdigit() or not re.fullmatch(r"[\w.-]+/[\w.-]+", repo) or not token:
        print("usage: pr_issue.py <pull request number>  (needs GITHUB_REPOSITORY and GITHUB_TOKEN)", file=sys.stderr)
        return 2
    repo = urllib.parse.quote(repo, safe="/")
    try:
        passed, lines = run(int(argv[0]), lambda path: api(repo, token, path))
    except ApiError as e:
        print(f"::error::pr-issue could not read the pull request: {e}")
        return 2
    print("### Pull request names its issue: " + ("pass" if passed else "FAIL") + "\n")
    print("\n".join(lines))
    if not passed:
        print("::error::" + " ".join(line.lstrip("- ") for line in lines))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], os.environ))

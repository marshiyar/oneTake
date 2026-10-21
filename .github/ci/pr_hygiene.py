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
"""pr_hygiene.py: an advisory report on a pull request's shape. It warns; it never fails.

  python3 -I -B .github/ci/pr_hygiene.py --repo OWNER/NAME --pr N     (GH_TOKEN with pull-requests and issues read)

Reads only the GitHub API (the pull request, its file list, the issues it closes), never the pull request's code, and
writes a job summary ($GITHUB_STEP_SUMMARY, else stdout) and one `::warning::` annotation per finding:

  size     more than 400 changed lines (additions + deletions), not counting tests, fixtures and generated files
  files    more than 15 changed files, not counting fixtures and generated files (tests count: they are reviewed)
  areas    changes in more than one owner area, an area being a top-level module under mpvfx-swift/Sources/
  bug-fix  a closed issue (`Closes #n`, `Fixes #n`, `Resolves #n` and their tenses) labelled `bug`, and no changed file
           under mpvfx-swift/Tests/ (mpvfx-swift/AGENTS.md: every bug fix lands with a test)

A slice that has to be bigger says why in its description; these are prompts for the reviewer, not gates.
Exit 0 always; an API failure becomes a warning of its own.
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

MAX_LINES = 400
MAX_FILES = 15
SOURCES = "mpvfx-swift/Sources/"
TESTS = "mpvfx-swift/Tests/"
BUG_LABEL = "bug"
# fnmatch globs (`*` also matches `/`).
TEST_GLOBS = ["mpvfx-swift/Tests/*", ".github/ci/test_*.py"]
FIXTURE_GLOBS = ["*/Fixtures/*", "*/fixtures/*", "*/EngineFixtures/*"]
GENERATED_GLOBS = ["*/Generated/*", "*.generated.*", "*/Package.resolved", "Package.resolved",
                   ".github/sentinel-baseline/*", "*-baseline.json"]
CLOSES = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s+(?:([\w.-]+/[\w.-]+))?#(\d+)\b", re.IGNORECASE)


def matches(path, globs):
    return any(fnmatch.fnmatchcase(path, g) for g in globs)


def area_of(path):
    if path.startswith(SOURCES):
        rest = path[len(SOURCES):]
        if "/" in rest:
            return rest.split("/", 1)[0]
    return None


def closed_issues(body, repo):
    """Issue numbers the description closes in this repository, in order, without repeats."""
    out = []
    for m in CLOSES.finditer(body or ""):
        other, n = m.group(1), int(m.group(2))
        if other and other.lower() != repo.lower():
            continue
        if n not in out:
            out.append(n)
    return out


def _file_facts(f):
    """(name, every path it had, changed lines) of one entry of the API's file list."""
    name = f.get("filename", "")
    paths = [name] + ([f["previous_filename"]] if f.get("previous_filename") else [])
    return name, paths, int(f.get("additions", 0)) + int(f.get("deletions", 0))


def tally(files):
    """(changed lines, counted files, {owner area: files}, touches tests) over the API's file list."""
    lines = counted_files = 0
    areas = {}
    touches_tests = False
    for f in files:
        name, paths, changed = _file_facts(f)
        touches_tests = touches_tests or any(p.startswith(TESTS) for p in paths)
        if not (matches(name, FIXTURE_GLOBS) or matches(name, GENERATED_GLOBS)):
            counted_files += 1
            lines += 0 if matches(name, TEST_GLOBS) else changed
        for a in filter(None, map(area_of, paths)):
            areas[a] = areas.get(a, 0) + 1
    return lines, counted_files, areas, touches_tests


def limit_warnings(lines, counted_files, areas):
    warnings = []
    if lines > MAX_LINES:
        warnings.append(f"{lines} changed lines outside tests, fixtures and generated files (slice limit {MAX_LINES}): "
                        "split it, or say in the description why it cannot be")
    if counted_files > MAX_FILES:
        warnings.append(f"{counted_files} changed files (slice limit {MAX_FILES}): split it, or say why it cannot be")
    if len(areas) > 1:
        listed = ", ".join(f"{a} ({n})" for a, n in sorted(areas.items()))
        warnings.append(f"changes {len(areas)} owner areas ({listed}); a slice stays in one module unless the "
                        "description says why")
    return warnings


def bug_issues(issues, labels_of):
    """The closed issues labelled as bugs (labels_of(n) is None for a pull request or a missing issue)."""
    return [n for n in issues if BUG_LABEL in (labels_of(n) or [])]


def summary_lines(rows, issues, bugs, touches_tests, warnings):
    closes = ", ".join(f"#{n}" for n in issues) or "no issue"
    labelled = f"; labelled `{BUG_LABEL}`: {', '.join(f'#{n}' for n in bugs)}" if bugs else ""
    summary = ["## Pull request hygiene (advisory)", "", "| Measure | This PR | Limit |", "|---|---:|---:|"]
    summary += [f"| {what} | {value} | {limit} |" for what, value, limit in rows]
    summary += ["", f"Closes: {closes}{labelled}. Tests changed: {'yes' if touches_tests else 'no'}.", ""]
    return summary + ([f"- {w}" for w in warnings] or ["Within the slice limits."])


def assess(files, body, repo, labels_of):
    """files: the API's file list (filename, additions, deletions, previous_filename). labels_of(n): the label names of
    issue n, or None when n is not an issue of this repository. Returns (warnings, summary lines)."""
    lines, counted_files, areas, touches_tests = tally(files)
    rows = [("Changed lines (no tests, fixtures, generated)", lines, MAX_LINES),
            ("Changed files (no fixtures, generated)", counted_files, MAX_FILES),
            ("Owner areas under mpvfx-swift/Sources", len(areas), 1)]
    warnings = limit_warnings(lines, counted_files, areas)
    issues = closed_issues(body, repo)
    bugs = bug_issues(issues, labels_of)
    if bugs and not touches_tests:
        refs = ", ".join(f"#{n}" for n in bugs)
        warnings.append(f"closes bug {refs} but changes no file under {TESTS}: every bug fix lands with a test that "
                        "fails before the fix (mpvfx-swift/AGENTS.md)")
    return warnings, summary_lines(rows, issues, bugs, touches_tests, warnings)


def gh_json_lines(path, jq):
    out = subprocess.run(["gh", "api", "--paginate", path, "--jq", jq], capture_output=True, text=True, check=True)
    return [json.loads(x) for x in out.stdout.splitlines() if x.strip()]


def fetch(repo, pr):
    files = gh_json_lines(f"repos/{repo}/pulls/{pr}/files",
                          ".[] | {filename, additions, deletions, previous_filename}")
    body = gh_json_lines(f"repos/{repo}/pulls/{pr}", "{body}")[0].get("body") or ""

    def labels_of(n):
        issue = gh_json_lines(f"repos/{repo}/issues/{n}", "{labels: [.labels[].name], pr: (.pull_request != null)}")[0]
        return None if issue.get("pr") else issue.get("labels", [])

    return files, body, labels_of


def emit(warnings, summary):
    text = "\n".join(summary) + "\n"
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)
    print(text)
    for w in warnings:
        print(f"::warning title=PR hygiene::{w}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--pr", required=True, type=int)
    a = ap.parse_args(argv)
    try:
        files, body, labels_of = fetch(a.repo, a.pr)
        warnings, summary = assess(files, body, a.repo, labels_of)
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError, IndexError) as e:
        detail = getattr(e, "stderr", "") or str(e)
        warnings, summary = [f"could not read the pull request from the API: {detail.strip()[:300]}"], \
            ["## Pull request hygiene (advisory)", "", "Not assessed: the API could not be read."]
    emit(warnings, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())

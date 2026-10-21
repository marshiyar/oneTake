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
"""doc_refs.py [--offline] [--repo OWNER/NAME] [FILE.md]...: what the documentation points at exists.

Reads each Markdown file (default: every tracked *.md outside the test fixtures) and checks three kinds of reference:
  paths    an inline code span that names a repository path (`Sources/MpvfxColor/ColorRenderer.swift:106`,
           `docs/PACKAGING.md`, `packaging/`) resolves from the repository root, from mpvfx-swift/ or from the file's
           own folder; a `*` in it must match at least one path. A bare source file name in a code span
           (`LinuxShell.swift`) must be the name of some tracked file. A `:line` suffix past the end of the file is
           reported as a warning only: line numbers drift with every edit and are not worth a red check.
  links    a relative Markdown link `[text](path#anchor)` resolves to a file or folder (external links are not fetched).
  issues   every `#123`, `issues/123` or `pull/123` reference to this repository is an existing issue or pull request
           (one paginated `gh api` call; --offline skips it). A line holding a hex colour (`#306230`) is a palette
           and its bare `#n` are not read as issues.
Fenced code blocks are skipped: they hold commands and output, not references.
Prints one line per finding; exits 1 when a path, link or issue reference is broken, 0 otherwise, 2 on bad input.
"""
import argparse
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = "mpvfx-swift"
# First path segments that name repository content (both from the root and from mpvfx-swift/).
ROOTS = {"Sources", "Tests", "scripts", "packaging", "docs", "tools", ".github", APP, "Package.swift", "binaries.lock"}
# Bare names checked against the tracked files. Not C headers: the docs name the engine headers (`mpvfx_media.h`),
# which come from binaries.lock and are never tracked here.
SOURCE_EXT = (".swift", ".metal", ".comp", ".py", ".sh", ".ps1")
SKIP_DIRS = ("mpvfx-swift/Tests/EngineFixtures/",)
CODE_SPAN = re.compile(r"`([^`\n]+)`")
LINK = re.compile(r"\[[^\]\n]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
LINE_SUFFIX = re.compile(r"^(.*?):(\d+)(?:-(\d+))?$")
LINK_DEF = re.compile(r"^ {0,3}\[[^\]\n]+\]:\s*<?([^\s>]+)>?")   # a reference-style link definition: [docs]: docs/X.md
REL_ISSUE = re.compile(r"(?<![\w./-])(?:issues|pull)/(\d+)\b")   # issues/123 or pull/123, without the github.com prefix
ISSUE_URL = re.compile(r"github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/(\d+)")
BARE_ISSUE = re.compile(r"(?<![\w/&#\]])#(\d{1,5})\b")
# A line with a six-digit hex colour (`#306230`) is a palette, not a list of issues: its bare #n are not checked.
HEX_COLOUR = re.compile(r"#[0-9a-fA-F]{6}\b")


def tracked_files():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p for p in out.decode().split("\0") if p]


def strip_fences(text):
    """The text with fenced code blocks blanked, line numbers kept."""
    lines, fence = text.split("\n"), None
    for i, line in enumerate(lines):
        m = re.match(r"^\s*(`{3,}|~{3,})", line)
        if fence is None and m:
            fence, lines[i] = m.group(1)[0] * len(m.group(1)), ""
        elif fence is not None:
            if line.strip().startswith(fence):
                fence = None
            lines[i] = ""
    return lines


def candidates(md_dir, rel):
    rel = rel.removeprefix("./")
    return [os.path.normpath(os.path.join(ROOT, base, rel)) for base in ("", APP, md_dir)]


def resolves(md_dir, rel):
    for c in candidates(md_dir, rel):
        if any(ch in rel for ch in "*?["):
            if glob.glob(c, recursive=True):
                return c
        elif os.path.exists(c):
            return c
    return None


def path_token(token):
    """(path, first line) when the code span names a repository path, else None."""
    token = token.strip().rstrip(".,;")
    if " " in token or "://" in token or token.startswith(("-", "$", "~", "/")):
        return None
    line = None
    m = LINE_SUFFIX.match(token)
    if m and m.group(1):
        token, line = m.group(1), int(m.group(3) or m.group(2))
    first = token.split("/", 1)[0]
    if first in ROOTS and ("/" in token or first in ("Package.swift", "binaries.lock")):
        return token, line
    return None


def check_code_path(span, got, md_dir, where, findings, warnings, seen):
    rel, last = got
    seen["paths"] += 1
    hit = resolves(md_dir, rel)
    if not hit:
        findings.append(f"{where}: path `{rel}` does not exist (from the root, {APP}/ or {md_dir or '.'}/)")
        return
    if not (last and os.path.isfile(hit)):
        return
    with open(hit, "rb") as fh:
        count = fh.read().count(b"\n")
    if last > count:
        warnings.append(f"{where}: `{span}` points past the end of {os.path.relpath(hit, ROOT)} ({count} lines)")


def check_code_spans(line, md_dir, where, basenames, findings, warnings, seen):
    source_name = r"[\w.+-]+(" + "|".join(re.escape(e) for e in SOURCE_EXT) + r")"
    for span in CODE_SPAN.findall(line):
        got = path_token(span)
        if got:
            check_code_path(span, got, md_dir, where, findings, warnings, seen)
        elif re.fullmatch(source_name, span.strip()):
            seen["names"] += 1
            if span.strip() not in basenames:
                findings.append(f"{where}: file name `{span.strip()}` is not the name of any tracked file")


def check_link(target, md_dir, where, findings, issues, seen):
    rel_issue = re.search(r"(?:^|/)(?:issues|pull)/(\d+)$", target.split("#", 1)[0])
    has_scheme = re.match(r"^[a-z][a-z0-9+.-]*:", target)
    if rel_issue and not has_scheme:
        issues.append((None, int(rel_issue.group(1)), where))
        return
    if has_scheme or target.startswith("#"):
        match = ISSUE_URL.search(target)
        if match:
            issues.append((match.group(1), int(match.group(2)), where))
        return
    rel = target.split("#", 1)[0]
    seen["links"] += 1 if rel else 0
    if rel and not os.path.exists(os.path.normpath(os.path.join(ROOT, md_dir, rel))):
        findings.append(f"{where}: link target `{target}` does not exist")


def check_links(line, md_dir, where, findings, issues, seen):
    for target in LINK.findall(line) + LINK_DEF.findall(line):
        check_link(target, md_dir, where, findings, issues, seen)


def collect_issue_references(line, where, issues):
    bare = CODE_SPAN.sub("", LINK.sub("", line))
    if not HEX_COLOUR.search(bare):
        for num in BARE_ISSUE.findall(bare):
            issues.append((None, int(num), where))
    prose = CODE_SPAN.sub("", LINK.sub("", line)) if not LINK_DEF.match(line) else ""
    for url in ISSUE_URL.finditer(prose):
        issues.append((url.group(1), int(url.group(2)), where))
    for num in REL_ISSUE.findall(ISSUE_URL.sub("", prose)):
        issues.append((None, int(num), where))


def check_file(md, basenames, findings, warnings, issues, seen):
    md_dir = os.path.dirname(md)
    with open(os.path.join(ROOT, md), encoding="utf-8") as source:
        lines = strip_fences(source.read())
    for number, line in enumerate(lines, 1):
        where = f"{md}:{number}"
        check_code_spans(line, md_dir, where, basenames, findings, warnings, seen)
        check_links(line, md_dir, where, findings, issues, seen)
        collect_issue_references(line, where, issues)


def known_numbers(repo):
    """Every issue and pull request number of the repository (the issues endpoint lists both)."""
    out = subprocess.run(["gh", "api", "--paginate", f"repos/{repo}/issues?state=all&per_page=100", "--jq", ".[].number"],
                         capture_output=True, text=True, check=False)
    if out.returncode != 0:
        sys.exit(f"doc_refs: could not list the issues of {repo}: {out.stderr.strip()} (use --offline to skip)")
    return {int(x) for x in out.stdout.split()}


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("files", nargs="*", help="Markdown files relative to the repository root (default: every tracked *.md)")
    ap.add_argument("--offline", action="store_true", help="do not check issue and pull request numbers")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "marshiyar/oneTake"))
    return ap.parse_args()


def discover_files(args, tracked):
    return args.files or [p for p in tracked if p.endswith(".md") and not p.startswith(SKIP_DIRS)]


def check_files(files, basenames):
    findings, warnings, issues = [], [], []
    seen = {"paths": 0, "names": 0, "links": 0}
    for md in files:
        if not os.path.isfile(os.path.join(ROOT, md)):
            print(f"doc_refs: no such file {md}", file=sys.stderr)
            return None
        check_file(md, basenames, findings, warnings, issues, seen)
    return findings, warnings, issues, seen


def check_issues(args, issues, findings):
    own = [(n, where) for repo, n, where in issues if repo is None or repo.lower() == args.repo.lower()]
    if own and not args.offline:
        known = known_numbers(args.repo)
        findings += [f"{where}: #{n} is not an issue or pull request of {args.repo}" for n, where in own if n not in known]
    return own


def report(args, files, findings, warnings, seen, issue_count):
    for warning in warnings:
        print(f"warning: {warning}")
    for finding in findings:
        print(f"broken: {finding}")
    checked = "" if args.offline else f", {issue_count} issue references"
    print(f"doc_refs: {len(files)} files, {seen['paths']} paths, {seen['names']} file names, {seen['links']} links{checked}: "
          f"{len(findings)} broken, {len(warnings)} warnings")
    return 1 if findings else 0


def main():
    args = parse_args()
    tracked = tracked_files()
    basenames = {os.path.basename(p) for p in tracked}
    files = discover_files(args, tracked)
    result = check_files(files, basenames)
    if result is None:
        return 2
    findings, warnings, issues, seen = result
    own = check_issues(args, issues, findings)
    return report(args, files, findings, warnings, seen, len(own))


if __name__ == "__main__":
    sys.exit(main())

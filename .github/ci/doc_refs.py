#!/usr/bin/env python3
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
import argparse, glob, os, re, subprocess, sys

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
    rel = rel[2:] if rel.startswith("./") else rel
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


def check_file(md, basenames, findings, warnings, issues, seen):
    md_dir = os.path.dirname(md)
    with open(os.path.join(ROOT, md), encoding="utf-8") as f:
        lines = strip_fences(f.read())
    for n, line in enumerate(lines, 1):
        where = f"{md}:{n}"
        for span in CODE_SPAN.findall(line):
            got = path_token(span)
            if got:
                rel, last = got
                seen["paths"] += 1
                hit = resolves(md_dir, rel)
                if not hit:
                    findings.append(f"{where}: path `{rel}` does not exist (from the root, {APP}/ or {md_dir or '.'}/)")
                elif last and os.path.isfile(hit):
                    with open(hit, "rb") as fh:
                        count = fh.read().count(b"\n")
                    if last > count:
                        warnings.append(f"{where}: `{span}` points past the end of {os.path.relpath(hit, ROOT)} ({count} lines)")
            elif re.fullmatch(r"[\w.+-]+(" + "|".join(re.escape(e) for e in SOURCE_EXT) + r")", span.strip()):
                seen["names"] += 1
                if span.strip() not in basenames:
                    findings.append(f"{where}: file name `{span.strip()}` is not the name of any tracked file")
        for target in LINK.findall(line):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                m = ISSUE_URL.search(target)
                if m:
                    issues.append((m.group(1), int(m.group(2)), where))
                continue
            rel = target.split("#", 1)[0]
            seen["links"] += 1 if rel else 0
            if rel and not os.path.exists(os.path.normpath(os.path.join(ROOT, md_dir, rel))):
                findings.append(f"{where}: link target `{target}` does not exist")
        bare = CODE_SPAN.sub("", LINK.sub("", line))   # a link carries its number in its URL, read below
        if not HEX_COLOUR.search(bare):
            for num in BARE_ISSUE.findall(bare):
                issues.append((None, int(num), where))
        for url in ISSUE_URL.finditer(CODE_SPAN.sub("", LINK.sub("", line))):
            issues.append((url.group(1), int(url.group(2)), where))


def known_numbers(repo):
    """Every issue and pull request number of the repository (the issues endpoint lists both)."""
    out = subprocess.run(["gh", "api", "--paginate", f"repos/{repo}/issues?state=all&per_page=100", "--jq", ".[].number"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"doc_refs: could not list the issues of {repo}: {out.stderr.strip()} (use --offline to skip)")
    return {int(x) for x in out.stdout.split()}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("files", nargs="*", help="Markdown files relative to the repository root (default: every tracked *.md)")
    ap.add_argument("--offline", action="store_true", help="do not check issue and pull request numbers")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "marshiyar/oneTake"))
    args = ap.parse_args()
    tracked = tracked_files()
    basenames = {os.path.basename(p) for p in tracked}
    files = args.files or [p for p in tracked if p.endswith(".md") and not p.startswith(SKIP_DIRS)]
    findings, warnings, issues, seen = [], [], [], {"paths": 0, "names": 0, "links": 0}
    for md in files:
        if not os.path.isfile(os.path.join(ROOT, md)):
            print(f"doc_refs: no such file {md}", file=sys.stderr)
            return 2
        check_file(md, basenames, findings, warnings, issues, seen)
    own = [(n, where) for repo, n, where in issues if repo is None or repo.lower() == args.repo.lower()]
    if own and not args.offline:
        known = known_numbers(args.repo)
        findings += [f"{where}: #{n} is not an issue or pull request of {args.repo}" for n, where in own if n not in known]
    for w in warnings:
        print(f"warning: {w}")
    for f in findings:
        print(f"broken: {f}")
    checked = "" if args.offline else f", {len(own)} issue references"
    print(f"doc_refs: {len(files)} files, {seen['paths']} paths, {seen['names']} file names, {seen['links']} links{checked}: "
          f"{len(findings)} broken, {len(warnings)} warnings")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

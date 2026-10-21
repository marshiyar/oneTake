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
"""crash_constructs.py: the constructs that crash the app instead of returning an error, held to a ratchet.

  python3 -I -B .github/ci/crash_constructs.py [--base REV]   check the tree against the baseline (exit 1 on a rise)
  python3 -I -B .github/ci/crash_constructs.py --update       lower the baseline to the current counts (never raises)
  python3 -I -B .github/ci/crash_constructs.py --list [PATH]  print every occurrence, file:line kind
  python3 -I -B .github/ci/crash_constructs.py --init         write the first baseline (refused when one exists)

The rule (mpvfx-swift/AGENTS.md, "Never lose the user's edit"): no `!` force unwrap, `try!` or `as!` on input-derived
values in Sources/. Whether a value is input-derived needs a reviewer, so this check does not judge it: it counts every
occurrence per Swift file under mpvfx-swift/Sources/ and per kind, and fails when a file has more of a kind than
.github/ci/crash-constructs-baseline.json records (a file missing from the baseline records zero). Counts only go down:
--update writes min(baseline, current) and refuses to run while any count is above its baseline. A file that is renamed
or split moves its entry in the baseline by hand in the same pull request, where review sees it.

Kinds:
  force-unwrap   postfix `!` on an expression (`x!`, `f()!`, `a[i]!`)
  try!           `try!`
  as!            `as!`
  fatalError     a call of `fatalError(` (also `Swift.fatalError(`)
  precondition   a call of `precondition(` or `preconditionFailure(`
Not counted: `!=` and `!==`, prefix `!` (`!flag`), implicitly unwrapped optional types (`var v: View!`, `-> T!`,
`: [T]!`, `: (() -> Void)!`, `: G<T>!`), and anything inside a comment (line, nested block) or a string literal
(plain, multi-line, raw `#"..."#`); code inside a string interpolation `\\( )` is scanned as code.

With --base REV (CI passes the parent commit), the working baseline is also compared with the baseline at REV, allowing
equal-or-lower entries to follow source-file renames. If REV has no baseline, that comparison is skipped. Each source
file that rose prints the occurrences that REV does not have (matched by kind and line text); without it, or when REV
cannot be read, every occurrence of that kind in the file. Exit 0 within the baseline, 1 on a rise, 2 bad input or a
refused --update/--init.
"""
import argparse, bisect, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
BASELINE_REL = ".github/ci/crash-constructs-baseline.json"
SOURCES = "mpvfx-swift/Sources/"
KINDS = ("force-unwrap", "try!", "as!", "fatalError", "precondition")
CALLS = {"fatalError": "fatalError", "precondition": "precondition", "preconditionFailure": "precondition"}
IDENT_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$")  # $0 too
# Keywords that can sit right before a prefix `!` with no space (`return!x` is legal Swift); `self` stays out, since
# `self!` unwraps a weak capture.
KEYWORDS = frozenset("if guard while return in case else where throw repeat is await switch let var".split())


# ---- lexer: blank comments and string contents, keep code (interpolations included) ----

def mask(src):
    """Return src with every comment and every string literal's contents replaced by spaces (newlines kept), so each
    remaining character is code at its original offset. String delimiters stay, interpolated code stays."""
    out = list(src)
    n = len(src)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def code(i, in_interp):
        depth = 0
        while i < n:
            c = src[i]
            if c == "/" and i + 1 < n and src[i + 1] == "/":
                j = src.find("\n", i)
                j = n if j < 0 else j
                blank(i, j)
                i = j
                continue
            if c == "/" and i + 1 < n and src[i + 1] == "*":
                j, level = i + 2, 1
                while j < n and level:
                    if src.startswith("/*", j):
                        level, j = level + 1, j + 2
                    elif src.startswith("*/", j):
                        level, j = level - 1, j + 2
                    else:
                        j += 1
                blank(i, j)
                i = j
                continue
            if c == "#" or c == '"':
                h = 0
                while i + h < n and src[i + h] == "#":
                    h += 1
                if i + h < n and src[i + h] == '"':
                    i = string(i, h)
                    continue
                if h and i + h < n and src[i + h] == "/":   # extended regex literal #/.../#
                    i = regex(i, h)
                    continue
                i += max(h, 1)
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if in_interp and depth == 0:
                    return i + 1
                depth -= 1
            i += 1
        return i

    def string(i, h):
        i += h
        multi = src.startswith('"""', i)
        i += 3 if multi else 1
        close = ('"""' if multi else '"') + "#" * h
        esc = "\\" + "#" * h
        seg = i
        while i < n:
            if src.startswith(esc, i):
                k = i + len(esc)
                if k < n and src[k] == "(":
                    blank(seg, k + 1)
                    i = code(k + 1, True)
                    seg = i
                    continue
                i = k + 1
                continue
            if src.startswith(close, i):
                blank(seg, i)
                return i + len(close)
            if not multi and src[i] == "\n":   # unterminated: the compiler rejects it, stop at the line end
                blank(seg, i)
                return i
            i += 1
        blank(seg, n)
        return n

    def regex(i, h):
        """Blank an extended regex, retaining code inside raw-style interpolations."""
        i += h + 1
        close = "/" + "#" * h
        interp = "\\" + "#" * h + "("
        seg = i
        while i < n:
            if src.startswith(interp, i):
                blank(seg, i + len(interp))
                i = code(i + len(interp), True)
                seg = i
                continue
            if src.startswith(close, i):
                backslashes = 0
                k = i - 1
                while k >= 0 and src[k] == "\\":
                    backslashes += 1
                    k -= 1
                if backslashes % 2 == 0:
                    blank(seg, i)
                    return i + len(close)
            i += 1
        blank(seg, n)
        return n

    code(0, False)
    return "".join(out)


# ---- scanner ----

def _ident_before(text, end):
    """The identifier that ends at text[end-1] (backticks allowed), and where it starts."""
    j = end
    if j > 0 and text[j - 1] == "`":
        k = text.rfind("`", 0, j - 1)
        return (text[k + 1:j - 1], k) if k >= 0 else ("", j)
    while j > 0 and text[j - 1] in IDENT_CHARS:
        j -= 1
    return text[j:end], j


def _skip_space_back(text, i):
    while i > 0 and text[i - 1] in " \t\r\n":
        i -= 1
    return i


def _match_open(text, close_at, open_ch, close_ch):
    depth = 0
    for k in range(close_at, -1, -1):
        if text[k] == close_ch:
            depth += 1
        elif text[k] == open_ch:
            depth -= 1
            if depth == 0:
                return k
    return -1


def _in_type_position(text, start):
    """True when the type that starts at `start` follows a `:` or `->` (a declaration's type annotation)."""
    j = _skip_space_back(text, start)
    if j >= 2 and text[j - 2:j] == "->":
        return True
    if j >= 1 and text[j - 1] == ":":
        return True
    return False


def _is_iuo(text, bang):
    """True when the `!` at text[bang] closes an implicitly unwrapped optional type, not an expression."""
    prev = text[bang - 1]
    if prev == ">":          # G<T>!: a generic type
        return True
    if prev == "]" or prev == ")":
        open_ch = "[" if prev == "]" else "("
        k = _match_open(text, bang - 1, open_ch, prev)
        if k < 0:
            return False
        inner = text[k + 1:bang - 1].lstrip()
        if prev == "]" and not inner[:1].isupper():
            return False     # a subscript or an array literal
        return _in_type_position(text, k)
    name, start = _ident_before(text, bang)
    if not name or not name[0].isupper():
        return False         # types are capitalised; values are not (project style)
    # Walk a qualified name back (Outer.Inner) to its first segment.
    while start > 0 and text[start - 1] == ".":
        q, qs = _ident_before(text, start - 1)
        if not q:
            return False     # `.Case!` on an implicit member is an expression
        start = qs
    return _in_type_position(text, start)


def scan(src):
    """Every crash construct in a Swift source: a list of (kind, line number)."""
    text = mask(src)
    lines = [0]
    for m in re.finditer("\n", text):
        lines.append(m.end())
    found = []

    def at(off, kind):
        found.append((kind, bisect.bisect_right(lines, off)))

    for m in re.finditer("!", text):
        i = m.start()
        if i == 0:
            continue
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if nxt == "=":
            continue         # != and !==
        prev = text[i - 1]
        if prev in IDENT_CHARS or prev == "`":
            name, start = _ident_before(text, i)
            if name == "try":
                at(i, "try!")
                continue
            if name == "as":
                at(i, "as!")
                continue
            if (name in KEYWORDS and text[start:start + 1] != "`") or name[:1].isdigit():
                continue     # prefix `!` after a keyword; a number cannot be unwrapped
        elif prev not in ")]>":
            continue         # prefix `!`, or `!` after whitespace or an operator
        if _is_iuo(text, i):
            continue
        at(i, "force-unwrap")
    for m in re.finditer(r"(?<![A-Za-z0-9_$`])(fatalError|preconditionFailure|precondition)\s*\(", text):
        before = _skip_space_back(text, m.start())
        if before > 0 and text[before - 1] == ".":
            q, _ = _ident_before(text, before - 1)
            if q != "Swift":
                continue     # someone's own method of that name
        word, _ = _ident_before(text, _skip_space_back(text, before))
        if word == "func":
            continue
        at(m.start(), CALLS[m.group(1)])
    found.sort(key=lambda t: (t[1], KINDS.index(t[0])))
    return found


# ---- tree, baseline, report ----

def swift_files(root):
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", SOURCES], capture_output=True, check=True)
        files = [p for p in out.stdout.decode().split("\0") if p.endswith(".swift")]
    except (OSError, subprocess.CalledProcessError):
        files = []
        for d, _, names in os.walk(os.path.join(root, SOURCES)):
            files += [os.path.relpath(os.path.join(d, x), root).replace(os.sep, "/") for x in names if x.endswith(".swift")]
    return sorted(p for p in files if os.path.isfile(os.path.join(root, p)))


def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
        return f.read()


def tree_occurrences(root, files=None):
    """{path: [(kind, line), ...]} for every Swift file under Sources (only the files with any)."""
    occ = {}
    for rel in files if files is not None else swift_files(root):
        found = scan(read(root, rel))
        if found:
            occ[rel] = found
    return occ


def counts_of(occ):
    out = {}
    for rel, found in occ.items():
        c = {}
        for kind, _ in found:
            c[kind] = c.get(kind, 0) + 1
        out[rel] = {k: c[k] for k in KINDS if k in c}
    return out


def baseline_counts(data):
    """Validate a decoded baseline and return its counts."""
    if not isinstance(data, dict):
        raise ValueError("baseline is not an object")
    counts = data.get("counts")
    if not isinstance(counts, dict):
        raise ValueError("no \"counts\" object")
    for rel, c in counts.items():
        if not isinstance(c, dict) or any(k not in KINDS or not isinstance(v, int) or v < 0 for k, v in c.items()):
            raise ValueError(f"bad entry for {rel}: {c!r}")
    return counts


def load_baseline(path):
    with open(path, encoding="utf-8") as f:
        return baseline_counts(json.load(f))


def baseline_at_revision(root, rev):
    """Return the baseline committed at rev, or None when that revision has no baseline."""
    try:
        out = subprocess.run(["git", "-C", root, "show", f"{rev}:{BASELINE_REL}"], capture_output=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    return baseline_counts(json.loads(out.stdout))


def renamed_files(root, rev):
    """Map new paths to old paths for renames between rev and the working tree."""
    try:
        out = subprocess.run(["git", "-C", root, "diff", "--find-renames", "--name-status", rev, "--"],
                             capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return {}
    renames = {}
    for line in out.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) == 3 and fields[0].startswith("R"):
            renames[fields[2]] = fields[1]
    return renames


def baseline_increases(base, working, renames):
    """Return working baseline entries that exceed their same-path or renamed base entry."""
    moved_from = {old for new, old in renames.items() if new in working}
    violations = []
    for rel, counts in working.items():
        old_rel = renames.get(rel, rel)
        allowed = {} if rel in moved_from else base.get(old_rel, {})
        for kind, count in counts.items():
            old_count = allowed.get(kind, 0)
            if count > old_count:
                violations.append((rel, kind, old_count, count))
    return sorted(violations)


def write_baseline(path, counts):
    clean = {rel: {k: c[k] for k in KINDS if c.get(k)} for rel, c in sorted(counts.items())}
    clean = {rel: c for rel, c in clean.items() if c}
    data = {
        "about": "Crash constructs per Swift file under mpvfx-swift/Sources (.github/ci/crash_constructs.py). Counts "
                 "only go down: run `python3 -I -B .github/ci/crash_constructs.py --update` after removing some.",
        "totals": {k: sum(c.get(k, 0) for c in clean.values()) for k in KINDS},
        "counts": clean,
    }
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def compare(baseline, current):
    """(rises, falls): lists of (path, kind, baseline count, current count)."""
    rises, falls = [], []
    for rel in sorted(set(baseline) | set(current)):
        for kind in KINDS:
            b, c = baseline.get(rel, {}).get(kind, 0), current.get(rel, {}).get(kind, 0)
            if c > b:
                rises.append((rel, kind, b, c))
            elif c < b:
                falls.append((rel, kind, b, c))
    return rises, falls


def base_text(root, rev, rel):
    try:
        out = subprocess.run(["git", "-C", root, "show", f"{rev}:{rel}"], capture_output=True, check=True)
        return out.stdout.decode("utf-8", errors="replace")
    except (OSError, subprocess.CalledProcessError):
        return None


def new_occurrences(src, found, kind, old_src):
    """The occurrences of `kind` in src whose line text old_src does not have as often (None old_src: all of them)."""
    lines = src.split("\n")
    mine = [(line, lines[line - 1].strip()) for k, line in found if k == kind]
    if old_src is None:
        return [line for line, _ in mine]
    old_lines = old_src.split("\n")
    pool = {}
    for k, line in scan(old_src):
        if k == kind:
            t = old_lines[line - 1].strip()
            pool[t] = pool.get(t, 0) + 1
    new = []
    for line, t in mine:
        if pool.get(t, 0):
            pool[t] -= 1
        else:
            new.append(line)
    return new


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--baseline")
    ap.add_argument("--base", help="git revision the change is judged against, to name the new occurrences")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--update", action="store_true")
    mode.add_argument("--init", action="store_true")
    mode.add_argument("--list", nargs="*", metavar="PATH")
    a = ap.parse_args(argv)
    root = os.path.abspath(a.root)
    baseline_path = a.baseline or os.path.join(root, BASELINE_REL)

    if a.list is not None:
        files = a.list or swift_files(root)
        for rel, found in tree_occurrences(root, files).items():
            src_lines = read(root, rel).split("\n")
            for kind, line in found:
                print(f"{rel}:{line}: {kind}: {src_lines[line - 1].strip()[:160]}")
        return 0

    occ = tree_occurrences(root)
    current = counts_of(occ)
    totals = {k: sum(c.get(k, 0) for c in current.values()) for k in KINDS}
    total_line = ", ".join(f"{k} {totals[k]}" for k in KINDS) + f" (in {len(current)} files)"

    if a.init:
        if os.path.exists(baseline_path):
            print(f"refused: {baseline_path} exists; counts only go down (--update)", file=sys.stderr)
            return 2
        write_baseline(baseline_path, current)
        print(f"wrote {baseline_path}: {total_line}")
        return 0

    try:
        baseline = load_baseline(baseline_path)
        base_baseline = baseline_at_revision(root, a.base) if a.base and not a.update else None
    except (OSError, ValueError) as e:
        print(f"cannot read the baseline {baseline_path}: {e}", file=sys.stderr)
        return 2
    rises, falls = compare(baseline, current)
    baseline_rises = (baseline_increases(base_baseline, baseline, renamed_files(root, a.base))
                      if base_baseline is not None else [])

    if a.update:
        if rises:
            print("refused: --update only lowers counts, and these are above the baseline:", file=sys.stderr)
            for rel, kind, b, c in rises:
                print(f"  {rel}: {kind} {b} -> {c}", file=sys.stderr)
            return 2
        lowered = {rel: {k: min(v, current.get(rel, {}).get(k, 0)) for k, v in c.items()} for rel, c in baseline.items()}
        write_baseline(baseline_path, lowered)
        print(f"lowered {len(falls)} count(s); baseline now: {total_line}")
        return 0

    report = ["## Crash constructs (force unwrap, try!, as!, fatalError, precondition)", "",
              f"Current: {total_line}. Baseline: `{BASELINE_REL}`.", ""]
    notes = []
    if baseline_rises:
        report += ["**The committed baseline rose relative to the base revision:**", ""]
        for rel, kind, b, c in baseline_rises:
            report.append(f"- `{rel}`: {kind}; base {b}, new {c}")
        report += ["", "Baseline counts may only stay level or decrease (including across detected renames).", ""]
    if rises:
        report += ["**Above the baseline** (mpvfx-swift/AGENTS.md: return a typed error instead):", ""]
        for rel, kind, b, c in rises:
            src = read(root, rel)
            old = base_text(root, a.base, rel) if a.base else None
            where = "new" if old is not None else "every"
            report.append(f"- `{rel}`: {kind} {b} -> {c}; {where} occurrence(s):")
            src_lines = src.split("\n")
            for line in new_occurrences(src, occ.get(rel, []), kind, old):
                report.append(f"  - `{rel}:{line}`: `{src_lines[line - 1].strip()[:160]}`")
                notes.append(f"::error file={rel},line={line},title=crash construct ({kind})::{kind} above the "
                             f"baseline ({b} -> {c}); return a typed error instead")
        report += ["", "Remove the new construct (handle the nil, `try` with a typed error, `as?`). The script never "
                       "raises the baseline; a file that only moved carries its entry over by hand in the same pull "
                       "request, where review sees it."]
    elif falls:
        report.append(f"Within the baseline; {len(falls)} count(s) went down. Lock the gain in this pull request: "
                      "`python3 -I -B .github/ci/crash_constructs.py --update`.")
        notes.append(f"::notice title=crash constructs went down::{len(falls)} count(s) below the baseline; run "
                     ".github/ci/crash_constructs.py --update to lock them in")
    else:
        report.append("Within the baseline.")
    print("\n".join(report))
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for note in notes:
            print(note)
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as f:
                f.write("\n".join(report) + "\n")
    return 1 if rises or baseline_rises else 0

if __name__ == "__main__":
    sys.exit(main())

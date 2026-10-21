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
  force-unwrap   postfix `!` on an expression (`x!`, `f()!`, `a[i]!`, `xs.first { $0 > 1 }!`)
  try!           `try!`
  as!            `as!`
  fatalError     a call of `fatalError(` (also `Swift.fatalError(`)
  precondition   a call of `precondition(` or `preconditionFailure(`
Not counted: `!=` and `!==`, prefix `!` (`!flag`), implicitly unwrapped optional types in a declaration's type
annotation (`var v: View!`, `-> T!`, `let a: [any P]!`, `var h: (() -> Void)!`, `: G<T>!`, a parameter `x: T!`), and
anything inside a comment (line, nested block) or a string literal (plain, multi-line, raw `#"..."#`); code inside a
string interpolation `\\( )` is scanned as code.

With --base REV (CI passes the parent commit), the working baseline is also compared with the baseline at REV, allowing
equal-or-lower entries to follow source-file renames, and a split: the files git sees as renamed or copied from a file
the change removes may together hold up to that file's base count. If REV has no baseline, that comparison is skipped.
Each source file that rose prints the occurrences that REV does not have at that path (or the path it was renamed or
split from), matched by kind and line text; without it, or when REV cannot be read, every occurrence of that kind in
the file. Exit 0 within the baseline, 1 on a rise, 2 bad input or a refused --update/--init.
"""
import argparse
import bisect
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
BASELINE_REL = ".github/ci/crash-constructs-baseline.json"
SOURCES = "mpvfx-swift/Sources/"
KINDS = ("force-unwrap", "try!", "as!", "fatalError", "precondition")
CALLS = {"fatalError": "fatalError", "precondition": "precondition", "preconditionFailure": "precondition"}
IDENT_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$")  # $0 too
# Keywords that can sit right before a prefix `!` with no space (`return!x` is legal Swift); `self` stays out, since
# `self!` unwraps a weak capture.
KEYWORDS = frozenset(["if", "guard", "while", "return", "in", "case", "else", "where", "throw", "repeat", "is", "await",
                      "switch", "let", "var"])
# Characters that can end an expression right before a postfix `!` (an identifier character aside).
EXPR_ENDS = frozenset(")]>}")


# ---- lexer: blank comments and string contents, keep code (interpolations included) ----

class _Masker:
    """One pass over a Swift source that blanks comments and literal contents in a copy of it."""

    def __init__(self, src):
        self.src = src
        self.n = len(src)
        self.out = list(src)
        self.handlers = {"/": self._slash, "#": self._literal, '"': self._literal}

    def blank(self, a, b):
        for k in range(a, b):
            if self.out[k] != "\n":
                self.out[k] = " "

    def code(self, i, in_interp):
        """Scan code from i; inside an interpolation, return just past its closing `)`."""
        depth = 0
        while i < self.n:
            c = self.src[i]
            handler = self.handlers.get(c)
            j = handler(i) if handler else None
            if j is not None:
                i = j
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if in_interp and depth == 0:
                    return i + 1
                depth -= 1
            i += 1
        return i

    def _slash(self, i):
        nxt = self.src[i + 1:i + 2]
        if nxt == "/":
            j = self.src.find("\n", i)
            j = self.n if j < 0 else j
            self.blank(i, j)
            return j
        if nxt == "*":
            return self._block_comment(i)
        return None

    def _block_comment(self, i):
        j, level = i + 2, 1
        while j < self.n and level:
            if self.src.startswith("/*", j):
                level, j = level + 1, j + 2
            elif self.src.startswith("*/", j):
                level, j = level - 1, j + 2
            else:
                j += 1
        self.blank(i, j)
        return j

    def _literal(self, i):
        """A `"` or `#` opens a string, an extended regex `#/.../#`, or is a lone `#` (`#if`, `#selector`)."""
        h = 0
        while i + h < self.n and self.src[i + h] == "#":
            h += 1
        nxt = self.src[i + h:i + h + 1]
        if nxt == '"':
            return self._string(i, h)
        if h and nxt == "/":
            return self._regex(i, h)
        return i + max(h, 1)

    def _interpolation(self, seg, at, length):
        """Blank the literal text seg..at, keep the interpolation's `(`, scan its code; return where the text resumes."""
        self.blank(seg, at + length - 1)
        return self.code(at + length, True)

    def _string(self, i, h):
        i += h
        multi = self.src.startswith('"""', i)
        i += 3 if multi else 1
        close = ('"""' if multi else '"') + "#" * h
        esc = "\\" + "#" * h
        seg = i
        while i < self.n:
            if self.src.startswith(esc + "(", i):
                i = seg = self._interpolation(seg, i, len(esc) + 1)
                continue
            if self.src.startswith(esc, i):
                i += len(esc) + 1
                continue
            if self.src.startswith(close, i):
                self.blank(seg, i)
                return i + len(close)
            if not multi and self.src[i] == "\n":   # unterminated: the compiler rejects it, stop at the line end
                self.blank(seg, i)
                return i
            i += 1
        self.blank(seg, self.n)
        return self.n

    def _escaped(self, i):
        """True when an odd number of backslashes sits right before src[i]."""
        k = i
        while k > 0 and self.src[k - 1] == "\\":
            k -= 1
        return (i - k) % 2 == 1

    def _regex(self, i, h):
        """Blank an extended regex, retaining code inside raw-style interpolations."""
        i += h + 1
        close = "/" + "#" * h
        interp = "\\" + "#" * h + "("
        seg = i
        while i < self.n:
            if self.src.startswith(interp, i):
                i = seg = self._interpolation(seg, i, len(interp))
                continue
            if self.src.startswith(close, i) and not self._escaped(i):
                self.blank(seg, i)
                return i + len(close)
            i += 1
        self.blank(seg, self.n)
        return self.n


def mask(src):
    """Return src with every comment and every string literal's contents replaced by spaces (newlines kept), so each
    remaining character is code at its original offset. String delimiters and an interpolation's parentheses stay,
    interpolated code stays."""
    m = _Masker(src)
    m.code(0, False)
    return "".join(m.out)


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


def _enclosing_open(text, i):
    """The index of the unmatched `(`, `[` or `{` that encloses text[i], or -1 at the top level."""
    depth = 0
    for k in range(i - 1, -1, -1):
        c = text[k]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                return k
            depth -= 1
    return -1


def _is_parameter_list(text, open_at):
    """True when the `(` at open_at opens a declaration's parameter list (`func f(`, `func f<T>(`, `init?(`,
    `subscript(`) or a tuple type that is itself a declaration's type annotation."""
    if _in_type_position(text, open_at):
        return True
    j = _skip_space_back(text, open_at)
    if j >= 2 and text[j - 1] == ">" and text[j - 2] != "-":
        j = _skip_space_back(text, max(_match_open(text, j - 1, "<", ">"), 0))
    if j > 0 and text[j - 1] in "?!":
        j -= 1
    name, start = _ident_before(text, j)
    if name in ("init", "subscript"):
        return text[start - 1:start] != "."       # `self.init(` and `super.init(` are calls
    return _ident_before(text, _skip_space_back(text, start))[0] == "func"


def _declaration_colon(text, colon):
    """True when the `:` at text[colon] follows the name in `let/var name:` or a parameter in a parameter list."""
    name, start = _ident_before(text, _skip_space_back(text, colon))
    if not name:
        return False         # `["k": v]`, `(a) : b`
    if _ident_before(text, _skip_space_back(text, start))[0] in ("let", "var"):
        return True
    k = _enclosing_open(text, start)
    return k >= 0 and text[k] == "(" and _is_parameter_list(text, k)


def _in_type_position(text, start):
    """True when the type that starts at `start` is a declaration's type annotation (after `->`, or after the `:` of a
    declaration; a ternary's `:`, a dictionary literal's or an argument label's is an expression)."""
    j = _skip_space_back(text, start)
    if j >= 2 and text[j - 2:j] == "->":
        return True
    return j >= 1 and text[j - 1] == ":" and _declaration_colon(text, j - 1)


def _bracket_type(text, close):
    """`[T]!`, `[K: V]!`, `(T)!`, `(label: T)!`: a type only where a declaration annotates one."""
    open_ch = "[" if text[close] == "]" else "("
    k = _match_open(text, close, open_ch, text[close])
    return k >= 0 and _in_type_position(text, k)


def _named_type(text, bang):
    """`T!`, `Outer.Inner!`: a capitalised name (project style) in a declaration's type annotation."""
    name, start = _ident_before(text, bang)
    if not name or not name[0].isupper():
        return False         # types are capitalised; values are not (project style)
    while start > 0 and text[start - 1] == ".":
        q, start = _ident_before(text, start - 1)
        if not q:
            return False     # `.Case!` on an implicit member is an expression
    return _in_type_position(text, start)


def _is_iuo(text, bang):
    """True when the `!` at text[bang] closes an implicitly unwrapped optional type, not an expression."""
    prev = text[bang - 1]
    if prev == ">":          # G<T>!: a generic type
        return True
    if prev in ")]":
        return _bracket_type(text, bang - 1)
    if prev == "}":
        return False         # `xs.first { $0 > 1 }!`: a call with a trailing closure
    return _named_type(text, bang)


def _after_word(text, bang):
    """The kind of a `!` right after an identifier character: `try!`, `as!`, a force unwrap, or None (a prefix `!`)."""
    name, start = _ident_before(text, bang)
    if name in ("try", "as"):
        return name + "!"
    if (name in KEYWORDS and text[start:start + 1] != "`") or name[:1].isdigit():
        return None          # prefix `!` after a keyword; a number cannot be unwrapped
    return "force-unwrap"


def _bang_kind(text, i):
    """The kind of the `!` at text[i], or None when it crashes nothing."""
    if i == 0 or text[i + 1:i + 2] == "=":
        return None          # != and !==
    prev = text[i - 1]
    if prev in IDENT_CHARS or prev == "`":
        kind = _after_word(text, i)
        if kind != "force-unwrap":
            return kind
    elif prev not in EXPR_ENDS:
        return None          # prefix `!`, or `!` after whitespace or an operator
    return None if _is_iuo(text, i) else "force-unwrap"


def _is_crash_call(text, m):
    """True when the matched name is the standard library's function, not a method or a definition of that name."""
    before = _skip_space_back(text, m.start())
    if before > 0 and text[before - 1] == ".":
        return _ident_before(text, before - 1)[0] == "Swift"
    return _ident_before(text, _skip_space_back(text, before))[0] != "func"


CALL_RE = re.compile(r"(?<![A-Za-z0-9_$`])(fatalError|preconditionFailure|precondition)\s*\(")


def scan(src):
    """Every crash construct in a Swift source: a list of (kind, line number)."""
    text = mask(src)
    starts = [0] + [m.end() for m in re.finditer("\n", text)]
    hits = [(_bang_kind(text, m.start()), m.start()) for m in re.finditer("!", text)]
    hits += [(CALLS[m.group(1)], m.start()) for m in CALL_RE.finditer(text) if _is_crash_call(text, m)]
    found = [(kind, bisect.bisect_right(starts, off)) for kind, off in hits if kind]
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
        raise TypeError("baseline is not an object")
    counts = data.get("counts")
    if not isinstance(counts, dict):
        raise TypeError("no \"counts\" object")
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


def parse_name_status(text):
    """{new path: old path} from `git diff --name-status` output: every rename, and every copy whose source the same
    diff removes (a split)."""
    moved, copied, removed = {}, {}, set()
    for fields in (line.split("\t") for line in text.splitlines()):
        status = fields[0][:1]
        if status in ("R", "C") and len(fields) == 3:
            (moved if status == "R" else copied)[fields[2]] = fields[1]
        if status in ("R", "D"):
            removed.add(fields[1])
    moved.update({new: old for new, old in copied.items() if old in removed})
    return moved


def file_moves(root, rev):
    """{new path: old path} for files renamed, or split off a removed file, between rev and the working tree."""
    try:
        out = subprocess.run(["git", "-C", root, "diff", "--find-renames", "--find-copies", "--name-status", rev, "--"],
                             capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return {}
    return parse_name_status(out.stdout)


def _sum_counts(entries):
    total = {}
    for c in entries:
        for kind, v in c.items():
            total[kind] = total.get(kind, 0) + v
    return total


def _excess(label, counts, allowed):
    return [(label, kind, allowed.get(kind, 0), v) for kind, v in counts.items() if v > allowed.get(kind, 0)]


def baseline_increases(base, working, moves):
    """Return working baseline entries that exceed their base entry: the same path's, or for the files moved from one
    old path (a rename, or the parts of a split), that path's, which they share."""
    groups = {}
    for new, old in sorted(moves.items()):
        if new in working:
            groups.setdefault(old, []).append(new)
    grouped = {new for dests in groups.values() for new in dests}
    violations = []
    for rel, counts in working.items():
        if rel not in grouped:
            violations += _excess(rel, counts, {} if rel in groups else base.get(rel, {}))
    for old, dests in groups.items():
        combined = _sum_counts(working[new] for new in dests)
        violations += _excess(" + ".join(dests), combined, base.get(old, {}))
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


# ---- command line ----

def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--baseline")
    ap.add_argument("--base", help="git revision the change is judged against, to name the new occurrences")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--update", action="store_true")
    mode.add_argument("--init", action="store_true")
    mode.add_argument("--list", nargs="*", metavar="PATH")
    return ap.parse_args(argv)


def list_occurrences(root, paths):
    for rel, found in tree_occurrences(root, paths or swift_files(root)).items():
        src_lines = read(root, rel).split("\n")
        for kind, line in found:
            print(f"{rel}:{line}: {kind}: {src_lines[line - 1].strip()[:160]}")
    return 0


def init_baseline(path, current, total_line):
    if os.path.exists(path):
        print(f"refused: {path} exists; counts only go down (--update)", file=sys.stderr)
        return 2
    write_baseline(path, current)
    print(f"wrote {path}: {total_line}")
    return 0


def update_baseline(path, baseline, current, total_line):
    rises, falls = compare(baseline, current)
    if rises:
        print("refused: --update only lowers counts, and these are above the baseline:", file=sys.stderr)
        for rel, kind, b, c in rises:
            print(f"  {rel}: {kind} {b} -> {c}", file=sys.stderr)
        return 2
    lowered = {rel: {k: min(v, current.get(rel, {}).get(k, 0)) for k, v in c.items()} for rel, c in baseline.items()}
    write_baseline(path, lowered)
    print(f"lowered {len(falls)} count(s); baseline now: {total_line}")
    return 0


def baseline_rise_lines(baseline_rises):
    if not baseline_rises:
        return []
    lines = ["**The committed baseline rose relative to the base revision:**", ""]
    lines += [f"- `{rel}`: {kind}; base {b}, new {c}" for rel, kind, b, c in baseline_rises]
    return lines + ["", ("Baseline counts may only stay level or decrease (including across detected renames and "
                         "splits)."), ""]


def rise_lines(root, rev, moves, occ, rises):
    """The report lines and annotations for the files above the baseline, each naming its new occurrences."""
    report, notes = ["**Above the baseline** (mpvfx-swift/AGENTS.md: return a typed error instead):", ""], []
    for rel, kind, b, c in rises:
        src = read(root, rel)
        old = base_text(root, rev, moves.get(rel, rel)) if rev else None
        report.append(f"- `{rel}`: {kind} {b} -> {c}; {'new' if old is not None else 'every'} occurrence(s):")
        src_lines = src.split("\n")
        for line in new_occurrences(src, occ.get(rel, []), kind, old):
            report.append(f"  - `{rel}:{line}`: `{src_lines[line - 1].strip()[:160]}`")
            notes.append(f"::error file={rel},line={line},title=crash construct ({kind})::{kind} above the "
                         f"baseline ({b} -> {c}); return a typed error instead")
    report += ["", ("Remove the new construct (handle the nil, `try` with a typed error, `as?`). The script never "
                    "raises the baseline; a file that only moved carries its entry over by hand in the same pull "
                    "request, where review sees it.")]
    return report, notes


def falls_lines(falls):
    if not falls:
        return ["Within the baseline."], []
    return ([(f"Within the baseline; {len(falls)} count(s) went down. Lock the gain in this pull request: "
              "`python3 -I -B .github/ci/crash_constructs.py --update`.")],
            [(f"::notice title=crash constructs went down::{len(falls)} count(s) below the baseline; run "
              ".github/ci/crash_constructs.py --update to lock them in")])


def emit(report, notes):
    print("\n".join(report))
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    for note in notes:
        print(note)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("\n".join(report) + "\n")


def check(a, root, baseline_path, occ, total_line):
    """Judge the tree against the baseline (and the baseline against the one at --base); print the report."""
    try:
        baseline = load_baseline(baseline_path)
        base_baseline = baseline_at_revision(root, a.base) if a.base else None
    except (OSError, ValueError, TypeError) as e:
        print(f"cannot read the baseline {baseline_path}: {e}", file=sys.stderr)
        return 2
    rises, falls = compare(baseline, counts_of(occ))
    moves = file_moves(root, a.base) if a.base else {}
    baseline_rises = baseline_increases(base_baseline, baseline, moves) if base_baseline is not None else []
    report = ["## Crash constructs (force unwrap, try!, as!, fatalError, precondition)", "",
              f"Current: {total_line}. Baseline: `{BASELINE_REL}`.", ""]
    report += baseline_rise_lines(baseline_rises)
    extra, notes = rise_lines(root, a.base, moves, occ, rises) if rises else falls_lines(falls)
    emit(report + extra, notes)
    return 1 if rises or baseline_rises else 0


def main(argv=None):
    a = parse_args(argv)
    root = os.path.abspath(a.root)
    baseline_path = a.baseline or os.path.join(root, BASELINE_REL)
    if a.list is not None:
        return list_occurrences(root, a.list)
    occ = tree_occurrences(root)
    current = counts_of(occ)
    totals = {k: sum(c.get(k, 0) for c in current.values()) for k in KINDS}
    total_line = ", ".join(f"{k} {totals[k]}" for k in KINDS) + f" (in {len(current)} files)"
    if a.init:
        return init_baseline(baseline_path, current, total_line)
    if a.update:
        try:
            baseline = load_baseline(baseline_path)
        except (OSError, ValueError, TypeError) as e:
            print(f"cannot read the baseline {baseline_path}: {e}", file=sys.stderr)
            return 2
        return update_baseline(baseline_path, baseline, current, total_line)
    return check(a, root, baseline_path, occ, total_line)


if __name__ == "__main__":
    sys.exit(main())

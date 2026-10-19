#!/usr/bin/env python3
"""leak-scan.py --root TREE --private CLONE: find maintainer-only text in a snapshot tree before it is published.

TREE is the snapshot (every file under it is scanned, .git excluded). CLONE is the temporary clone of the old
repository the snapshot was taken from; what counts as private is read from it at run time, so this script holds no
private vocabulary itself:
  - when CLONE has its own scanner (agent-kit/tools/github/leak_scan.py), its rules run over TREE unchanged
    (identifiers, private paths, and 12-word runs shared with the private instruction files);
  - otherwise a generic scan runs: internal rule IDs (a capital D, two or three digits, then a clause number), paths of the private folders,
    names of the private skills, roles, prompts and hooks (file names under CLONE), the phrase "owner ruling", and
    12-word runs shared with CLONE's private Markdown files.
Files whose job is to name those paths (.gitignore, the session-start wiring) are not checked for paths.
Prints one line per finding (path:line: kind: text). Exit 0 clean, 1 findings, 2 bad arguments.
"""
import argparse, importlib.util, os, re, sys

PRIVATE_DIRS = ("agent-kit/", ".claude/agents/", ".claude/prompts/", ".claude/rules/", ".claude/skills/")
# Files whose job is to name the private paths (to ignore them, or to start the session hook).
PATH_EXEMPT = (".gitignore", ".claude/settings.json", ".claude/hooks/session-start.sh")
SHINGLE = 12
SKIP_DIRS = {".git", ".build", ".binaries", "__pycache__"}


def files(root):
    for dirpath, dirnames, names in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in names:
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            try:
                with open(path, "rb") as f:
                    data = f.read(2_000_001)
            except OSError:
                continue
            if len(data) > 2_000_000 or b"\0" in data[:8000]:
                continue
            yield rel, data.decode("utf-8", errors="replace")


def private_scanner(clone):
    path = os.path.join(clone, "agent-kit", "tools", "github", "leak_scan.py")
    if not os.path.exists(path):
        return None
    spec = importlib.util.spec_from_file_location("private_leak_scan", path)
    module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    rules = module.Rules(clone)
    return lambda text, rel: [(kind, detail, n) for kind, detail, n in rules.check(text, rel)]


def words(text):
    return re.findall(r"[a-z0-9]+", re.sub(r"<!--.*?-->", " ", text, flags=re.S).lower())


def generic_scanner(clone):
    names = set()
    for sub in ("agent-kit/skills", "agent-kit/agents", "agent-kit/prompts", ".claude/skills", ".claude/agents",
                ".claude/prompts", ".claude/hooks"):
        d = os.path.join(clone, sub)
        if os.path.isdir(d):
            names.update(re.sub(r"\.(md|py)$", "", n) for n in os.listdir(d) if not n.startswith(("test_", "README")))
    names = sorted(n for n in names if re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)+", n))
    vocab = re.compile(r"(?<![\w/.-])(?:" + "|".join(map(re.escape, names)) + r")(?![\w-])") if names else None
    rule_id = re.compile(r"\bD\d{2,3}\s*(?:inv\.\s*\d+|F\d+)")
    paths = re.compile(r"(?<![\w-])(?:agent-kit\b|\.claude/(?:agents|prompts|rules|skills)\b|\.agents/)")
    phrase = re.compile(r"owner ruling", re.I)

    corpus = set()
    for top in ("agent-kit", ".claude", "mpvfx-swift/.agents"):
        for dirpath, _, fs in os.walk(os.path.join(clone, top)):
            for f in fs:
                if f.endswith(".md"):
                    with open(os.path.join(dirpath, f), encoding="utf-8", errors="replace") as h:
                        w = words(h.read())
                    corpus.update(" ".join(w[i:i + SHINGLE]) for i in range(len(w) - SHINGLE + 1))

    def check(text, rel):
        out = []
        for n, line in enumerate(text.split("\n"), 1):
            out += [("rule ID", m.group(0), n) for m in rule_id.finditer(line)]
            out += [("private phrase", m.group(0), n) for m in phrase.finditer(line)]
            if vocab:
                out += [("private name", m.group(0), n) for m in vocab.finditer(line)]
            out += [("private path", m.group(0), n) for m in paths.finditer(line)]
        w = words(text)
        for i in range(len(w) - SHINGLE + 1):
            run = " ".join(w[i:i + SHINGLE])
            if run in corpus:
                out.append(("text shared with private instructions", run, 0))
                break
        return out

    return check


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", required=True)
    ap.add_argument("--private", required=True, help="the temporary clone of the old repository")
    args = ap.parse_args(argv)
    if not os.path.isdir(args.root) or not os.path.isdir(args.private):
        print("leak-scan: --root and --private must be folders", file=sys.stderr)
        return 2
    check = private_scanner(args.private)
    which = "the old repository's own scanner"
    if check is None:
        check, which = generic_scanner(args.private), "the generic scan"
    findings = []
    for rel, text in files(args.root):
        if rel.startswith("tools/snapshot/"):
            continue
        for kind, detail, n in check(text, rel):
            if rel in PATH_EXEMPT and "path" in f"{kind} {detail}":
                continue
            findings.append(f"{rel}:{n}: {kind}: {detail}" if n else f"{rel}: {kind}: {detail}")
    for f in findings:
        print(f)
    print(f"leak-scan ({which}): {len(findings)} findings", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

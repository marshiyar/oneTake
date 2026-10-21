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
"""integrate.py: combine conflicted pull requests into one mergeable pull request.

Three steps, one per job of .github/workflows/integrate.yml (the job that builds pull request code holds no secret):

  plan     list the pull requests to combine (the numbers given, else every open one into main labelled
           `merge-conflict`, drafts included, never `hold`, head in this repository) and write plan.json.
  build    in a checkout of main: reset the branch `integrate/batch` to main, merge each head in order
           (`git merge --no-ff`, hooks off, git rerere on) with conflicts.py's safe resolutions and a regenerate of
           the *-source.yml workflows; a pull request that stays conflicted is aborted and skipped. Then one build
           gate for the whole batch (warnings-as-errors build, tests build, the CI scripts' unit tests); a build
           error is mapped to the pull requests that changed the failing files, those are dropped and the batch is
           rebuilt, at most 3 times. Writes result.json and a git bundle of the branch.
  publish  with the review App's token: verify the bundle against live pull request state, build main + ONE squash
           commit authored and committed as the owner (a squash merge is authored by whoever opened the pull request,
           so the owner opens it) and push it as `integrate/batch` (the bot's own branch; the only force push). With
           the optional secret OWNER_TOKEN (a fine-grained token of the owner: contents and pull-requests write on
           this repository) it then opens or updates the one integration pull request, squash-merges it when `merge`
           is on and the gate passed, closes the included pull requests, drops their `merge-conflict` label; without
           it nothing is opened or merged and the summary says the branch is ready. Skipped and dropped pull requests
           get `needs-resolution` either way.
  land     a person runs it locally with their own `gh` login: opens the pull request from the pushed branch (body
           from its commit message, plus the Skipped section when `--result result.json` is given), squash-merges it,
           closes the pull requests named in the commit message and fixes the labels.

Order: pull request B follows A when A's head is an ancestor of B's head, then by number. Pull request code is only
ever merged by git here; the one scripts run are main's (shader generator, workflow generator), and only when the
pull request leaves them unchanged. Standard library only (the workflow generator needs PyYAML); GitHub through the
`gh` CLI and git through `git`, both via `Runner`, which tests replace.
"""
import argparse, contextlib, dataclasses, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import conflicts as cf        # noqa: E402  (Git, GitHub, Runner, classify, UNION_PATTERNS, labels)
import merge_train as mt      # noqa: E402  (closing_issues)

Error = cf.Error
BASE, BRANCH = cf.BASE, "integrate/batch"
NEEDS, NEEDS_COLOR = "needs-resolution", "fbca04"
TRAILER = "Agent-Role: integrate-bot"
ZED = "Zed Saranillo <saranillozed55@gmail.com>"
MAX_DROP_ROUNDS = 3
SOURCE_GEN = ".github/ci/source_workflows.py"
SOURCE_WORKFLOW_RE = re.compile(r"\.github/workflows/[A-Za-z0-9._-]+-source\.yml")
AUDIO_PREFIXES = ("mpvfx-swift/Sources/MpvfxAudio/", "mpvfx-swift/Sources/MpvfxAudioGraph/")
CAPTION_MARK = "aption"                       # Caption, caption, Captions
SWIFT_DIR, ROOT_TESTS = "mpvfx-swift", ["python3", "-m", "unittest", "discover", "-s", ".github/ci", "-p", "test_*.py"]
BUILDS = ([["python3", "-I", "-B", "scripts/fetch-binaries.py"],
           ["swift", "build", "-Xswiftc", "-warnings-as-errors", "-Xcc", "-Werror"],
           ["swift", "build", "--build-tests"]])
ERROR_PATH_RE = re.compile(r"^(\S[^\n]*?):\d+(?::\d+)?: error:", re.M)
NUMBERS_RE = re.compile(r"[0-9]+(?: [0-9]+)*")


# ---- decisions (pure) ------------------------------------------------------------------------------------------

@dataclasses.dataclass
class Item:
    number: int
    sha: str
    title: str = ""
    body: str = ""
    ref: str = ""

    def as_json(self):
        return dataclasses.asdict(self)


def parse_numbers(text):
    """Pull request numbers from the workflow input ("" -> none given). Anything but digits and spaces is refused."""
    text = (text or "").strip()
    if not text:
        return []
    if not NUMBERS_RE.fullmatch(" ".join(text.split())):
        raise Error(f"the pull request list must be numbers separated by spaces, got {text[:80]!r}")
    return list(dict.fromkeys(int(t) for t in text.split()))


def order_items(items, is_ancestor):
    """B after A when A's head is an ancestor of B's head (different heads), else by number."""
    rest = sorted(items, key=lambda i: i.number)
    before = {i.number: {j.number for j in rest if j.sha != i.sha and is_ancestor(j.sha, i.sha)} for i in rest}
    out, done = [], set()
    while rest:
        pick = next((i for i in rest if before[i.number] <= done), rest[0])   # a cycle cannot happen; be total anyway
        out.append(pick)
        done.add(pick.number)
        rest.remove(pick)
    return out


def is_generated_workflow(path):
    return bool(SOURCE_WORKFLOW_RE.fullmatch(path))


def wants_zed(files):
    """Audio or caption work: the squash message carries the owner's co-author line."""
    return any(f.startswith(AUDIO_PREFIXES) or CAPTION_MARK in f for f in files)


def refs_text(numbers):
    return " ".join(f"#{n}" for n in numbers)


def pr_title(numbers):
    return "Integrate " + refs_text(numbers)


def closing_lines(items):
    return [f"Closes #{n}" for n in mt.closing_issues(items)]


def one_line(text, limit=200):
    return " ".join((text or "").split())[:limit]


def render_body(included, skipped, dropped, items_by_number):
    """The integration pull request body: the included pull requests, their closing references, what was left out."""
    lines = ["Combines these pull requests into one mergeable change:", ""]
    lines += [f"- #{i['number']} {one_line(i['title'])}" for i in included]
    closes = closing_lines([items_by_number[i["number"]] for i in included if i["number"] in items_by_number])
    if closes:
        lines += [""] + closes
    return "\n".join(lines) + "\n\n" + skipped_section(skipped, dropped)


def skipped_section(skipped, dropped):
    lines = ["## Skipped", ""]
    rows = [(s["number"], s["reason"], s.get("files", [])) for s in skipped] + \
           [(d["number"], "dropped: the build failed (" + one_line(d["error"], 160) + ")", d.get("files", []))
            for d in dropped]
    if not rows:
        lines.append("None.")
    else:
        lines += ["| PR | Reason | Files |", "| --- | --- | --- |"]
        for n, why, files in sorted(rows):
            shown = ", ".join(f"`{f}`" for f in files[:8]) + (f" and {len(files) - 8} more" if len(files) > 8 else "")
            lines.append(f"| #{n} | {one_line(why, 240).replace('|', '/')} | {shown or '-'} |")
    return "\n".join(lines) + "\n"


def commit_message(included, all_files, closes=()):
    """The squash commit's message: the included pull requests, their `Closes #n` lines, the co-author line for
    audio/caption work, the role."""
    lines = [pr_title([i["number"] for i in included]), ""]
    lines += [f"- #{i['number']} {one_line(i['title'])}" for i in included]
    lines += [""]
    if closes:
        lines += list(closes) + [""]
    if wants_zed(all_files):
        lines.append(f"Co-authored-by: {ZED}")
    lines.append(TRAILER)
    return "\n".join(lines)


TRAILER_RE = re.compile(r"^(?:Agent-Role|Co-authored-by):", re.I)


def parse_message(message):
    """(title, included numbers, body lines without trailers) of a batch commit message made by commit_message."""
    lines = message.strip().splitlines()
    title = lines[0] if lines else ""
    numbers = list(dict.fromkeys(int(n) for n in re.findall(r"#([0-9]+)", title)))
    body = [l for l in lines[1:] if not TRAILER_RE.match(l)]
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    return title, numbers, body


def error_paths(output, root=""):
    """Repository-relative file paths named by `path:line:col: error:` lines of a build log."""
    found = []
    for m in ERROR_PATH_RE.finditer(output or ""):
        p = m.group(1).strip()
        if root and p.startswith(root.rstrip("/") + "/"):
            p = p[len(root.rstrip("/")) + 1:]
        elif p.startswith("/") and f"/{SWIFT_DIR}/" in p:
            p = p[p.index(f"/{SWIFT_DIR}/") + 1:]
        elif not p.startswith("/") and not p.startswith(SWIFT_DIR + "/") and not p.startswith(".github/"):
            p = f"{SWIFT_DIR}/{p}"   # the build runs inside mpvfx-swift/
        found.append(p)
    return list(dict.fromkeys(found))


def first_error(output):
    lines = [l.strip() for l in (output or "").splitlines() if l.strip()]
    return next((l for l in lines if "error:" in l), lines[-1] if lines else "build failed")[:300]


def blame(errors, files_by_pr):
    """Pull request numbers whose changed files include a file the build reported."""
    return sorted(n for n, files in files_by_pr.items() if set(files) & set(errors))


# ---- GitHub ----------------------------------------------------------------------------------------------------

class GitHub(cf.GitHub):
    def _one(self, path):
        _, out = self._api(path, jq="tojson")
        return json.loads(out)

    @staticmethod
    def _item(d):
        return Item(number=d["number"], sha=d["head"]["sha"], title=d.get("title") or "", body=d.get("body") or "",
                    ref=d["head"]["ref"])

    @staticmethod
    def _eligible(d):
        labels = {l["name"] for l in d.get("labels", [])}
        repo = (d["head"].get("repo") or {}).get("full_name")
        return (d.get("state") == "open" and d["base"]["ref"] == BASE and repo == d["base"]["repo"]["full_name"]
                and cf.HOLD not in labels and d["head"]["ref"] != BRANCH), labels

    def candidates(self, numbers):
        """The pull requests to combine: those named, else every labelled one. Never a held one, a fork's or a closed one."""
        if numbers:
            docs = [self._one(f"repos/{self.repo}/pulls/{n}") for n in numbers]
            return [self._item(d) for d in docs if self._eligible(d)[0]]
        docs = self._lines(f"repos/{self.repo}/pulls?state=open&per_page=100")
        return [self._item(d) for d in docs if (lambda ok, labels: ok and cf.LABEL in labels)(*self._eligible(d))]

    def live(self, n):
        d = self._one(f"repos/{self.repo}/pulls/{n}")
        return d["state"], d["head"]["sha"]

    def batch_pr(self):
        owner = self.repo.split("/")[0]
        docs = self._lines(f"repos/{self.repo}/pulls?state=open&head={owner}:{BRANCH}&per_page=10")
        return docs[0]["number"] if docs else None

    def upsert_pr(self, title, body):
        n = self.batch_pr()
        if n:
            self._api(f"repos/{self.repo}/pulls/{n}", method="PATCH", fields=[("title", title), ("body", body)])
            return n
        _, out = self._api(f"repos/{self.repo}/pulls", method="POST", jq=".number",
                           fields=[("title", title), ("head", BRANCH), ("base", BASE), ("body", body)])
        return int(out.strip())

    def squash_merge(self, n, sha, message):
        title, _, rest = message.partition("\n\n")
        self._api(f"repos/{self.repo}/pulls/{n}/merge", method="PUT",
                  fields=[("merge_method", "squash"), ("sha", sha), ("commit_title", f"{title} (#{n})"),
                          ("commit_message", rest)])

    def close(self, n):
        self._api(f"repos/{self.repo}/pulls/{n}", method="PATCH", fields=[("state", "closed")])

    def add_needs_resolution(self, n):
        self._api(f"repos/{self.repo}/labels", method="POST",
                  fields=[("name", NEEDS), ("color", NEEDS_COLOR),
                          ("description", "Integration could not combine it; resolve against main by hand")],
                  check=False)
        self._api(f"repos/{self.repo}/issues/{n}/labels", method="POST", fields=[("labels[]", NEEDS)])


# ---- git -------------------------------------------------------------------------------------------------------

@dataclasses.dataclass
class Merged:
    kind: str                      # merged | contained | skipped
    files: list = dataclasses.field(default_factory=list)
    detail: str = ""


class Git(cf.Git):
    def __init__(self, cwd, token="", run=None, which=None):
        super().__init__(cwd, token, run, **({"which": which} if which else {}))

    def shallow(self):
        return self._git("rev-parse", "--is-shallow-repository")[1] == "true"

    def fetch(self, numbers):
        """Main (whole history, merges need the merge base) and only the pull request heads; no tags."""
        args = ["fetch", "-q", "--no-tags"] + (["--unshallow"] if self.shallow() else [])
        self._git(*args, "origin", f"+refs/heads/{BASE}:refs/remotes/origin/{BASE}", auth=True)
        if numbers:
            self._git("fetch", "-q", "--no-tags", "origin", *[f"+refs/pull/{n}/head:refs/integrate/pr/{n}" for n in numbers],
                      auth=True)
        return {n: self._git("rev-parse", f"refs/integrate/pr/{n}")[1] for n in numbers}

    def configure_rerere(self):
        self._git("config", "rerere.enabled", "true")
        self._git("config", "rerere.autoupdate", "true")

    def head(self):
        return self._git("rev-parse", "HEAD")[1]

    def is_ancestor(self, a, b):
        return self._git("merge-base", "--is-ancestor", a, b, check=False)[0] == 0

    def changed_files(self, base, sha):
        """Files the pull request changes against main; NUL-separated so odd names survive."""
        rc, out, _ = self.run(["git", "-c", "core.hooksPath=/dev/null", "diff", "--name-only", "--no-renames", "-z",
                               f"{base}...{sha}"], env=dict(self.IDENT), cwd=self.cwd)
        if rc != 0:
            raise Error(f"git diff {base[:12]}...{sha[:12]} failed")
        return sorted(set(out.split("\0")) - {""})

    def start(self, base):
        self._reset()
        self._git("checkout", "-q", "--detach", "--force", base)
        self._git("checkout", "-q", "-B", BRANCH, base)
        self._git("reset", "-q", "--hard", base)

    @contextlib.contextmanager
    def union_attributes(self):
        path = self._attributes()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        saved = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        with open(path, "w", encoding="utf-8") as f:
            f.write("".join(f"{p} merge=union\n" for p in cf.UNION_PATTERNS) + "mpvfx-swift/docs/STATUS.md merge=union\n")
        try:
            yield
        finally:
            if saved is None:
                os.remove(path)
            else:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(saved)

    def regenerate_workflows(self):
        """Regenerate the *-source.yml files with main's generator. Returns "" or why it was not done."""
        if self._git("diff", "--quiet", f"origin/{BASE}", "--", SOURCE_GEN, check=False)[0] != 0:
            return "the pull request changes the workflow generator itself"
        rc, _, err = self.run(["python3", "-I", "-B", SOURCE_GEN], env=None, cwd=self.cwd)
        if rc != 0:
            return f"the workflow generator failed: {err.strip()[-200:]}"
        self._git("add", "-A", "--", ".github/workflows")
        return ""

    def merge_one(self, item):
        rc, _ = self._git("merge", "--no-ff", "--no-commit", item.sha, check=False)
        if not self.merging():
            if rc == 0:
                return Merged("contained")
            return Merged("skipped", detail="git could not start the merge")
        bad = self.unmerged()
        regen, manual = cf.classify(bad)
        workflows = [p for p in manual if is_generated_workflow(p)]
        manual = [p for p in manual if p not in workflows]
        why = ""
        if manual:
            why = "conflicts that need a person"
        elif regen and (r := self.regenerate()):
            why = f"generated GPU shaders: {r}"
        elif workflows and (r := self.regenerate_workflows()):
            why = f"generated workflows: {r}"
        elif self.unmerged():
            why = "conflicts remain after the safe resolutions"
        if why:
            files = sorted(set(self.unmerged() or bad))
            self._reset()
            return Merged("skipped", files=files, detail=why)
        self._git("commit", "-q", "-m", f"Merge #{item.number} into {BRANCH}", "-m", TRAILER)
        self._git("rerere", check=False)
        return Merged("merged")

    def bundle(self, base, path):
        self._git("bundle", "create", path, f"refs/heads/{BRANCH}", f"^{base}")

    def unbundle(self, path, tip):
        self._git("fetch", "-q", path, f"+refs/heads/{BRANCH}:refs/integrate/tip")
        got = self._git("rev-parse", "refs/integrate/tip")[1]
        if got != tip:
            raise Error("the bundle's branch is not the commit result.json names")

    def squash(self, base, tip, message):
        """main + ONE commit with the batch's tree, authored and committed as the owner (IDENT)."""
        tree = self._git("rev-parse", f"{tip}^{{tree}}")[1]
        sha = self._git("commit-tree", tree, "-p", base, "-m", message)[1]
        self._git("update-ref", "refs/integrate/squash", sha)
        return sha

    def push_batch(self):
        """The bot's own branch: the one force push here."""
        self._git("push", "-q", "--force", "origin", f"refs/integrate/squash:refs/heads/{BRANCH}", auth=True)

    def fetch_batch(self):
        """The pushed branch: (sha, commit message)."""
        self._git("fetch", "-q", "--no-tags", "origin", f"+refs/heads/{BRANCH}:refs/integrate/tip")
        return (self._git("rev-parse", "refs/integrate/tip")[1],
                self._git("log", "-1", "--format=%B", "refs/integrate/tip")[1])


# ---- the build gate --------------------------------------------------------------------------------------------

class Gate:
    def __init__(self, root, run=None):
        self.root, self.run = root, run or cf.Runner()

    def _try(self, cmd, cwd):
        rc, out, err = self.run(cmd, env=None, cwd=cwd)
        text = (out or "") + (err or "")
        print(f"$ {' '.join(cmd)} -> {rc}\n{text[-4000:]}", flush=True)
        return rc, text

    def build(self):
        """"" when the whole batch builds, else the failing command's output."""
        for cmd in BUILDS:
            rc, text = self._try(cmd, os.path.join(self.root, SWIFT_DIR))
            if rc != 0:
                return text
        return ""

    def tests(self):
        rc, text = self._try(ROOT_TESTS, self.root)
        return "" if rc == 0 else text


def build_batch(git, gate, items, base):
    """Merge in order, gate once, drop what the build blames; returns the result document."""
    ordered = order_items(items, git.is_ancestor)
    files = {i.number: git.changed_files(base, i.sha) for i in ordered}
    dropped, gate_state, detail = {}, "none", ""
    for attempt in range(MAX_DROP_ROUNDS + 1):
        git.start(base)
        included, skipped, contained = [], {}, []
        for it in ordered:
            if it.number in dropped:
                continue
            res = git.merge_one(it)
            if res.kind == "merged":
                included.append(it)
            elif res.kind == "contained":
                contained.append(it.number)
            else:
                skipped[it.number] = {"number": it.number, "reason": res.detail, "files": res.files}
        if not included:
            break
        err = gate.build()
        if not err:
            err = gate.tests()
            gate_state, detail = ("passed", "") if not err else ("failed", "unit tests: " + first_error(err))
            break
        blamed = blame(error_paths(err, gate.root), {i.number: files[i.number] for i in included})
        gate_state, detail = "failed", first_error(err)
        if not blamed or attempt == MAX_DROP_ROUNDS:
            break
        for n in blamed:
            dropped[n] = first_error(err)
    by = {i.number: i for i in ordered}
    return {"base": base, "tip": git.head() if included else base, "gate": gate_state, "gate_detail": detail,
            "included": [{"number": i.number, "title": i.title, "sha": i.sha, "files": files[i.number]} for i in included],
            "skipped": [skipped[n] for n in sorted(skipped)],
            "dropped": [{"number": n, "title": by[n].title, "error": e, "files": files[n]} for n, e in sorted(dropped.items())],
            "contained": contained}


def summary(result, note=""):
    rows = ["| Pull request | Outcome | Detail |", "| --- | --- | --- |"]
    rows += [f"| #{i['number']} {one_line(i['title'], 80)} | included | |" for i in result["included"]]
    rows += [f"| #{s['number']} | skipped | {one_line(s['reason'], 120)}; {len(s['files'])} file(s) |" for s in result["skipped"]]
    rows += [f"| #{d['number']} | dropped | {one_line(d['error'], 160).replace('|', '/')} |" for d in result["dropped"]]
    rows += [f"| #{n} | already in main | |" for n in result["contained"]]
    head = f"### integrate\n\nBuild gate: **{result['gate']}** {one_line(result.get('gate_detail', ''), 200)}\n"
    return head + (f"\n{note}\n" if note else "") + "\n" + "\n".join(rows) + "\n"


# ---- publish ---------------------------------------------------------------------------------------------------

def land_batch(owner, sha, number, included, merge_message, skipped_ids, contained, log):
    """With the owner's identity: squash-merge, close the combined pull requests, fix labels. Returns the note."""
    owner.squash_merge(number, sha, merge_message)
    for n in included:
        owner.close(n)
        owner.remove_label(n)
    for n in contained:
        owner.remove_label(n)
    for n in skipped_ids:
        owner.add_needs_resolution(n)
    return f"Squash-merged #{number}; closed {refs_text(included)}."


def publish(gh, git, plan, result, merge, bundle, log, owner=None):
    """Push main + one owner-authored squash commit. With `owner` (a GitHub client on the owner's token) also open the
    pull request and squash-merge it; without, open and merge nothing: the branch is ready for `land`."""
    items = {i["number"]: Item(**i) for i in plan["prs"]}
    included, note = result["included"], ""
    left_out = [s["number"] for s in result["skipped"]] + [d["number"] for d in result["dropped"]]
    if included:
        stale = [i["number"] for i in included if gh.live(i["number"]) != ("open", i["sha"])]
        git.unbundle(bundle, result["tip"])
        for i in included:
            if not git.is_ancestor(i["sha"], "refs/integrate/tip"):
                raise Error(f"#{i['number']}'s head is not in the bundle")
        numbers = [i["number"] for i in included]
        files = sorted({f for i in included for f in i["files"]})
        message = commit_message(included, files, closing_lines([items[n] for n in numbers if n in items]))
        sha = git.squash(result["base"], result["tip"], message)
        git.push_batch()
        log.append(f"pushed {BRANCH} at {sha[:12]}")
        if owner is None:
            note = (f"`{BRANCH}` is ready at `{sha[:12]}` ({refs_text(numbers)}). No OWNER_TOKEN is set, so no pull "
                    f"request was opened or merged; run `integrate.py land` with your own gh login.")
        else:
            n = owner.upsert_pr(pr_title(numbers), render_body(included, result["skipped"], result["dropped"], items))
            log.append(f"integration pull request #{n}")
            if not merge:
                note = f"Opened #{n}; merge is off."
            elif result["gate"] != "passed":
                note = f"Opened #{n}; not merged: build gate {result['gate']}."
            elif stale:
                note = f"Opened #{n}; not merged: {refs_text(stale)} changed since the build."
            else:
                note = land_batch(owner, sha, n, numbers, message, [], [], log)
    else:
        owner = None
    for n in result["contained"]:
        (owner or gh).remove_label(n)
    for n in left_out:
        gh.add_needs_resolution(n)
    log.append(note or "nothing to integrate")
    return note


def land(owner, git, result, log):
    """A person's local run: open the pull request from the pushed branch, squash-merge it, close what it combines."""
    sha, message = git.fetch_batch()
    title, numbers, body = parse_message(message)
    if not numbers:
        raise Error(f"{BRANCH}'s commit message names no pull requests")
    text = "\n".join(body) + "\n"
    if result:
        text += "\n" + skipped_section(result["skipped"], result["dropped"])
    n = owner.upsert_pr(title, text)
    log.append(f"integration pull request #{n}")
    left = ([s["number"] for s in result["skipped"]] + [d["number"] for d in result["dropped"]]) if result else []
    return land_batch(owner, sha, n, numbers, message, left, result["contained"] if result else [], log)


# ---- commands --------------------------------------------------------------------------------------------------

def write_json(path, doc):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def append_env_file(var, text):
    path = os.environ.get(var)
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)


def cmd_plan(args, env):
    gh = GitHub(env["GITHUB_REPOSITORY"])
    items = gh.candidates(parse_numbers(env.get("INTEGRATE_PRS", "")))
    _, out = gh._api(f"repos/{gh.repo}/git/ref/heads/{BASE}", jq=".object.sha")
    write_json(args.out, {"base": out.strip(), "prs": [i.as_json() for i in items]})
    append_env_file("GITHUB_OUTPUT", f"any={'true' if items else 'false'}\nbase={out.strip()}\n")
    print(f"{len(items)} pull request(s): {refs_text(i.number for i in items) or 'none'}")
    return 0


def cmd_build(args, env):
    plan = read_json(args.plan)
    items = [Item(**i) for i in plan["prs"]]
    git = Git(os.getcwd())
    git.configure_rerere()
    heads = git.fetch([i.number for i in items])
    for i in items:
        if heads[i.number] != i.sha:
            i.sha = heads[i.number]          # the head moved since the plan: build what is there now
    with git.union_attributes():
        result = build_batch(git, Gate(os.getcwd()), items, plan["base"])
    if result["included"]:
        git.bundle(plan["base"], args.bundle)
    write_json(args.out, result)
    append_env_file("GITHUB_STEP_SUMMARY", summary(result))
    print(summary(result))
    return 0


class TokenRunner(cf.Runner):
    """gh calls made with the owner's token."""

    def __init__(self, token):
        self.token = token

    def __call__(self, args, env=None, cwd=None):
        return super().__call__(args, env=dict(env or {}, GH_TOKEN=self.token), cwd=cwd)


def cmd_publish(args, env):
    plan, result = read_json(args.plan), read_json(args.result)
    repo = env["GITHUB_REPOSITORY"]
    gh = GitHub(repo)
    owner = GitHub(repo, run=TokenRunner(env["OWNER_TOKEN"])) if env.get("OWNER_TOKEN") else None
    git = Git(os.getcwd(), env["PUSH_TOKEN"])
    log = []
    note = publish(gh, git, plan, result, env.get("INTEGRATE_MERGE", "true") == "true", args.bundle, log, owner)
    append_env_file("GITHUB_STEP_SUMMARY", summary(result, note))
    print("\n".join(log))
    return 0


def cmd_land(args, env):
    """Run locally; `gh` and git use the person's own login."""
    repo = args.repo or env.get("GITHUB_REPOSITORY")
    if not repo:
        raise Error("name the repository: --repo owner/name")
    result = read_json(args.result) if args.result else None
    log = []
    note = land(GitHub(repo), Git(os.getcwd()), result, log)
    print("\n".join(log + [note]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--out", required=True)
    b = sub.add_parser("build")
    b.add_argument("--plan", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--bundle", required=True)
    q = sub.add_parser("publish")
    q.add_argument("--plan", required=True)
    q.add_argument("--result", required=True)
    q.add_argument("--bundle", required=True)
    ld = sub.add_parser("land", help="open, squash-merge and close from the pushed branch, with your own gh login")
    ld.add_argument("--repo", default="")
    ld.add_argument("--result", default="")
    args = ap.parse_args(argv)
    try:
        return {"plan": cmd_plan, "build": cmd_build, "publish": cmd_publish, "land": cmd_land}[args.cmd](args, os.environ)
    except Error as e:
        print(f"integrate: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

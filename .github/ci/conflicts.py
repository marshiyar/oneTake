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
"""conflicts.py: keep open pull requests free of stale merge conflicts.

For every open, ready (not draft) pull request into main whose head branch is in this repository and that has no
label `hold`, ask GitHub whether it is mergeable (the field is null while GitHub computes it: polled a bounded number
of times, then the pull request is skipped until the next round).

A conflicted one gets `git merge origin/main` tried in a checkout of main, with these safe resolutions only:
  * Markdown (`*.md`, STATUS.md among them) takes the union of both sides (`merge=union`, set in the temporary
    .git/info/attributes for the attempt);
  * the generated GPU shader files are regenerated with main's `gen-compute-shaders.py` (never the pull request's
    own copy: when the pull request changed the generator, the files stay a conflict) when glslangValidator and
    spirv-opt are installed or installable;
  * anything else is a real conflict.
If every conflict resolved that way, the merge is committed as the owner with the trailer `Agent-Role: conflicts-bot`,
pushed to the pull request branch (a normal push, never forced) and the label `merge-conflict` is removed. Otherwise
the merge is aborted, the label is added and one comment per head commit lists the conflicting files (a marker in the
comment keeps it from being repeated). A pull request that is no longer conflicted loses the label.

Nothing from a pull request runs: git only merges trees (hooks are off), and the one script that runs is main's.
Standard library only; GitHub through the `gh` CLI and git through `git`, both via `Runner`, which tests replace.
"""
import base64, dataclasses, json, os, re, shutil, subprocess, sys, time

LABEL, HOLD = "merge-conflict", "hold"
LABEL_COLOR = "d93f0b"
BASE = "main"
OWNER_NAME, OWNER_EMAIL = "Arshiya Rahgozar", "57055687+marshiyar@users.noreply.github.com"
TRAILER = "Agent-Role: conflicts-bot"
GENERATOR = "mpvfx-swift/scripts/gpu/gen-compute-shaders.py"
GENERATED_FILES = ("mpvfx-swift/Sources/CMpvfxVulkan/mpvfx_grade_spirv.h",
                   "mpvfx-swift/Sources/CMpvfxWin32/mpvfx_grade_hlsl.h")
GENERATED_DIR = "mpvfx-swift/scripts/gpu/generated/"
UNION_PATTERNS = ("*.md",)
POLLS, POLL_SECONDS = 6, 5
BRANCH_RE = re.compile(r"[A-Za-z0-9._][A-Za-z0-9._/-]*")
MARKER_RE = re.compile(r"<!-- conflicts-bot:head ([0-9a-f]{40}) -->")
SHA_RE = re.compile(r"[0-9a-f]{40}")


class Error(Exception):
    pass


@dataclasses.dataclass
class PR:
    number: int
    head_sha: str = ""
    head_ref: str = ""
    same_repo: bool = True
    draft: bool = False
    labels: set = dataclasses.field(default_factory=set)
    base: str = BASE


@dataclasses.dataclass
class Outcome:
    kind: str                      # pushed | uptodate | conflict
    files: list = dataclasses.field(default_factory=list)
    detail: str = ""


# ---- decisions (pure) ------------------------------------------------------------------------------------------

def is_generated(path):
    return path in GENERATED_FILES or (path.startswith(GENERATED_DIR) and len(path) > len(GENERATED_DIR))


def classify(unmerged):
    """(regenerate, manual) for the paths still conflicted after the union merge. A Markdown path still unmerged
    (deleted on one side) is manual: the union driver only merges contents."""
    regen = sorted(p for p in set(unmerged) if is_generated(p))
    manual = sorted(p for p in set(unmerged) if not is_generated(p))
    return regen, manual


def candidates(prs):
    """Open pull requests this bot looks at: into main, head in this repository, ready, not on hold."""
    return [p for p in prs if p.base == BASE and p.same_repo and not p.draft and HOLD not in p.labels]


def marker(sha):
    return f"<!-- conflicts-bot:head {sha} -->"


def already_commented(comment_bodies, sha):
    return any(sha in MARKER_RE.findall(b or "") for b in comment_bodies)


def comment_text(sha, files, detail=""):
    shown = "\n".join(f"- `{f}`" for f in files[:50]) or "- (none listed)"
    more = f"\n- ... and {len(files) - 50} more" if len(files) > 50 else ""
    why = f"\n\n{detail}" if detail else ""
    return (f"{marker(sha)}\nThis branch conflicts with `{BASE}` at `{sha[:12]}` and the conflicts-bot could not "
            f"resolve them automatically (only Markdown unions and regenerated GPU shader files are resolved). "
            f"Conflicting files:\n\n{shown}{more}{why}\n\nMerge `origin/{BASE}` into the branch and resolve them; "
            f"the label `{LABEL}` is removed once the pull request merges cleanly.")


def label_action(has_label, conflicted):
    """What to do with the label: "add", "remove" or None."""
    if conflicted and not has_label:
        return "add"
    if not conflicted and has_label:
        return "remove"
    return None


# ---- GitHub ----------------------------------------------------------------------------------------------------

class Runner:
    """Runs a command; returns (returncode, stdout, stderr). Tests pass their own callable instead."""

    def __call__(self, args, env=None, cwd=None):
        p = subprocess.run(args, env=dict(os.environ, **(env or {})), cwd=cwd, capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr


class GitHub:
    def __init__(self, repo, run=None, sleep=time.sleep):
        self.repo, self.run, self.sleep = repo, run or Runner(), sleep

    def _api(self, path, method="GET", fields=(), jq=None, paginate=False, check=True):
        args = ["gh", "api", "-X", method, path]
        for k, v in fields:
            args += ["-f", f"{k}={v}"]
        if paginate:
            args.append("--paginate")
        if jq:
            args += ["--jq", jq]
        rc, out, err = self.run(args)
        if rc != 0 and check:
            raise Error(f"gh api {method} {path.split('?')[0]}: {err.strip()[:300]}")
        return rc, out

    def _lines(self, path, jq=".[]"):
        _, out = self._api(path, jq=jq, paginate=True)
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def open_prs(self):
        out = []
        for d in self._lines(f"repos/{self.repo}/pulls?state=open&per_page=100"):
            repo = (d["head"].get("repo") or {}).get("full_name")
            out.append(PR(number=d["number"], head_sha=d["head"]["sha"], head_ref=d["head"]["ref"],
                          same_repo=repo == d["base"]["repo"]["full_name"], draft=bool(d.get("draft")),
                          labels={l["name"] for l in d.get("labels", [])}, base=d["base"]["ref"]))
        return out

    def mergeable(self, n):
        """True, False, or None when GitHub is still computing after the bounded polls."""
        for i in range(POLLS):
            _, out = self._api(f"repos/{self.repo}/pulls/{n}", jq=".mergeable")
            value = out.strip()
            if value in ("true", "false"):
                return value == "true"
            if i + 1 < POLLS:
                self.sleep(POLL_SECONDS)
        return None

    def head_sha(self, n):
        _, out = self._api(f"repos/{self.repo}/pulls/{n}", jq=".head.sha")
        return out.strip()

    def comment_bodies(self, n):
        return [str(b) for b in self._lines(f"repos/{self.repo}/issues/{n}/comments?per_page=100", jq=".[].body | tojson")]   # gh --jq prints strings raw; tojson keeps one JSON value per line

    def comment(self, n, body):
        self._api(f"repos/{self.repo}/issues/{n}/comments", method="POST", fields=[("body", body)])

    def ensure_label(self):
        self._api(f"repos/{self.repo}/labels", method="POST",
                  fields=[("name", LABEL), ("color", LABEL_COLOR),
                          ("description", "Conflicts with main; the conflicts-bot could not resolve it")],
                  check=False)

    def add_label(self, n):
        self.ensure_label()
        self._api(f"repos/{self.repo}/issues/{n}/labels", method="POST", fields=[("labels[]", LABEL)])

    def remove_label(self, n):
        self._api(f"repos/{self.repo}/issues/{n}/labels/{LABEL}", method="DELETE", check=False)


# ---- git -------------------------------------------------------------------------------------------------------

class Git:
    IDENT = {"GIT_AUTHOR_NAME": OWNER_NAME, "GIT_COMMITTER_NAME": OWNER_NAME,
             "GIT_AUTHOR_EMAIL": OWNER_EMAIL, "GIT_COMMITTER_EMAIL": OWNER_EMAIL}

    def __init__(self, cwd, token="", run=None, which=shutil.which):
        self.cwd, self.token, self.run, self.which = cwd, token, run or Runner(), which

    def _git(self, *args, check=True, auth=False):
        env = dict(self.IDENT)
        if auth and self.token:
            enc = base64.b64encode(f"x-access-token:{self.token}".encode()).decode()
            env.update({"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
                        "GIT_CONFIG_VALUE_0": f"AUTHORIZATION: basic {enc}"})
        # No hooks and no external drivers: nothing from a pull request runs; merging only reads its trees.
        rc, out, err = self.run(["git", "-c", "core.hooksPath=/dev/null", *args], env=env, cwd=self.cwd)
        if rc != 0 and check:
            raise Error(f"git {args[0]}: {(err or out).strip()[:500]}")
        return rc, out.strip()

    def _attributes(self):
        return os.path.join(self._git("rev-parse", "--absolute-git-dir")[1], "info", "attributes")

    def unmerged(self):
        return self._git("diff", "--name-only", "--diff-filter=U")[1].splitlines()

    def merging(self):
        return self._git("rev-parse", "-q", "--verify", "MERGE_HEAD", check=False)[0] == 0

    def tools_ready(self):
        """glslangValidator and spirv-opt on PATH, installing the Debian packages when they are not."""
        need = ("glslangValidator", "spirv-opt")
        if all(self.which(t) for t in need):
            return True
        for cmd in (["sudo", "-n", "apt-get", "install", "-y", "-qq", "glslang-tools", "spirv-tools"],
                    ["apt-get", "install", "-y", "-qq", "glslang-tools", "spirv-tools"]):
            if self.run(cmd, env=None, cwd=self.cwd)[0] == 0 and all(self.which(t) for t in need):
                return True
        return False

    def regenerate(self):
        """Regenerate the shader files with main's generator. Returns "" or why it was not done."""
        if self._git("diff", "--quiet", f"origin/{BASE}", "--", GENERATOR, check=False)[0] != 0:
            return "the pull request changes the shader generator itself"
        if not self.tools_ready():
            return "glslangValidator and spirv-opt are not installable here"
        rc, _, err = self.run(["python3", "-I", "-B", GENERATOR], env=None, cwd=self.cwd)
        if rc != 0:
            return f"the shader generator failed: {err.strip()[-200:]}"
        found = [p for p in (*GENERATED_FILES, GENERATED_DIR) if os.path.exists(os.path.join(self.cwd, p))]
        if found:
            self._git("add", "-A", "--", *found)
        return ""

    def _reset(self):
        self._git("merge", "--abort", check=False)
        self._git("reset", "-q", "--hard", check=False)
        self._git("clean", "-fdq", check=False)

    def attempt(self, branch, sha):
        """Merge origin/main into the pull request branch at `sha`; push when every conflict resolves safely."""
        if not BRANCH_RE.fullmatch(branch) or ".." in branch or not SHA_RE.fullmatch(sha):
            raise Error(f"refusing branch name {branch!r}")
        self._git("fetch", "-q", "origin", f"+refs/heads/{BASE}:refs/remotes/origin/{BASE}",
                  f"+refs/heads/{branch}:refs/conflicts/head", auth=True)
        tip = self._git("rev-parse", "refs/conflicts/head")[1]
        if tip != sha:
            return Outcome("uptodate", detail="the branch moved; next round")
        self._reset()
        self._git("checkout", "-q", "--detach", "--force", tip)
        path = self._attributes()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        saved = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        with open(path, "w", encoding="utf-8") as f:
            f.write("".join(f"{p} merge=union\n" for p in UNION_PATTERNS) + "mpvfx-swift/docs/STATUS.md merge=union\n")
        try:
            return self._merge_and_push(branch)
        finally:
            if saved is None:
                os.remove(path)
            else:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(saved)
            self._reset()

    def _merge_and_push(self, branch):
        rc, _ = self._git("merge", "--no-ff", "--no-commit", f"origin/{BASE}", check=False)
        if not self.merging():
            if rc == 0:
                return Outcome("uptodate", detail="nothing to merge")
            raise Error("git merge failed before it started")
        bad = self.unmerged()
        if rc != 0 and not bad:
            raise Error("git merge failed with no conflicted file")
        regen, manual = classify(bad)
        if manual:
            return Outcome("conflict", files=sorted(set(bad)))
        if regen:
            why = self.regenerate()
            if why:
                return Outcome("conflict", files=regen, detail=f"Generated files left alone: {why}.")
            if self.unmerged():
                return Outcome("conflict", files=self.unmerged())
        self._git("commit", "-q", "-m", f"Merge origin/{BASE} into {branch}", "-m", TRAILER)
        try:
            self._git("push", "-q", "origin", f"HEAD:refs/heads/{branch}", auth=True)
        except Error as e:
            return Outcome("conflict", files=regen or ["(merge is clean but the push was refused)"],
                           detail=f"Push refused: {e}")
        return Outcome("pushed")


# ---- the round -------------------------------------------------------------------------------------------------

def handle(gh, git, pr):
    """One pull request; returns a log line."""
    mergeable = gh.mergeable(pr.number)
    has = LABEL in pr.labels
    if mergeable is None:
        return f"#{pr.number}: mergeability still unknown, skipped"
    if mergeable:
        if label_action(has, False) == "remove":
            gh.remove_label(pr.number)
            return f"#{pr.number}: no longer conflicted, label removed"
        return f"#{pr.number}: mergeable"
    if already_commented(gh.comment_bodies(pr.number), pr.head_sha) and has:
        return f"#{pr.number}: conflicted at {pr.head_sha[:12]}, already reported"
    out = git.attempt(pr.head_ref, pr.head_sha)
    if out.kind == "pushed":
        if has:
            gh.remove_label(pr.number)
        return f"#{pr.number}: merged {BASE} into {pr.head_ref} and pushed"
    if out.kind == "uptodate":
        return f"#{pr.number}: {out.detail}"
    if label_action(has, True) == "add":
        gh.add_label(pr.number)
    if not already_commented(gh.comment_bodies(pr.number), pr.head_sha):
        gh.comment(pr.number, comment_text(pr.head_sha, out.files, out.detail))
    return f"#{pr.number}: conflicts in {', '.join(out.files)}"


def run_round(gh, git):
    log = []
    for pr in candidates(gh.open_prs()):
        try:
            log.append(handle(gh, git, pr))
        except Error as e:
            log.append(f"#{pr.number}: skipped ({e})")
        except Exception as e:   # an unexpected fault on one pull request never stops the round
            log.append(f"#{pr.number}: skipped ({type(e).__name__}: {e})")
    return log


def main():
    env = os.environ
    gh = GitHub(env["GITHUB_REPOSITORY"])
    git = Git(os.getcwd(), env.get("PUSH_TOKEN", ""))
    lines = run_round(gh, git)
    print("\n".join(lines) or "no open pull requests to check")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write("### conflicts-bot\n\n" + "\n".join(f"- {l}" for l in lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

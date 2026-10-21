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
"""workflow_lint.py [--root DIR] [--allow FILE] [--base-allow FILE]: the rules of .github/CHECKS.md, on every workflow.

Reads every .github/workflows/*.yml (and *.yaml) and reports, per workflow and job:
  unpinned-action      a `uses:` that is not pinned to a full 40-hex commit SHA (local `./` actions are exempt; a
                       `docker://` image must be pinned by `@sha256:` digest)
  no-version-comment   a pinned `uses:` without the version it stands for as a trailing comment (`# v7.0.1`)
  no-permissions       no top-level `permissions:` (the token then gets the repository default, often write)
  top-level-write      a top-level `permissions:` that grants a write scope (widen per job instead)
  no-timeout           a job without `timeout-minutes` (a job calling a reusable workflow is exempt: GitHub does not
                       allow the key there)
  no-concurrency       a workflow with neither a top-level `concurrency:` nor one on every job (a workflow that only
                       runs through `workflow_call` is exempt: it runs under its caller's group)
  persist-credentials  an `actions/checkout` step without `persist-credentials: false`
  untrusted-checkout   a workflow triggered by pull_request_target, workflow_run or issue_comment (privileged: it holds
                       the base repository's token) that checks out a ref or repository taken from the event's pull
                       request or head (github.event.pull_request.head.*, github.event.workflow_run.head_*,
                       github.head_ref, refs/pull/...) or from a step, job or env output that cannot be read here; or
                       that runs `gh pr checkout`, or git checkout/fetch/switch of such a ref, in a script
  python-isolation     a repository script started with python or python3 without both -I and -B
  workflow-env-secret  a secret or github.token in the top-level `env:`, where every job of the workflow receives it
  secrets-inherit      a reusable-workflow call with `secrets: inherit` (pass only the secrets the callee needs)
  continue-on-error    a job or step with `continue-on-error` set: a check that cannot fail checks nothing
  required-path-filter the required workflow (mpvfx-ci.yml) filters pull_request or merge_group by paths: a filtered
                       run never starts, and its required check waits forever or is skipped unseen
  gate-coverage        a job of the required workflow that its aggregate job (ci-ok) does not wait for, or an
                       aggregate job without `if: always()` (a failed need would skip it, and skipped reads as passed)

A finding can be accepted, with a reason, in the allow list (.github/ci/workflow-lint-allow.toml): one [[allow]] entry
per (rule, workflow, job), job "" for the workflow itself. The list only shrinks: an entry that matches no finding is an
error (remove it), and with --base-allow (the list on the pull request's base) an entry the base does not have is an
error too. Prints a Markdown report (for the job summary); exits 0 when every finding is allowed, 1 when one is not or
the allow list is wrong, 2 on input that cannot be read. Needs PyYAML (python3-yaml) and Python 3.11+ (tomllib).
"""
import argparse, glob, os, re, sys, tomllib

try:
    import yaml
except ImportError:   # pragma: no cover - depends on the machine
    sys.exit("workflow_lint: PyYAML is missing (Debian/Ubuntu: apt-get install python3-yaml)")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOW = os.path.join(".github", "ci", "workflow-lint-allow.toml")

RULES = {
    "unpinned-action": "every action pinned to a full commit SHA",
    "no-version-comment": "a pinned action names its version in a comment",
    "no-permissions": "top-level permissions: is set",
    "top-level-write": "top-level permissions are read-only; widen per job",
    "no-timeout": "every job has timeout-minutes",
    "no-concurrency": "every workflow has a concurrency group",
    "persist-credentials": "actions/checkout with persist-credentials: false",
    "untrusted-checkout": "privileged triggers never check out pull request or head code",
    "python-isolation": "repository scripts run with python3 -I -B",
    "workflow-env-secret": "secrets only in the jobs that need them, not in the top-level env",
    "secrets-inherit": "a reusable workflow gets only the secrets it needs, not secrets: inherit",
    "continue-on-error": "no job or step is allowed to fail silently",
    "required-path-filter": "the required workflow runs on every pull request (no paths filter)",
    "gate-coverage": "ci-ok waits for every job of the required workflow and always runs",
}
# The required workflow, its aggregate job and the jobs that run after the gate (they publish; they gate nothing).
REQUIRED = {"mpvfx-ci.yml": ("ci-ok", {"publish"})}
PRIVILEGED = {"pull_request_target", "workflow_run", "issue_comment"}
USES_LINE = re.compile(r"""^\s*(?:-\s+)?uses:\s*["']?([^\s"'#]+)["']?\s*(?:#\s*(.*))?$""")
PINNED = re.compile(r"^[\w.-]+/[\w.-]+(?:/[^@\s]+)?@[0-9a-f]{40}$")
DOCKER_PINNED = re.compile(r"^docker://[^@\s]+@sha256:[0-9a-f]{64}$")
VERSION = re.compile(r"^v?\d+(?:\.\d+)*\b")
UNTRUSTED_REF = re.compile(r"github\.event\.(?:pull_request\.head|workflow_run\.head_(?:sha|branch|commit|repository)"
                           r"|workflow_run\.pull_requests|issue\.pull_request)|github\.head_ref|refs/pull/")
INDIRECT_REF = re.compile(r"\$\{\{\s*(?:steps|needs|env|vars)\.")
GIT_CHECKOUT = re.compile(r"\bgit\s+(?:-\S+\s+)*(?:checkout|switch|fetch|pull|worktree)\b")
PY_CALL = re.compile(r"""(?<![\w./$-])python3?(?:\.\d+)?((?:\s+-[A-Za-z]+)*)\s+("[^"]*"|'[^']*'|\S+)""")
SECRET_EXPR = re.compile(r"\$\{\{[^}]*\b(?:secrets\.|github\.token\b)")


class Finding:
    def __init__(self, rule, workflow, job, line, message):
        self.rule, self.workflow, self.job, self.line, self.message = rule, workflow, job, line, message
        self.allowed = None   # the allow entry's reason, when one matches

    @property
    def key(self):
        return (self.rule, self.workflow, self.job)

    def where(self):
        return f"{self.workflow}:{self.line}" + (f" (job {self.job})" if self.job else "")


class _Map(dict):
    line = 0


class _Loader(yaml.SafeLoader):
    """SafeLoader whose mappings remember the line they start on."""


def _mapping(loader, node):
    loader.flatten_mapping(node)
    m = _Map(loader.construct_pairs(node, deep=True))
    m.line = node.start_mark.line + 1
    return m


_Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


def load(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    doc = yaml.load(text, Loader=_Loader)   # noqa: S506 - a SafeLoader subclass
    if not isinstance(doc, dict):
        raise ValueError("not a mapping at the top level")
    return text, doc


def triggers(doc):
    on = doc.get("on", doc.get(True))   # YAML 1.1 reads a bare `on` key as true
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return set(on)
    if isinstance(on, dict):
        return set(on)
    return set()


def job_of(line, jobs):
    """The id of the job whose block holds this line ("" before the first job)."""
    best = ""
    for jid, start in jobs:
        if start <= line:
            best = jid
    return best


def check_uses(name, text, job_lines, out):
    for n, raw in enumerate(text.split("\n"), 1):
        m = USES_LINE.match(raw)
        if not m:
            continue
        ref, comment, job = m.group(1), (m.group(2) or "").strip(), job_of(n, job_lines)
        if ref.startswith("./"):
            continue
        if ref.startswith("docker://"):
            if not DOCKER_PINNED.match(ref):
                out.append(Finding("unpinned-action", name, job, n, f"`{ref}` is not pinned by @sha256: digest"))
            continue
        if not PINNED.match(ref):
            out.append(Finding("unpinned-action", name, job, n, f"`{ref}` is not pinned to a 40-hex commit SHA"))
        elif not VERSION.match(comment):
            out.append(Finding("no-version-comment", name, job, n,
                               f"`{ref.split('@')[0]}` is pinned without its version as a comment (`# v1.2.3`)"))


def python_calls(script):
    """(flags, target) for each python start in a shell script that runs a file or stdin."""
    for m in PY_CALL.finditer(script):
        target = m.group(2).strip("\"'")
        if target == "-" or target.endswith(".py"):
            yield set("".join(f.lstrip("-") for f in m.group(1).split())), target


def is_checkout(step):
    return isinstance(step.get("uses"), str) and step["uses"].split("@")[0] == "actions/checkout"


def lint_workflow(path, name):
    text, doc = load(path)
    out = []
    jobs = doc.get("jobs") or {}
    if not isinstance(jobs, dict):
        raise ValueError("`jobs` is not a mapping")
    job_lines = sorted(((jid, getattr(job, "line", 0) or 0) for jid, job in jobs.items()), key=lambda j: j[1])
    check_uses(name, text, job_lines, out)
    on = triggers(doc)

    perms = doc.get("permissions", None)
    if "permissions" not in doc:
        out.append(Finding("no-permissions", name, "", 1, "no top-level permissions: (set `contents: read` or `{}`)"))
    elif perms == "write-all" or (isinstance(perms, dict) and any(v == "write" for v in perms.values())):
        scopes = "write-all" if perms == "write-all" else ", ".join(k for k, v in perms.items() if v == "write")
        out.append(Finding("top-level-write", name, "", getattr(perms, "line", 1),
                           f"top-level permissions grant write ({scopes}); widen in the jobs that need it"))

    if "concurrency" not in doc and on != {"workflow_call"}:
        bare = [jid for jid, job in jobs.items() if isinstance(job, dict) and "concurrency" not in job]
        if bare:
            out.append(Finding("no-concurrency", name, "", 1,
                               "no top-level concurrency: and jobs without their own: " + ", ".join(bare)))

    for key, value in (doc.get("env") or {}).items():
        if isinstance(value, str) and SECRET_EXPR.search(value):
            out.append(Finding("workflow-env-secret", name, "", getattr(doc.get("env"), "line", 1),
                               f"top-level env `{key}` carries a credential to every job"))

    if name in REQUIRED:
        out += gate_findings(name, doc, jobs)

    privileged = bool(on & PRIVILEGED)
    for jid, job in jobs.items():
        if not isinstance(job, dict):
            continue
        line = job.line
        if "uses" in job:
            if job.get("secrets") == "inherit":
                out.append(Finding("secrets-inherit", name, jid, line, "`secrets: inherit` passes every secret"))
        elif "timeout-minutes" not in job:
            out.append(Finding("no-timeout", name, jid, line, "no timeout-minutes (the default is 360)"))
        if job.get("continue-on-error") not in (None, False):
            out.append(Finding("continue-on-error", name, jid, line, "the job may fail without failing the run"))
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            sline, label = step.line, step.get("name") or step.get("uses") or "run step"
            with_ = step.get("with") or {}
            if is_checkout(step):
                if str(with_.get("persist-credentials", "true")).lower() != "false":
                    out.append(Finding("persist-credentials", name, jid, sline,
                                       "actions/checkout leaves the token in .git/config (set persist-credentials: false)"))
                if privileged:
                    for k in ("ref", "repository"):
                        v = str(with_.get(k, ""))
                        if UNTRUSTED_REF.search(v):
                            out.append(Finding("untrusted-checkout", name, jid, sline,
                                               f"checkout {k}: `{v}` comes from the event's pull request or head"))
                        elif INDIRECT_REF.search(v):
                            out.append(Finding("untrusted-checkout", name, jid, sline,
                                               f"checkout {k}: `{v}` is computed at run time and cannot be shown to "
                                               "be trusted"))
            if step.get("continue-on-error") not in (None, False):
                out.append(Finding("continue-on-error", name, jid, sline, f"step `{label}` may fail unseen"))
            run = step.get("run")
            if not isinstance(run, str):
                continue
            if privileged and ("gh pr checkout" in run or (GIT_CHECKOUT.search(run) and UNTRUSTED_REF.search(run))):
                out.append(Finding("untrusted-checkout", name, jid, sline,
                                   f"step `{label}` fetches or checks out pull request or head code"))
            for flags, target in python_calls(run):
                missing = "".join(f for f in "IB" if f not in flags)
                if missing:
                    out.append(Finding("python-isolation", name, jid, sline,
                                       f"python runs `{target}` without -{' -'.join(missing)}"))
    return out


def gate_findings(name, doc, jobs):
    gate, after = REQUIRED[name]
    out = []
    on = doc.get("on", doc.get(True))
    if isinstance(on, dict):
        for event in ("pull_request", "merge_group"):
            cfg = on.get(event)
            if isinstance(cfg, dict) and ({"paths", "paths-ignore"} & set(cfg)):
                out.append(Finding("required-path-filter", name, "", getattr(cfg, "line", 1),
                                   f"`{event}` has a paths filter; skip work inside the run instead (job `changes`)"))
    agg = jobs.get(gate)
    if not isinstance(agg, dict):
        return out + [Finding("gate-coverage", name, "", 1, f"no aggregate job `{gate}`")]
    needs = agg.get("needs") or []
    needs = {needs} if isinstance(needs, str) else set(needs)
    if "always()" not in str(agg.get("if", "")):
        out.append(Finding("gate-coverage", name, gate, agg.line, f"`{gate}` has no `if: always()`"))
    for jid in jobs:
        if jid != gate and jid not in after and jid not in needs:
            out.append(Finding("gate-coverage", name, gate, agg.line, f"`{gate}` does not wait for job `{jid}`"))
    return out


def read_allow(path):
    """{(rule, workflow, job): reason}, and the problems with the file."""
    if not path or not os.path.isfile(path):
        return {}, []
    with open(path, "rb") as f:
        try:
            data = tomllib.load(f)
        except tomllib.TOMLDecodeError as e:
            return {}, [f"{path}: not valid TOML: {e}"]
    entries, problems = {}, []
    for i, e in enumerate(data.get("allow", []), 1):
        key = (e.get("rule", ""), e.get("workflow", ""), e.get("job", ""))
        reason = str(e.get("reason", "")).strip()
        if key[0] not in RULES:
            problems.append(f"allow entry {i}: unknown rule `{key[0]}`")
        if not key[1]:
            problems.append(f"allow entry {i}: no workflow")
        if len(reason) < 20:
            problems.append(f"allow entry {i} ({key[0]}, {key[1]}, {key[2] or '-'}): give a reason (20+ characters)")
        if key in entries:
            problems.append(f"allow entry {i}: ({key[0]}, {key[1]}, {key[2] or '-'}) is listed twice")
        entries[key] = reason
    return entries, problems


def run(root, allow_path, base_allow_path=None):
    """(findings, allow-list problems), every finding marked allowed or not."""
    paths = sorted(glob.glob(os.path.join(root, ".github", "workflows", "*.yml")) +
                   glob.glob(os.path.join(root, ".github", "workflows", "*.yaml")))
    findings, problems = [], []
    for p in paths:
        try:
            findings += lint_workflow(p, os.path.basename(p))
        except (yaml.YAMLError, ValueError) as e:
            print(f"workflow_lint: {os.path.relpath(p, root)}: {e}", file=sys.stderr)
            raise SystemExit(2) from None
    allow, problems = read_allow(allow_path)
    used = set()
    for f in findings:
        if f.key in allow:
            f.allowed = allow[f.key]
            used.add(f.key)
    for key in sorted(set(allow) - used):
        problems.append(f"allow entry ({key[0]}, {key[1]}, {key[2] or '-'}) matches no finding: remove it "
                        "(the list only shrinks)")
    if base_allow_path:
        base, _ = read_allow(base_allow_path)
        for key in sorted(set(allow) - set(base)):
            problems.append(f"allow entry ({key[0]}, {key[1]}, {key[2] or '-'}) is new: the list only shrinks; "
                            "fix the workflow instead")
    return len(paths), findings, problems


def report(count, findings, problems):
    new = [f for f in findings if f.allowed is None]
    lines = ["## workflow-lint", "",
             f"{count} workflows, {len(findings)} findings: {len(new)} new, {len(findings) - len(new)} allowed by "
             "`.github/ci/workflow-lint-allow.toml`. Rules: `.github/CHECKS.md`.", ""]
    if problems:
        lines += ["**Allow list:**", ""] + [f"- {p}" for p in problems] + [""]
    if findings:
        lines += ["| | rule | where | finding |", "|---|---|---|---|"]
        for f in sorted(findings, key=lambda f: (f.allowed is not None, f.workflow, f.line)):
            mark = "allowed" if f.allowed is not None else "**new**"
            lines.append(f"| {mark} | {f.rule} | {f.where()} | {f.message.replace('|', '/')} |")
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--root", default=ROOT, help="repository root (default: the one holding this script)")
    ap.add_argument("--allow", help=f"allow list (default: <root>/{ALLOW})")
    ap.add_argument("--base-allow", help="the allow list on the base branch: an entry it lacks is an error")
    ap.add_argument("--list-rules", action="store_true", help="print the rules and exit")
    args = ap.parse_args(argv)
    if args.list_rules:
        for rule, text in RULES.items():
            print(f"{rule:20} {text}")
        return 0
    allow = args.allow or os.path.join(args.root, ALLOW)
    count, findings, problems = run(args.root, allow, args.base_allow)
    sys.stdout.write(report(count, findings, problems))
    return 1 if problems or any(f.allowed is None for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main())

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
"""Writes the *-source.yml workflows that OneTake-app/OneTake-actionRunners-1 calls to run some of this repository's
jobs on its own organization's runner pool, each from the workflow that runs those jobs here (SPECS below).

A generated file differs from its source in exactly these ways:
  - its only trigger is workflow_call, with required inputs source_repository and source_ref (plus the inputs a spec
    names), and it has no caller in this repository: no schedule, dispatch or push here ever runs a commit an input
    chose;
  - it keeps only the jobs its spec names, without their `if:`, their `needs:` on jobs it drops, or job-level
    permissions: every job runs with the source's read-only top-level token;
  - every checkout takes that repository and commit and keeps no token (persist-credentials: false);
  - no cache step: those runs share the runners repository's default-branch cache scope, where one pull request's run
    could otherwise plant a build cache that a later run restores;
  - no secret: any value that names one is emptied (and the file is refused if one is left);
  - each spec's own edits (its step and job patches), listed with it.

  python3 -I -B .github/ci/source_workflows.py          rewrite every generated file
  python3 -I -B .github/ci/source_workflows.py --check  fail when one is not what this script writes
"""
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
CHECKOUT = "actions/checkout@"
CACHE = re.compile(r"^actions/cache(/[a-z]+)?@")   # actions/cache@, actions/cache/restore@, actions/cache/save@
SECRET = re.compile(r"\bsecrets\s*[.\[]")          # ${{ secrets.X }} and ${{ secrets['X'] }}
UPLOAD_ARTIFACT = "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"   # v7.0.2, as every workflow pins it


def _codeql_swift(job_name, steps):
    """Never uploads: the SARIF file becomes the artifact `sarif-swift`, which the runners repository sends to this
    repository's code scanning with its App (the job here holds no security-events token)."""
    out = []
    for s in steps:
        if s.get("uses", "").startswith("github/codeql-action/analyze@"):
            s = {**s, "with": {**s.get("with", {}), "upload": "never", "output": "${{ runner.temp }}/sarif"}}
        out.append(s)
    out.append({"uses": UPLOAD_ARTIFACT, "with": {"name": "sarif-swift", "path": "${{ runner.temp }}/sarif/*.sarif",
                                                  "if-no-files-found": "error", "retention-days": 7}})
    return out


BENCH_INPUTS = {"runs": {"type": "number", "default": 5}, "only": {"type": "string", "default": ""}}
# target file: (source file, workflow name, jobs kept, extra workflow_call inputs, patch(job name, steps) -> steps[,
# jobs patch(jobs) -> jobs])
SPECS = {
    "codeql-swift-source.yml": ("codeql.yml", "codeql-swift-source", ["swift"], {}, _codeql_swift),
    # The bench-<os> artifacts stay in the calling run; bench.py records the commit it measured (git rev-parse HEAD).
    # windows stays in bench.yml: its pinned setup-swift commit has no version to name (workflow-lint allow list).
    "bench-source.yml": ("bench.yml", "bench-source", ["linux", "macos"], BENCH_INPUTS, None),
    # The Linux build variants: their guard and other cheap checks stay in the source workflows.
    "linux-no-vulkan-source.yml": ("linux-no-vulkan.yml", "linux-no-vulkan-source", ["build"], {}, None),
    "linux-optional-headers-source.yml": ("linux-optional-headers.yml", "linux-optional-headers-source", ["build"], {}, None),
}


class _Dumper(yaml.SafeDumper):
    pass


def _str(dumper, value):
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style="|" if "\n" in value else None)


_Dumper.add_representer(str, _str)


def _no_secrets(value):
    if isinstance(value, dict):
        return {k: _no_secrets(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_no_secrets(v) for v in value]
    return "" if isinstance(value, str) and SECRET.search(value) else value


def _step(step):
    uses = step.get("uses", "")
    if CACHE.match(uses):
        return None
    step = _no_secrets(dict(step))
    if uses.startswith(CHECKOUT):
        step["with"] = {**step.get("with", {}), "repository": "${{ inputs.source_repository }}",
                        "ref": "${{ inputs.source_ref }}", "persist-credentials": False}
    return step


PIN = re.compile(r"uses: (\S+@[0-9a-f]{40})\s*(#.*)$")


def _pin_comments(source, text):
    """Puts back each pinned action's `# vX.Y.Z` comment, which the YAML writer drops."""
    comments = dict(m.groups() for m in map(PIN.search, source.splitlines()) if m)
    comments.setdefault(UPLOAD_ARTIFACT, "# v7.0.2")

    def add(match):
        return f"{match.group(0)} {comments.get(match.group(1), '')}".rstrip()

    return "\n".join(re.sub(r"uses: (\S+@[0-9a-f]{40})$", add, line) for line in text.split("\n"))


def _needs(job, keep):
    """The job's `needs:` on the jobs that are kept, as a list (empty when none)."""
    needs = job.get("needs")
    return [n for n in ([needs] if isinstance(needs, str) else needs or []) if n in keep]


def _job(job, keep, patch, job_name):
    """One kept job: no `if:` or job permissions, `needs:` only on kept jobs, steps rewritten, then the spec's patch."""
    out = {k: v for k, v in job.items() if k not in ("if", "permissions", "needs")}
    needs = _needs(job, keep)
    if needs:
        out = {"needs": needs, **out}
    steps = [s for s in (_step(s) for s in out["steps"]) if s is not None]
    out["steps"] = patch(job_name, steps) if patch else steps
    return out


def _header(src_name):
    return (f"# GENERATED by .github/ci/source_workflows.py from {src_name}: do not edit; change the source and rerun it.\n"
            "# Called only by OneTake-app/OneTake-actionRunners-1 to run these jobs on a named oneTake commit on that\n"
            "# organization's runners: no caches, no secrets, no write token, no token left in the checkouts.\n")


def generate(target, source):
    src_name, name, keep, extra_inputs, patch, *more = SPECS[target]
    wf = yaml.safe_load(source)
    inputs = {**extra_inputs, "source_repository": {"type": "string", "required": True},
              "source_ref": {"type": "string", "required": True}}
    out = {"name": name, "on": {"workflow_call": {"inputs": inputs}}, "permissions": wf["permissions"]}
    if wf.get("env"):
        out["env"] = wf["env"]
    out["jobs"] = {n: _job(wf["jobs"][n], keep, patch, n) for n in keep}
    if more:
        out["jobs"] = more[0](out["jobs"])
    text = yaml.dump(out, Dumper=_Dumper, sort_keys=False, width=10**6, allow_unicode=True)
    if SECRET.search(text):
        raise ValueError(f"{target}: a secret is still referenced")
    return _header(src_name) + _pin_comments(source, text)


def main(argv):
    stale = []
    for target, spec in SPECS.items():
        with open(os.path.join(WORKFLOWS, spec[0]), encoding="utf-8") as f:
            text = generate(target, f.read())
        path = os.path.join(WORKFLOWS, target)
        if "--check" in argv:
            try:
                with open(path, encoding="utf-8") as f:
                    current = f.read()
            except FileNotFoundError:
                current = None
            if current != text:
                stale.append(target)
            continue
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    for target in stale:
        print(f"{target} is stale: run python3 -I -B .github/ci/source_workflows.py")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

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
CACHE = "actions/cache/"
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


CHECKOUT_PIN = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"   # v7.0.1, as every workflow pins it
TEST_INPUTS = {"linux_shards": {"type": "string", "default": "[]"}}
PICK = """swift package dump-package > "$RUNNER_TEMP/package.json"
python3 -I -B ../.github/ci/test-shards.py --os linux "$RUNNER_TEMP/package.json" > "$RUNNER_TEMP/linux.json"
python3 -I -B - <<'PY'
import json, os
out = {}
for name in ("linux",):
    want = json.loads(os.environ[name.upper()])
    with open(os.path.join(os.environ["RUNNER_TEMP"], f"{name}.json")) as f:
        shards = json.load(f)
    known = {s["shard"] for s in shards}
    if not isinstance(want, list) or not all(isinstance(n, str) and n in known for n in want):
        raise SystemExit(f"::error::{name}_shards {want!r} names a shard test-shards.py does not have")
    out[name] = [s for s in shards if s["shard"] in want]
    print(f"{name}: {[s['shard'] for s in out[name]]}")
with open(os.environ["GITHUB_OUTPUT"], "a") as f:
    f.write(f"linux={json.dumps(out['linux'])}\\n")
PY
"""


def _test_steps(job_name, steps):
    """No pass is recorded there (it would need a cache); mpvfx-ci's remote-shards job records it here instead."""
    return [s for s in steps if not s.get("name", "").startswith("Record the pass")]


def _test_jobs(jobs):
    """A plan job of its own: the shard objects (filter, skip) for the names asked for, from test-shards.py on that
    commit, so the payload carries only names. The test job runs that list, when it is not empty."""
    plan = {"runs-on": "ubuntu-24.04", "timeout-minutes": 10,
            "outputs": {"linux_shards": "${{ steps.pick.outputs.linux }}"},
            "defaults": {"run": {"shell": "bash", "working-directory": "mpvfx-swift"}},
            "steps": [_step({"uses": CHECKOUT_PIN}),
                      {"name": "The shards asked for", "id": "pick",
                       "env": {"LINUX": "${{ inputs.linux_shards }}"},
                       "run": PICK}]}
    out = {"plan": plan}
    for name, job in jobs.items():
        os_name = name.split("-")[0]
        out[name] = {"needs": "plan", "if": f"needs.plan.outputs.{os_name}_shards != '[]'", **job}
    return out


# target file: (source file, workflow name, jobs kept, extra workflow_call inputs, patch(job name, steps) -> steps[,
# jobs patch(jobs) -> jobs])
SPECS = {
    "codeql-swift-source.yml": ("codeql.yml", "codeql-swift-source", ["swift"], {}, _codeql_swift),
    # The Linux test shards marked `runners` in test-shards.py (mpvfx-ci.yml job remote-shards). Not windows-test: its
    # setup-swift pin has no version to name (workflow-lint allow list), so Windows shards stay in mpvfx-ci.
    "mpvfx-ci-tests-source.yml": ("mpvfx-ci.yml", "mpvfx-ci-tests-source", ["linux-test"], TEST_INPUTS,
                                  _test_steps, _test_jobs),
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
    return "" if isinstance(value, str) and "secrets." in value else value


def _step(step):
    uses = step.get("uses", "")
    if uses.startswith(CACHE):
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
    comments.setdefault(CHECKOUT_PIN, "# v7.0.1")

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
    if "secrets." in text:
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

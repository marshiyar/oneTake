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
"""Tests for workflow_lint.py: each rule fires on the pattern it names and stays quiet on the compliant form; the allow
list accepts findings with reasons, rejects stale and new entries; the repository's own workflows pass."""
import contextlib, importlib.util, io, os, tempfile, textwrap, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("workflow_lint", os.path.join(HERE, "workflow_lint.py"))
wl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wl)

SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"
CHECKOUT = f"actions/checkout@{SHA} # v7.0.1"

GOOD = f"""\
name: good
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: good-${{{{ github.ref }}}}
  cancel-in-progress: true
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: {CHECKOUT}
        with:
          persist-credentials: false
      - uses: ./.github/actions/local
      - run: python3 -I -B .github/ci/thing.py --flag
      - run: |
          python3 -IB - "$RUNNER_TEMP/x.json" <<'PY'
          print(1)
          PY
      - run: python3 -c 'print(1)'
  call:
    uses: ./.github/workflows/other.yml
    secrets:
      TOKEN: ${{{{ secrets.TOKEN }}}}
"""


def lint(text, name="w.yml"):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, name)
        with open(p, "w") as f:
            f.write(textwrap.dedent(text))
        return wl.lint_workflow(p, name)


def rules(text):
    return sorted(f.rule for f in lint(text))


def swap(old, new, text=GOOD):
    assert old in text, old
    return text.replace(old, new, 1)


class Rules(unittest.TestCase):
    def test_a_compliant_workflow_has_no_finding(self):
        self.assertEqual(lint(GOOD), [])

    def test_unpinned_actions(self):
        self.assertEqual(rules(swap(CHECKOUT, "actions/checkout@v7")), ["unpinned-action"])
        self.assertEqual(rules(swap(CHECKOUT, "actions/checkout@3d3c42e")), ["unpinned-action"])
        self.assertEqual(rules(swap(CHECKOUT, "actions/checkout@main # v7")), ["unpinned-action"])
        self.assertEqual(rules(swap("./.github/actions/local", "docker://alpine:3.20")), ["unpinned-action"])
        self.assertEqual(rules(swap("./.github/actions/local", "docker://alpine@sha256:" + "a" * 64)), [])
        self.assertEqual(rules(swap("./.github/workflows/other.yml", "o/r/.github/workflows/x.yml@v1")),
                         ["unpinned-action"])

    def test_a_pin_needs_its_version_as_a_comment(self):
        self.assertEqual(rules(swap(CHECKOUT, f"actions/checkout@{SHA}")), ["no-version-comment"])
        self.assertEqual(rules(swap(CHECKOUT, f"actions/checkout@{SHA} # latest")), ["no-version-comment"])
        self.assertEqual(rules(swap(CHECKOUT, f"'actions/checkout@{SHA}' # 7.0.1")), [])

    def test_permissions(self):
        self.assertEqual(rules(swap("permissions:\n  contents: read\nconcurrency", "concurrency")), ["no-permissions"])
        self.assertEqual(rules(swap("permissions:\n  contents: read\nconcurrency",
                                    "permissions:\n  contents: write\nconcurrency")), ["top-level-write"])
        self.assertEqual(rules(swap("permissions:\n  contents: read\nconcurrency", "permissions: write-all\nconcurrency")),
                         ["top-level-write"])
        self.assertEqual(rules(swap("permissions:\n  contents: read\nconcurrency", "permissions: {}\nconcurrency")), [])
        self.assertEqual(rules(swap("permissions:\n  contents: read\nconcurrency", "permissions: read-all\nconcurrency")),
                         [])

    def test_every_job_has_a_timeout_except_a_reusable_call(self):
        found = lint(swap("    timeout-minutes: 5\n", ""))
        self.assertEqual([(f.rule, f.job) for f in found], [("no-timeout", "build")])

    def test_concurrency_at_the_top_or_on_every_job(self):
        top = "concurrency:\n  group: good-${{ github.ref }}\n  cancel-in-progress: true\n"
        self.assertEqual(rules(swap(top, "")), ["no-concurrency"])
        each = swap(top, "").replace("    runs-on: ubuntu-24.04\n", "    runs-on: ubuntu-24.04\n    concurrency: b\n")
        each = each.replace("    uses: ./.github/workflows/other.yml\n",
                            "    uses: ./.github/workflows/other.yml\n    concurrency: c\n")
        self.assertEqual(rules(each), [])
        called = swap(top, "").replace("on:\n  pull_request:\n  push:\n    branches: [main]\n", "on:\n  workflow_call:\n")
        self.assertEqual(rules(called), [])

    def test_checkout_without_persist_credentials_false(self):
        self.assertEqual(rules(swap("          persist-credentials: false\n", "          fetch-depth: 0\n")),
                         ["persist-credentials"])
        self.assertEqual(rules(swap("        with:\n          persist-credentials: false\n", "")),
                         ["persist-credentials"])
        self.assertEqual(rules(swap("persist-credentials: false", "persist-credentials: 'false'")), [])

    def test_python_without_isolation(self):
        self.assertEqual(rules(swap("python3 -I -B .github", "python3 .github")), ["python-isolation"])
        self.assertEqual(rules(swap("python3 -I -B .github", "python3 -I .github")), ["python-isolation"])
        self.assertEqual(rules(swap("python3 -I -B .github", 'python -B -u "$RUNNER_TEMP/x.py"')), ["python-isolation"])
        self.assertEqual(rules(swap("python3 -IB -", "python3 -")), ["python-isolation"])
        self.assertEqual(rules(swap("python3 -I -B .github", "python3 -m pip install x; python3 -I -B .github")), [])

    def test_secrets_stay_in_the_jobs(self):
        env = "env:\n  TOKEN: ${{ secrets.TOKEN }}\njobs:"
        self.assertEqual(rules(swap("jobs:", env)), ["workflow-env-secret"])
        self.assertEqual(rules(swap("jobs:", "env:\n  GH_TOKEN: ${{ github.token }}\njobs:")), ["workflow-env-secret"])
        self.assertEqual(rules(swap("jobs:", "env:\n  RUN: ${{ github.event.workflow_run.id }}\njobs:")), [])
        self.assertEqual(rules(swap("    secrets:\n      TOKEN: ${{ secrets.TOKEN }}\n", "    secrets: inherit\n")),
                         ["secrets-inherit"])

    def test_continue_on_error(self):
        self.assertEqual(rules(swap("    timeout-minutes: 5\n", "    timeout-minutes: 5\n    continue-on-error: true\n")),
                         ["continue-on-error"])
        self.assertEqual(rules(swap("      - run: python3 -c", "      - continue-on-error: true\n        run: python3 -c")),
                         ["continue-on-error"])
        self.assertEqual(rules(swap("    timeout-minutes: 5\n", "    timeout-minutes: 5\n    continue-on-error: false\n")),
                         [])


GATED = """\
name: mpvfx-ci
on:
  pull_request:
    branches: [main]
  merge_group:
  push:
    branches: [main]
    paths-ignore: ['**/*.md']
permissions:
  contents: read
concurrency: ci
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - run: true
  ci-ok:
    needs: [build]
    if: always()
    runs-on: ubuntu-24.04
    timeout-minutes: 2
    steps:
      - run: true
  publish:
    needs: [build]
    runs-on: ubuntu-24.04
    timeout-minutes: 2
    steps:
      - run: true
"""


class RequiredWorkflow(unittest.TestCase):
    def gate(self, text):
        return sorted((f.rule, f.message) for f in lint(text, "mpvfx-ci.yml"))

    def test_the_gate_waits_for_every_job_and_always_runs(self):
        self.assertEqual(self.gate(GATED), [])
        extra = GATED.replace("  ci-ok:\n", "  lint:\n    runs-on: x\n    timeout-minutes: 1\n    steps:\n      - run: true\n  ci-ok:\n")
        self.assertEqual(self.gate(extra), [("gate-coverage", "`ci-ok` does not wait for job `lint`")])
        self.assertEqual(self.gate(GATED.replace("    if: always()\n", "")), [("gate-coverage", "`ci-ok` has no `if: always()`")])
        self.assertEqual(lint(extra, "other.yml"), [])

    def test_no_paths_filter_on_pull_requests_or_the_merge_queue(self):
        pr = GATED.replace("    branches: [main]\n  merge_group:", "    branches: [main]\n    paths: ['src/**']\n  merge_group:")
        self.assertEqual([r for r, _ in self.gate(pr)], ["required-path-filter"])
        mq = GATED.replace("  merge_group:\n", "  merge_group:\n    paths-ignore: ['docs/**']\n")
        self.assertEqual([r for r, _ in self.gate(mq)], ["required-path-filter"])



PRIVILEGED = f"""\
name: p
on:
  pull_request_target:
  workflow_run:
    workflows: [ci]
    types: [completed]
permissions: {{}}
concurrency: p
jobs:
  j:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - uses: {CHECKOUT}
        with:
          ref: main
          persist-credentials: false
      - run: echo "$HEAD_SHA"
        env:
          HEAD_SHA: ${{{{ github.event.pull_request.head.sha }}}}
"""


class UntrustedCheckout(unittest.TestCase):
    def test_main_or_the_default_ref_is_fine(self):
        self.assertEqual(lint(PRIVILEGED), [])
        self.assertEqual(lint(PRIVILEGED.replace("          ref: main\n", "")), [])

    def test_a_ref_from_the_pull_request_or_the_head_is_refused(self):
        for ref in ("${{ github.event.pull_request.head.sha }}", "${{ github.event.pull_request.head.ref }}",
                    "${{ github.event.workflow_run.head_sha }}", "${{ github.event.workflow_run.head_branch }}",
                    "${{ github.head_ref }}", "refs/pull/${{ github.event.number }}/merge"):
            with self.subTest(ref=ref):
                self.assertEqual(rules(PRIVILEGED.replace("ref: main", f"ref: {ref}")), ["untrusted-checkout"])
        repo = PRIVILEGED.replace("ref: main", "repository: ${{ github.event.pull_request.head.repo.full_name }}")
        self.assertEqual(rules(repo), ["untrusted-checkout"])

    def test_a_ref_computed_at_run_time_is_refused(self):
        self.assertEqual(rules(PRIVILEGED.replace("ref: main", "ref: ${{ steps.pr.outputs.sha }}")),
                         ["untrusted-checkout"])

    def test_scripts_that_fetch_the_pull_request(self):
        fetch = PRIVILEGED.replace('echo "$HEAD_SHA"', 'git fetch origin ${{ github.event.pull_request.head.sha }}')
        self.assertEqual(rules(fetch), ["untrusted-checkout"])
        self.assertEqual(rules(PRIVILEGED.replace('echo "$HEAD_SHA"', "gh pr checkout 5")), ["untrusted-checkout"])
        self.assertEqual(rules(PRIVILEGED.replace('echo "$HEAD_SHA"', "git fetch origin main")), [])

    def test_issue_comment_is_privileged_too(self):
        text = PRIVILEGED.replace("  pull_request_target:\n  workflow_run:\n    workflows: [ci]\n    types: [completed]\n",
                                  "  issue_comment:\n    types: [created]\n")
        self.assertEqual(rules(text.replace("ref: main", "ref: ${{ steps.pr.outputs.sha }}")), ["untrusted-checkout"])

    def test_an_unprivileged_trigger_may_check_out_the_head(self):
        text = PRIVILEGED.replace("  pull_request_target:\n  workflow_run:\n    workflows: [ci]\n    types: [completed]\n",
                                  "  pull_request:\n")
        self.assertEqual(rules(text.replace("ref: main", "ref: ${{ github.event.pull_request.head.sha }}")), [])


class AllowList(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = self.dir.name
        os.makedirs(os.path.join(self.root, ".github", "workflows"))
        with open(os.path.join(self.root, ".github", "workflows", "w.yml"), "w") as f:
            f.write(swap("    timeout-minutes: 5\n", ""))

    def tearDown(self):
        self.dir.cleanup()

    def write(self, name, entries):
        path = os.path.join(self.root, name)
        with open(path, "w") as f:
            for rule, wf, job, reason in entries:
                f.write(f'[[allow]]\nrule = "{rule}"\nworkflow = "{wf}"\njob = "{job}"\nreason = "{reason}"\n\n')
        return path

    def main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = wl.main(["--root", self.root, *args])
        return code, out.getvalue()

    def test_an_unlisted_finding_fails(self):
        code, out = self.main()
        self.assertEqual(code, 1)
        self.assertIn("1 new", out)
        self.assertIn("| **new** | no-timeout | w.yml:", out)

    def test_a_listed_finding_with_a_reason_passes(self):
        allow = self.write("allow.toml", [("no-timeout", "w.yml", "build", "a reason that is long enough")])
        code, out = self.main("--allow", allow)
        self.assertEqual(code, 0, out)
        self.assertIn("0 new, 1 allowed", out)

    def test_a_short_reason_an_unknown_rule_or_a_duplicate_fails(self):
        for entries, needle in (([("no-timeout", "w.yml", "build", "because")], "give a reason"),
                                ([("no-timeout", "w.yml", "build", "a reason that is long enough"),
                                  ("no-such-rule", "w.yml", "build", "a reason that is long enough")], "unknown rule"),
                                ([("no-timeout", "w.yml", "build", "a reason that is long enough")] * 2, "twice")):
            with self.subTest(needle=needle):
                code, out = self.main("--allow", self.write("allow.toml", entries))
                self.assertEqual(code, 1)
                self.assertIn(needle, out)

    def test_a_stale_entry_fails(self):
        allow = self.write("allow.toml", [("no-timeout", "w.yml", "build", "a reason that is long enough"),
                                          ("persist-credentials", "w.yml", "build", "a reason that is long enough")])
        code, out = self.main("--allow", allow)
        self.assertEqual(code, 1)
        self.assertIn("matches no finding", out)

    def test_the_list_only_shrinks_against_the_base(self):
        allow = self.write("allow.toml", [("no-timeout", "w.yml", "build", "a reason that is long enough")])
        base = self.write("base.toml", [])
        code, out = self.main("--allow", allow, "--base-allow", base)
        self.assertEqual(code, 1)
        self.assertIn("is new", out)
        same = self.write("same.toml", [("no-timeout", "w.yml", "build", "another reason, long enough"),
                                        ("persist-credentials", "x.yml", "", "an entry the head has removed")])
        self.assertEqual(self.main("--allow", allow, "--base-allow", same)[0], 0)

    def test_a_broken_workflow_stops_the_run(self):
        with open(os.path.join(self.root, ".github", "workflows", "bad.yml"), "w") as f:
            f.write("jobs: [\n")
        err = io.StringIO()
        with self.assertRaises(SystemExit) as e, contextlib.redirect_stderr(err):
            self.main()
        self.assertEqual(e.exception.code, 2)
        self.assertIn("bad.yml", err.getvalue())


class Repository(unittest.TestCase):
    def test_this_repositorys_workflows_pass_with_its_allow_list(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = wl.main([])
        self.assertEqual(code, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()

# Automated checks

What runs on this repository, what a red result means, and the rules every check follows. `main` changes only through
a pull request, and it needs two things: the aggregate check **`ci-ok`** green, and one approval. `ci-ok` is the only
required check. Everything else is advisory: it reports on the pull request, but it does not block the merge on its
own. Reviewers still read advisory results, and a red one needs an answer before approval.

To re-run a failed run: open it from the pull request's Checks tab and use **Re-run failed jobs**, or run
`gh run rerun <run id> --failed`. A run started by `workflow_run` (strip-check, sentinel's installer jobs, bench after
CI, agentbot) re-runs the same way from its own run page. The flake policy below limits how often you may re-run.

## Every workflow and job

Required means the job is one of the jobs `ci-ok` waits for (`needs:` in `.github/workflows/mpvfx-ci.yml`). Jobs that
a documentation-only pull request skips on purpose count as passed.

| Workflow / job | Trigger | Required? | A failure means | Fix or re-run |
| --- | --- | --- | --- | --- |
| **mpvfx-ci** / `changes` | PR into main, push to main, merge queue, nightly 06:17 UTC, v* tag, dispatch | required | The changed-file list could not be read (API error) | Re-run once. A PR whose files are all Markdown, `mpvfx-swift/docs/` or the licence files skips everything below |
| mpvfx-ci / `plan` | as above, when code changed | required | Test shard keys could not be computed (`.github/ci/test-shards.py`, `swift package dump-package`) | Run `swift package dump-package` in `mpvfx-swift/`; a manifest error shows there |
| mpvfx-ci / `checks` | as above | required | `scripts/test_fetch_binaries.py` failed, or a source file lacks its copyright block | `python3 mpvfx-swift/scripts/copyright.py --fix`, commit |
| mpvfx-ci / `linux` | as above | required | Release build (warnings are errors), generated shaders out of date, `.deb` packaging, or the install + launch smoke under Xvfb failed | Reproduce with `sh mpvfx-swift/scripts/check.sh`; shaders: `python3 -I -B mpvfx-swift/scripts/gpu/gen-compute-shaders.py`; the smoke snapshot is in the `linux` artifact |
| mpvfx-ci / `linux test (<shard>)` | shards with no pass recorded for their inputs | required | A test failed in that shard (library, audio-presets, audio-live, rest) | Read the Test counts step, or agentbot's digest comment; reproduce with `swift test --filter <name>` |
| mpvfx-ci / `windows` | as above | required | Windows release build, zip or `setup.exe` packaging, or install + launch + uninstall smoke failed | The `windows` artifact holds the zip, installer and smoke snapshot |
| mpvfx-ci / `windows test (<shard>)` | as above | required | A Windows test failed | as linux test |
| mpvfx-ci / `macos` → **mpvfx-macos** `plan`, `test (<shard>)`, `package` | called by mpvfx-ci; also dispatch | required | macOS build, Metal shader compile, tests, disk image, signature check or launch smoke failed | The `macos` artifact holds the disk image and smoke snapshot; a hung launch prints thread stacks in the log |
| mpvfx-ci / **`ci-ok`** | always, after the jobs above | **the required check** | One of the jobs above ended failure or cancelled | Fix that job; `ci-ok` passes when every job passed or was skipped on purpose |
| mpvfx-ci / `publish` | main and v* tags only, every platform green | not a check (runs after the gate) | A release could not be created (`.github/ci/publish.sh`) | Re-run the job; nothing is published from pull requests |
| **workflow-lint** / `lint` | every PR into main, push to main, dispatch | advisory (new, 2026-10-21) | A workflow breaks a rule below, or `.github/ci/workflow-lint-allow.toml` grew or has a stale entry | `python3 -I -B .github/ci/workflow_lint.py` prints the table that is also in the job summary; fix the workflow, or remove the entry it fixed |
| **sentinel** / `repo` | every PR, push to main, dispatch | advisory | The repository holds something a video editor has no business doing (network, process spawning, credential-shaped literals, unpinned actions, workflow injection, ...) | `python3 -I -B .github/ci/sentinel.py repo`; a justified exception goes in `.github/sentinel.toml` with its reason |
| sentinel / `installers`, `linux`, `windows`, `macos` | after each mpvfx-ci run that built installers; dispatch with a run id | advisory | A shipped binary imports a symbol that is forbidden, or new since the baseline | If the import is wanted, commit the run's `sentinel-imports-<os>` lists into `.github/sentinel-baseline/` in a PR that says why |
| **strip-check** / `linux`, `windows`, `macos` | after each successful mpvfx-ci run; dispatch with a run id | advisory (it judges what was built, after the merge; a red result is fixed before the next release) | A shipped binary carries symbols or debug data | Fix the strip step of that platform's packaging; re-run with Run workflow and the run id |
| **codeql** / `scripts-and-workflows (python, actions)`, `swift` | PR and push to main (not docs-only), weekly, dispatch | advisory | Code scanning found a new alert, or the Swift build under the tracer failed | Security > Code scanning lists the alert; fix it or dismiss it there with a reason |
| **scorecard** / `analysis` | push to main, weekly, dispatch | advisory | The OpenSSF Scorecard run failed (the score itself never fails it) | Re-run; the score is under Security > Code scanning |
| **bench** / `linux`, `windows`, `macos` | after green mpvfx-ci on main, PRs that touch performance code, Sunday, dispatch | advisory | A benchmark crashed or did not produce numbers (budgets are not enforced yet: #96) | The `bench-<os>` artifact holds every sample; agentbot compares a PR with main |
| **agentbot** / `digest`, `flakes`, `shots`, `bench` | after mpvfx-ci or bench completes | advisory (bot) | A bot could not post its comment or update the Flaky tests issue | Re-run; it never checks out or runs PR code |
| **codex-apply** / `apply` | a comment by the Codex app holding a diff, on a PR from this repository | not a check (bot) | The patch was refused (`.github/ci/codex_patch.py`) or did not apply to the head | The comment it posts says which; ask Codex for a diff against the current head |
| **merge-train** / `record`, `train` | every 15 minutes, the `queue` label, closed train PRs, each completed mpvfx-ci pull request run | not a check (bot) | A round of the train (with its autoqueue step, which labels ready PRs `queue`) could not finish | See CONTRIBUTING.md "Landing pull requests"; it continues on the next round. Label a PR `hold` to keep it out of the queue |
| pre-commit.ci | every PR (outside GitHub Actions; `.pre-commit-config.yaml`) | advisory | A file-hygiene hook, ruff, actionlint or the copyright check failed | `pre-commit run --all-files` |
| Codex review (`chatgpt-codex-connector[bot]`) | every PR | advisory (review comments) | A P0 or P1 finding is open | Fix it or answer the thread; no approval while one is unanswered |

### In review (not on main yet)

| Workflow | Pull request | What it will check | Planned status |
| --- | --- | --- | --- |
| `linux-optional-headers.yml` | #99 | The Linux build without the Vulkan and PulseAudio headers (#78); #111 asks to make it required | advisory |
| `doc-refs.yml` | #99 | Every path, link and #n reference in tracked Markdown exists | advisory |
| `quality-ratchets.yml`, `pr-hygiene.yml` | [#114](https://github.com/marshiyar/oneTake/pull/114) | A crash-construct ratchet (count may only go down) and an advisory PR hygiene report | advisory |
| UI/UX checks (branch `ci/ui-quality-checks`) | in progress on 2026-10-21 | UI quality checks | advisory |

When one of these lands, its row moves into the table above in the same pull request.

## Rules for automated checks

Every workflow follows these rules. *Enforced* names the `workflow_lint.py` rule (`.github/ci/workflow_lint.py`, run
by workflow-lint) that fails when the rule is broken. Findings that exist today are listed, each with its reason, in
`.github/ci/workflow-lint-allow.toml`. That list only shrinks: see rule 9.

1. **Pin every action to a full commit SHA, with the version as a comment.** For example:
   `uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`. A tag can move; a SHA cannot. Local
   `./` actions are exempt. Dependabot moves the pins once a week (`.github/dependabot.yml`).
   *Enforced:* `unpinned-action`, `no-version-comment`.
2. **Least privilege.** Set `permissions:` at the top of the workflow, read-only (`contents: read`, or `{}`). Widen it
   only in the job that needs more, and only by the scopes that job uses, each with a comment saying why.
   *Enforced:* `no-permissions`, `top-level-write`.
3. **`pull_request_target`, `workflow_run` and `issue_comment` never check out or run pull request code.** These
   triggers run with the base repository's token and secrets. Check out the default branch (no `ref:`, or
   `ref: main`), and read what you need about the pull request through the API. Never check out a ref taken from
   `github.event.pull_request.head`, `github.event.workflow_run.head_sha` or `head_branch`, or `refs/pull/`.
   *Enforced:* `untrusted-checkout`. It also flags a checkout ref computed at run time, which a linter cannot show to
   be safe. The linter cannot follow a ref passed through an environment variable into a script, so reviewers check
   that case.
4. **`persist-credentials: false` on every `actions/checkout`.** Without it, the job's token stays in `.git/config`
   next to whatever the job runs. A job that pushes authenticates only the push command.
   *Enforced:* `persist-credentials`.
5. **Every job has `timeout-minutes`, and every workflow has `concurrency:`.** A hung job otherwise holds a runner for
   six hours. Without a group, runs pile up or race on shared state (the Flaky tests issue, caches, releases). Use
   `cancel-in-progress: true` for checks of a ref, and `false` for anything that writes.
   *Enforced:* `no-timeout`, `no-concurrency`.
6. **Run repository scripts with `python3 -I -B`.** `-I` ignores `PYTHONPATH`, user site-packages and the current
   folder, so a file planted in the tree cannot shadow a module. `-B` writes no `.pyc` files into the checkout.
   *Enforced:* `python-isolation`.
7. **Secrets only in the jobs that need them.** Pass a secret as a step's `env:`, never in the top-level `env:`. Pass
   a reusable workflow the named secrets it reads, not `secrets: inherit`. Never pass secrets to a pull request run
   from a fork. Secrets live in the repository's secret store, never in YAML or logs; `::add-mask::` anything derived
   from one.
   *Enforced:* `workflow-env-secret`, `secrets-inherit`.
8. **A new check starts advisory.** Add it as its own workflow, outside `ci-ok`. When it has been green on main for
   two weeks (`gh run list --workflow <file> --branch main --limit 50` shows no failure that was the check's own
   fault), a pull request moves it into `.github/workflows/mpvfx-ci.yml` as a job that `ci-ok` waits for. That pull
   request links the run list as evidence. A check is never made required by a branch-protection setting alone:
   `ci-ok` stays the only required check.
   *Enforced in part:* `gate-coverage` fails when a job in the required workflow is not one `ci-ok` waits for, or
   when `ci-ok`'s condition is anything but exactly `if: always()`.
9. **Baselines and allow lists only shrink.** A count-based baseline (such as the crash-construct ratchet in review)
   may go down in any pull request and never goes up. `.github/ci/workflow-lint-allow.toml` and `.github/sentinel.toml`
   entries carry a reason each. The pull request that fixes a finding removes its entry. A new exception is a design
   decision: argue it in the pull request, and never add one just to turn a check green. Sentinel's import baselines
   are records of what ships, not budgets: they change only in a pull request that says why each new import is
   wanted.
   *Enforced:* workflow-lint fails on an allow entry that matches nothing or fewer findings than its `count`, on
   more findings than the count, and, on a pull request, on an entry that the base branch's list does not have or
   has with a lower count.
10. **Flake policy: one re-run, then it is real.** A failed job may be re-run once. If it fails again, treat it as a
    real failure and fix it, or open an issue and fix the test. When a re-run passes, agentbot's `flakes` job records
    what failed before in the issue **Flaky tests**, with counts. A test that shows up there twice gets an issue of
    its own and is fixed. Flakiness in a required check blocks the release until then, because a check people learn
    to re-run stops being read.
11. **Never skip or weaken a check to land a pull request.** Do not delete a test, mark it skipped, lower a threshold,
    edit an expected value, add `continue-on-error`, or add an allow entry to make a pull request green. If a check is
    wrong, fix the check in its own pull request, with the reason.
    *Enforced in part:* `continue-on-error`, and the shrink rule above.
12. **Path filters must not hide failures from required checks.** The required workflow has no `paths:` or
    `paths-ignore:` on `pull_request` or `merge_group`. A run that never starts leaves `ci-ok` pending forever, or
    lets a change through unseen. To skip work for some files, decide inside the run (the `changes` job), log the
    decision, and let `ci-ok` see the skipped jobs. Advisory workflows may use path filters to save runners.
    *Enforced:* `required-path-filter` (on `.github/workflows/mpvfx-ci.yml`).
13. **Job summaries over log digging.** A check writes what failed, and how to reproduce it, to
    `$GITHUB_STEP_SUMMARY`, as sentinel, strip-check, bench and workflow-lint do. Nobody should have to search a
    log for the failing line. agentbot's digest comment puts the lines that name each failure on the pull request.
    *Not enforced mechanically;* reviewers check new workflows for it.

Run the linter locally before you push a workflow change:

```sh
python3 -I -B .github/ci/test_workflow_lint.py
python3 -I -B .github/ci/workflow_lint.py        # exit 0: every finding is allowed; the table lists them
```

It needs PyYAML (`python3-yaml` on Debian and Ubuntu; `pip install pyyaml` elsewhere). actionlint, run by
pre-commit.ci, checks syntax and expressions; workflow-lint checks the rules above.

<!-- markdownlint-disable-file MD043 -- the required-headings rule has no heading list configured, so any heading fails it -->

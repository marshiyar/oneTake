# Contributing

Thanks for helping. A few rules keep the history readable and the project releasable.

## Pull requests

1. Branch from `main`; open a pull request into `main`.
2. Before pushing, run `sh mpvfx-swift/scripts/check.sh` (it fetches the engine libraries, builds, runs the tests and
   checks copyright blocks).
3. `ci-ok` is the required check. Documentation-only pull requests skip the build and tests.
4. No approving review is required. Pull requests are squash merged into `main`, and auto-merge lands them once
   `ci-ok` passes.
5. Keep a pull request to one change. Say what changed and why in the description, in plain words a user of the
   app would understand where possible.

Every check, what its failure means, how to fix or re-run it, and the rules for adding one: [.github/CHECKS.md](.github/CHECKS.md).

## Landing pull requests

CI is slow, so pull requests can land in batches instead of one at a time:

1. When a pull request is ready, the maintainer adds the label `queue`. The bot notes which commit was queued;
   pushing new commits afterwards takes the pull request out of the queue (add the label again when ready).
2. Every few minutes the merge train takes up to eight queued pull requests, merges them onto `main` in the order they
   were queued, and opens one pull request for the batch (`Merge train: #a, #b, #c`). CI runs once for the whole batch.
3. If CI passes, the batch lands as one commit, and each pull request in it is closed with a comment
   saying where it landed.
4. If CI fails, the batch is split in half and each half is tried in turn, until the pull request that breaks the
   build is found. That one leaves the queue with the label `train-failed` and a comment linking the failed run; fix it
   and add `queue` again.

A pull request that conflicts with `main` or with another one in the batch is left out of that batch with a comment
and stays queued; update it from `main`. A pull request that changes workflow files is landed on its own.

## Commits

- Write the subject as a short sentence about the change ("Keep the playhead in view while scrubbing"), and use the
  body for the why.
- Every source file starts with the copyright block that `python3 mpvfx-swift/scripts/copyright.py --fix` writes.
- By contributing you agree that your contribution is licensed as MIT OR Apache-2.0, like the rest of the app
  ([LICENSE](LICENSE)).

## The engines

The media and keyframe engines are proprietary libraries, pinned in `mpvfx-swift/binaries.lock`; their source is not
here. Changes to how the app calls them belong in the app's adapters (`mpvfx-swift/Sources/OneTakeMedia`,
`mpvfx-swift/Sources/OneTakeKeyframes`). A newer engine release is adopted by a pull request that runs
`python3 scripts/fetch-binaries.py --update <component> <version>` in `mpvfx-swift/` and commits the new lock.

## Maintainer tooling

Maintainers may check out private session tooling beside this repository; the Claude Code session-start hook renders
it in when present (into git-ignored paths) and otherwise does nothing. Nothing in it is needed to build, test or
contribute.

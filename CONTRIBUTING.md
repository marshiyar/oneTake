# Contributing

Thanks for helping. A few rules keep the history readable and the project releasable.

## Pull requests

1. Branch from `main`; open a pull request into `main`.
2. Before pushing, run `sh mpvfx-swift/scripts/check.sh` from the repository root (it fetches the engine libraries,
   runs the fetch-script tests, checks copyright blocks and the generated GPU shaders, then builds and tests with
   warnings as errors). `sh mpvfx-swift/scripts/check.sh --fast` skips the build and tests;
   `sh mpvfx-swift/scripts/doctor.sh` names anything a full run still needs.
3. CI runs the same checks on Linux and Windows ([ci.yml](.github/workflows/ci.yml)). macOS runs them locally.
4. `main` takes changes through the maintainer's merge system once they build and pass.
5. Keep a pull request to one change. Say what changed and why in the description, in plain words a user of the
   app would understand where possible.

Keep the docs you touch in step with the code in the same pull request: [STATUS.md](mpvfx-swift/docs/STATUS.md) for
what works now, [FEATURES.md](mpvfx-swift/docs/FEATURES.md) for the full inventory, and
[CHANGELOG.md](mpvfx-swift/CHANGELOG.md) under Unreleased for anything a user would notice.

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

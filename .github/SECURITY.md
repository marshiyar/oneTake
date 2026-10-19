# Security

## Reporting

Report a vulnerability privately through GitHub: **Security › Report a vulnerability** on this repository (private
vulnerability reporting), not in a public issue. Include the installer or commit, the platform, and steps to
reproduce. You will get an acknowledgement, and a fix or an explanation, in the open once it is safe to publish.

## What is checked on every change

- **`mpvfx-ci`**: builds, tests, packages and install-smokes the app on Linux, Windows and macOS; the installed app
  runs with the build tree hidden, so nothing it ships can depend on the build machine.
- **`codeql`**: GitHub code scanning on the Swift app, the Python scripts and the workflow files.
- **`sentinel`**: this project's own check of what a video editor has no business doing, in the repository (network,
  process spawning, dynamic loading, input or screen capture, persistence, privilege, anti-debugging, remote code,
  credential-shaped literals, Trojan Source characters, obfuscated literals, workflow injection and unpinned actions,
  code hidden in data files) and in the shipped installers (every binary's imports against forbidden sets and the
  recorded baseline, so a new import never ships unnoticed). Allow list with reasons: `.github/sentinel.toml`.
- **`strip-check`**: every shipped binary is stripped.
- **Dependabot**: the GitHub Actions the workflows run, one grouped pull request a week.

## What the app does not do

MpVFX makes no network connection and sends nothing anywhere: there is no telemetry, no update check and no account.
The two engines it links are downloaded at build time only, by `mpvfx-swift/scripts/fetch-binaries.py`, from this
project's release host, and verified by SHA-256 against `mpvfx-swift/binaries.lock`.

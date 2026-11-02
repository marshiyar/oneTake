# Security

## Reporting

Report a vulnerability privately through GitHub: **Security › Report a vulnerability** on this repository (private
vulnerability reporting), not in a public issue. Include the installer or commit, the platform, and steps to
reproduce. You will get an acknowledgement, and a fix or an explanation, in the open once it is safe to publish.

## What is checked on every change

- **CI** ([ci.yml](workflows/ci.yml)): builds and runs every test on Linux and Windows.
- **Dependabot**: the GitHub Actions the workflows run, one grouped pull request a week.

## What the app does not do

MpVFX makes no network connection and sends nothing anywhere: there is no telemetry, no update check and no account.
The two engines it links are downloaded at build time only, by `mpvfx-swift/scripts/fetch-binaries.py`, from this
project's release host, and verified by SHA-256 against `mpvfx-swift/binaries.lock`.

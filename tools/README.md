# Snapshot tooling

One-time tooling that builds this repository's first commit from the old app repository. `main` stays empty until the
snapshot is taken; this branch holds only the tooling.

```sh
sh tools/make-snapshot.sh --commit ../onetake-snapshot/tree   # after the listed pull requests of the old repository merged
```

| Step | Script | What it does |
|---|---|---|
| 1 | `make-snapshot.sh` | refuses to run until the old repository's pull requests #71, #72, #74, #73, #69, #70 and #62 are merged (`--wait-for`), clones the old repository read-only into a temporary folder |
| 2 | `snapshot/snapshot.py` | copies the public files only, lays `snapshot/overlay/` over them, rewrites the app for prebuilt engines, writes `snapshot-report.txt` next to the tree |
| 3 | `snapshot/leak-scan.py` | scans the tree for maintainer-only text; what counts as private is read from the temporary clone at run time |
| 4 | `make-snapshot.sh --commit` | `git init` and one commit authored and committed by the owner; nothing is pushed |

Publishing is a separate, deliberate step once the report is clean: push the tree's `main` to this repository.

## What changes in the app

- `Package.swift`: the engine source packages are gone; `CMediaEngine` / `CKeyframeEngine` (C module maps over the
  headers shipped with the binaries) and the app's own adapters `OneTakeMedia` / `OneTakeKeyframes` link the
  prebuilt dynamic libraries in `mpvfx-swift/.binaries/` (rpath for `swift run` and `swift test`).
- Swift sources: `import OneTakeMedia` / `import OneTakeKeyframes`; the keyframe engine type is `KeyframeRuntime`.
- `binaries.lock` + `scripts/fetch-binaries.py` (with tests): version, URL and SHA-256 per platform, verified
  download, clear errors when a release is missing.
- Installers: macOS bundles the dylibs in `Contents/Frameworks` (`@rpath`), the `.deb` installs them in
  `/usr/lib/mpvfx`, the Windows zip and installer carry the DLLs next to `MpVFX.exe`.
- CI: the old jobs without the engine builds and without tokens; `ci-ok` aggregate; `agent-approve.yml` (needs
  `AGENT_APP_ID` and `AGENT_APP_PRIVATE_KEY`).
- `.gitignore` for the session tooling rendered at start; `.claude/settings.json` only runs
  `.claude/hooks/session-start.sh`, which runs the private setup when it is present and fetches the engines.

## Release archive contract (for the binaries repository)

One archive per platform (`macos-arm64`, `linux-x86_64`, `windows-x86_64`; `macos-x86_64` and `linux-aarch64` are
accepted when listed in the lock), named `<asset>.tar.gz` (or `.zip`) as `asset` in `binaries.lock`, plus a
`SHA256SUMS` file in the release. One top-level folder inside the archive is allowed; zip names may use `\`.
media-v0.1.0 follows it (library `mpvfx_ffi`):

```
include/mpvfx_media.h | include/cvkf.h
lib/libmpvfx_ffi.dylib | lib/libcvkf.dylib     macOS, install name @rpath/lib<name>.dylib
lib/libmpvfx_ffi.so | lib/libcvkf.so               Linux, SONAME lib<name>.so
lib/mpvfx_ffi.lib (or .dll.lib) + bin/ or lib/mpvfx_ffi.dll   Windows (same for cvkf)
LICENSE, NOTICE                                  the binary licence and third-party notices (shipped by every installer)
```

Once a release is published, `cd mpvfx-swift && python3 scripts/fetch-binaries.py --update <component> <version>`
fills in the URLs and SHA-256 values (from the release's `SHA256SUMS`; no token needed). media is pinned to 0.1.0;
keyframes is pending until `keyframes-v1.0.0` is published.

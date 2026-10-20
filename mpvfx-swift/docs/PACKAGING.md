# Installers

MpVFX ships an installer for each desktop OS. The macOS one is signed with a Developer ID and notarized when the
signing secrets are set; Windows and Linux installers are unsigned (no certificate yet).

| OS | File | What it does | Built by |
|---|---|---|---|
| macOS 15+ (Apple silicon) | `MpVFX-<version>-macos-arm64.dmg` | Disk image with `MpVFX.app` and an Applications link: drag to install. The engine libraries are in `MpVFX.app/Contents/Frameworks`. Developer ID signed, hardened runtime, notarized and stapled when the signing secrets are set | `packaging/macos/package.sh` |
| Windows 10/11 x64 | `MpVFX-<version>-windows-x64-setup.exe` | Per-user install to `%LOCALAPPDATA%\Programs\MpVFX` (the engine DLLs next to `MpVFX.exe`), Start menu shortcut, entry in Settings > Apps with an uninstaller. No administrator rights. Unsigned: SmartScreen asks "More info > Run anyway" | `packaging/windows/build-setup.ps1` (IExpress, part of Windows) |
| Ubuntu/Debian x64 | `mpvfx_<version>+git<time>.<sha>_amd64.deb` | App in `/opt/mpvfx`, the engine libraries in `/usr/lib/mpvfx`, `mpvfx` on PATH, menu entry and icons. Depends are the packages of the system libraries the app and engines link | `packaging/linux/build-deb.sh` |

The portable `.tar.gz` (Linux, engine `.so` files next to the binary) and `.zip` (Windows) are published next to the
installers. The version is `packaging/VERSION`; the build number is the commit's short sha.

## The engine libraries

The media engine (library `mpvfx_ffi`) and the keyframe engine (`cvkf`) are proprietary and prebuilt. `binaries.lock` pins,
per component, a release of `marshiyar/mpvfx-media-binaries` (tags `media-v<version>`, `keyframes-v<version>`) and the
download URL and SHA-256 of each platform's archive (`.tar.gz`, or `.zip` on Windows). `scripts/fetch-binaries.py` downloads the archives for the
machine it runs on, refuses any whose SHA-256 differs, and unpacks them into `.binaries/<component>/`:

| Folder | Holds |
|---|---|
| `include/` | the C header the app's adapter compiles against (`mpvfx_media.h`, `cvkf.h`) |
| `lib/` | `lib<name>.dylib` (macOS, install name `@rpath/lib<name>.dylib`), `lib<name>.so` (Linux), `<name>.lib` (Windows import library) |
| `bin/` | `<name>.dll` (Windows only) |
| `LICENSE`, `NOTICE` | the engine's licence and third-party notices; every installer ships them (macOS `Contents/Resources/EngineLicenses/`, Debian `/usr/share/doc/mpvfx/engines/`, the portable archives `licenses/`) |

`Package.swift` links them through the C module maps in `Sources/CMediaEngine` and `Sources/CKeyframeEngine`, with an
rpath to `.binaries/<component>/lib` so `swift run` and `swift test` work in place; the installers replace that rpath
with the app's own folder. To move to a newer engine: `python3 scripts/fetch-binaries.py --update <component> <version>`
(reads the published release, rewrites the lock), then a pull request with the new `binaries.lock`.

## Where they are built

GitHub Actions in this repository (`.github/workflows/`), on every pull request into `main`, every push to `main`,
every night and every push of a `v*` tag: `mpvfx-ci.yml` (Linux, Windows) and `mpvfx-macos.yml` (macOS). Either can also be run by hand on any
branch (Actions > workflow > Run workflow; "full tests" ignores recorded passes, and for macOS "Skip the test suite"
gives a packaging-only run). Each OS has one build, package and install-smoke job and runs its tests beside it as 4
shards (`linux test (…)`, `windows test (…)`, `macos / test (…)`), the same shard list on every OS
(`.github/ci/test-shards.py`, balanced by measured test time). A shard that passed on an OS is not rerun there while
every file its tests are built from (and `binaries.lock`) is unchanged (cache entry `<os>-pass-<shard>-<key>`). The
nightly run ignores every recorded pass and runs all of it. `ci-ok` passes when every job passed or was skipped for a
recorded pass. Pull requests build and test but never publish. The macOS jobs run on GitHub's `xcode-27` runner with
Xcode pinned (`XCODE_VERSION` in `mpvfx-macos.yml`). Each job installs its installer on the runner, launches the
installed app with a hidden window (the `*-smoke.png` snapshot) with the build tree and the fetched libraries moved
away, and, on Windows and Linux, uninstalls it again.

## Releases: nightly and official

When every platform is green, one publish job (`.github/ci/publish.sh`) uploads all installers to a single GitHub
release:

- **Nightly builds** are pre-releases named `nightly-<commit>` (the commit's first 7 hex digits), titled
  `oneTake nightly <date> (<commit>)`, made by every green run of `main` (a push, the nightly run or a manual run).
  A rerun on the same commit uploads into the same release. They are untested development builds, never marked
  latest; only the newest 7 are kept.
- **Official releases** come from pushing a `v*` tag, e.g. `git tag v0.2.0 && git push origin v0.2.0`. The tag's
  version (without the `v`) must equal `packaging/VERSION`, or the publish job fails before uploading anything. The
  release is titled `oneTake <version>`, is the repository's "latest" release (`releases/latest`), and is never
  deleted.

Pull requests and other branches build and test but never publish. Older `build-main-*` releases from before this
scheme are left as they are.

No repository secret is needed to build and test. The optional secrets below sign the macOS disk image and approve
pull requests.

## Approvals: the review App

`main` requires `ci-ok` and one approving review. Approvals can come from the project's review GitHub App (installed
on this repository only; Pull requests read and write, Contents read, Checks read, no webhook), whose App ID and
private key are the repository secrets `AGENT_APP_ID` and `AGENT_APP_PRIVATE_KEY`. After reviewing, the owner comments
`/agent-approve <full head sha>` on the pull request; `.github/workflows/agent-approve.yml` posts the App's approval
only when the comment comes from the owner's account, names the current head, and `ci-ok` passed on that commit.

## macOS signing: one-time setup (owner)

The workflow reads five repository secrets (Settings > Secrets and variables > Actions > New repository secret).
Without them the image is still built, ad-hoc signed and not notarized.

1. **Certificate.** On your Mac: Xcode > Settings > Accounts > your team > Manage Certificates > `+` >
   **Developer ID Application** (or developer.apple.com > Certificates > `+` > Developer ID Application).
2. **Export it.** Keychain Access > login > My Certificates > "Developer ID Application: <you> (<TEAMID>)" >
   right-click > Export > `.p12`, with a password. Then, in Terminal (any folder):
   `base64 -i ~/Downloads/Certificates.p12 | pbcopy`
3. **Secrets:**

   | Secret | Value |
   |---|---|
   | `MACOS_CERT_P12_BASE64` | the base64 text you just copied |
   | `MACOS_CERT_PASSWORD` | the `.p12` password |
   | `APPLE_ID` | your Apple Account email |
   | `APPLE_APP_PASSWORD` | an app-specific password: account.apple.com > Sign-In and Security > App-Specific Passwords |
   | `APPLE_TEAM_ID` | the 10-character Team ID (developer.apple.com > Account > Membership details) |

4. Run `mpvfx-macos`. The log shows `notarytool ... "status": "Accepted"` and `The staple and validate action
   worked!`, and the smoke step's `spctl --assess` prints `source=Notarized Developer ID`.

## Building an installer by hand

From `mpvfx-swift/`, after `python3 scripts/fetch-binaries.py`:

```sh
# macOS (MACOS_SIGN_IDENTITY / APPLE_* from the table above to sign and notarize)
swift build -c release && sh packaging/macos/package.sh dist
# Linux (Debian/Ubuntu; needs patchelf)
swift build -c release --static-swift-stdlib
sh packaging/linux/build-deb.sh dist "$(swift build -c release --static-swift-stdlib --show-bin-path)"
```

Windows: assemble the portable folder as the "Package (portable zip)" step of `mpvfx-ci.yml` does (the engine DLLs
from `.binaries\*\bin` next to `MpVFX.exe`), then `pwsh packaging/windows/build-setup.ps1 -AppDir <that folder> -Dist dist`.

The icon is drawn by `packaging/icon/make-icon.py` (standard library only); re-run it from `mpvfx-swift/` after
changing the drawing and commit the PNGs and `mpvfx.ico` it writes.

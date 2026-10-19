# oneTake: MpVFX

MpVFX is a native video editor for macOS, Linux and Windows, written in Swift: cut, grade and export video with a
custom-drawn timeline, colour grading on the GPU and its own media engine (no FFmpeg).

**Open core.** The app in this repository is open source under MIT OR Apache-2.0. The media engine and the keyframe
engine it runs on are proprietary: they are not in this repository, and the app downloads them as prebuilt,
checksum-pinned libraries. See [LICENSE](LICENSE).

| Path | What it holds |
| --- | --- |
| [`mpvfx-swift/`](mpvfx-swift/) | the app: Swift package, tests, docs, installers ([its README](mpvfx-swift/README.md)) |
| [`mpvfx-swift/binaries.lock`](mpvfx-swift/binaries.lock) | engine versions, download URLs and SHA-256 per platform |
| [`.github/`](.github/) | CI: build, test, package and publish on all three platforms |

## Build and run

Requirements: Swift 6.0 or newer and Python 3.11 or newer.
macOS 15 or newer with Xcode; Linux with `libgtk-3-dev`, `libsqlite3-dev`, `pkg-config` (and `libpulse-dev` for
audio output); Windows 10 or 11 with the Swift toolchain.

```sh
cd mpvfx-swift
python3 scripts/fetch-binaries.py   # downloads and verifies the engine libraries into .binaries/
swift build
swift run MpVFX                      # opens the editor
MPVFX_DEMO=1 swift run MpVFX         # the built-in demo timeline
```

`fetch-binaries.py` stops with a clear message when the pinned engine release is not published yet or a download does
not match its checksum.

**Status:** the media engine is pinned (0.1.0). The keyframe engine's first release is still pending: until it is
published and pinned in `binaries.lock`, `fetch-binaries.py` reports it missing and the app does not build or link. On Windows, add `mpvfx-swift\.binaries\media\bin` and `...\keyframes\bin` to `PATH` before
`swift run` or `swift test`.

## Test

```sh
cd mpvfx-swift
swift test                 # the whole suite
sh scripts/check.sh        # what CI checks first: fetch, build, tests, copyright blocks
```

Installers (macOS disk image, Windows setup.exe, Ubuntu/Debian .deb) are built by CI and published as releases; see
[`mpvfx-swift/docs/PACKAGING.md`](mpvfx-swift/docs/PACKAGING.md).

Contributions are welcome: [CONTRIBUTING.md](CONTRIBUTING.md).

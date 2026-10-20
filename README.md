# oneTake: MpVFX

MpVFX is a native video editor for macOS, Linux and Windows, written in Swift: cut, grade and export video with a
custom-drawn timeline, colour grading on the GPU and its own media engine. A project is a folder holding one JSON
document, `.studio/project.json`.

**Open core.** The app in this repository is open source (MIT OR Apache-2.0). The media engine and the keyframe
engine are proprietary and not in this repository: the app downloads them as prebuilt, checksum-pinned libraries
([`binaries.lock`](mpvfx-swift/binaries.lock), [`scripts/fetch-binaries.py`](mpvfx-swift/scripts/fetch-binaries.py))
and talks to them through its own Swift adapters ([`OneTakeMedia`](mpvfx-swift/Sources/OneTakeMedia),
[`OneTakeKeyframes`](mpvfx-swift/Sources/OneTakeKeyframes)). See [LICENSE](LICENSE).

<p align="center"><img src="mpvfx-swift/docs/images/readme/editor-demo-1440x900@1x.png" alt="The MpVFX editor on Linux with the built-in demo timeline: library panel, preview with transport controls, Design and Renders tabs, and a timeline with an image track, two video clips and a music track" width="760"></p>

<p align="center"><em>Linux, <code>MPVFX_DEMO=1</code>, 1440×900 (<a href="mpvfx-swift/scripts/capture-readme.sh"><code>scripts/capture-readme.sh</code></a>). The demo's media files do not exist, so the preview is empty.</em></p>

## Download

Installers for each green build of `main` are on the [releases page](https://github.com/marshiyar/oneTake/releases/latest):
macOS disk image (Apple silicon), Windows setup.exe, Ubuntu/Debian `.deb`, and portable archives for Linux and Windows. The Windows
and Linux builds carry everything they need; macOS 15 or newer on Apple silicon, Windows 10 or 11 (x64), Ubuntu 24.04 or a Debian
with GTK 3, PulseAudio and SQLite 3.

## What it does

- **Editor:** the same custom-drawn editor on every platform (GTK 3 + Cairo on Linux, AppKit + Core Graphics on
  macOS, Win32 + Direct2D on Windows): library, media bin, preview, timeline and inspector.
- **Editing:** multi-track timeline, keyframes on position, crop and other parameters, colour grading and stylize
  effects, text layers, 3D transforms. Preview and export draw with the same painter, so what you see is what renders.
- **Composition size:** Landscape 16:9, Portrait 9:16, Square 1:1, Vertical 4:5, 4K 16:9 or custom, from the Design
  tab. The Renders tab's output size scales the composition and keeps its shape.
- **GPU grading:** the grade and stylize effects run through Metal (macOS), Vulkan (Linux) or Direct3D 11 (Windows),
  and on the CPU when there is no usable device. `MPVFX_GPU=0` forces the CPU; `MPVFX_GPU=software` also accepts a
  software device.
- **Audio:** PulseAudio (Linux), Core Audio (macOS) or WASAPI (Windows) playback through a bus/FX graph that playback
  and export share.
- **Projects:** save (Cmd/Ctrl+S, close, autosave), import, a library navigator and export from the Renders tab.
  Projects from earlier versions open, preview and export; a layer the renderer cannot draw is kept unchanged, skipped,
  and named in one notice when the project opens.

[`docs/STATUS.md`](mpvfx-swift/docs/STATUS.md) lists the state of every feature; [`docs/FEATURES.md`](mpvfx-swift/docs/FEATURES.md)
what is planned.

## Media formats

- **Import:** MP4/M4V/MOV with H.264 (8-bit 4:2:0) or HEVC (Main, Main 10) video and LPCM, FLAC, AAC (LC, HE, HE v2)
  or MP2 sound; WAV, FLAC, M4A, ADTS `.aac`, MPEG audio Layer I/II (`.mp2`), Ogg Vorbis and SILK-only Opus (`.ogg`, `.oga`,
  `.opus`; CELT and hybrid Opus streams are refused); PNG, JPEG and BMP images. Anything else is refused with a message that names the format.
- **MP3:** not yet. A video with MP3 sound imports without its sound; `.mp3` files are refused.
- **Export:** MP4 (H.264 + FLAC, 48 kHz stereo) and MOV with alpha (PNG frames + 16-bit LPCM). An export never
  overwrites: if a file appears at the output path while rendering, the export stops and leaves it.

## Build from source

Requirements: Swift 6.0 or newer, Python 3.11 or newer (for the engine download).

- macOS 15 or newer: Xcode.
- Linux: `libgtk-3-dev`, `libsqlite3-dev`, `pkg-config`; `libpulse-dev` for audio output.
- Windows 10 or 11: the Swift toolchain; put `mpvfx-swift\.binaries\media\bin` and `mpvfx-swift\.binaries\keyframes\bin`
  on `PATH` before `swift run` or `swift test`.

```sh
cd mpvfx-swift
python3 scripts/fetch-binaries.py   # engine libraries into .binaries/ (again after binaries.lock changes)
swift build
swift run MpVFX                     # your standalone project (made on first launch)
MPVFX_DEMO=1 swift run MpVFX        # the built-in demo timeline
MPVFX_PROJECT=/path/to/project swift run MpVFX
```

If the build cannot find `mpvfx_media.h` or `cvkf.h`, run `python3 scripts/fetch-binaries.py` first. The engines are
pinned at media 0.2.0 and keyframes 1.0.0 in `mpvfx-swift/binaries.lock`.

## Test and check

From `mpvfx-swift/`, before every push:

```sh
sh scripts/check.sh          # engine libraries, fetch-script tests, copyright blocks, shaders, swift build, swift test
sh scripts/check.sh --fast   # the same without swift build and swift test
sh scripts/doctor.sh         # what a full run needs that is missing, with fixes
```

A full run starts with [`scripts/doctor.sh`](mpvfx-swift/scripts/doctor.sh): with a prerequisite missing it stops at
once with `check: UNAVAILABLE` (exit 2), neither passed nor failed.

CI ([`mpvfx-ci.yml`](.github/workflows/mpvfx-ci.yml)) builds, tests, packages and install-smokes the app on Linux,
Windows and macOS; `ci-ok` is the required check, and a green `main` publishes the installers. Two more workflows
report on each build: [`strip-check.yml`](.github/workflows/strip-check.yml) verifies every published binary is
stripped, and [`bench.yml`](.github/workflows/bench.yml) benchmarks startup, the audio graph, the colour grade (CPU vs
GPU) and preview playback on all three platforms. How the installers are built and signed:
[`docs/PACKAGING.md`](mpvfx-swift/docs/PACKAGING.md). Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).

Benchmarks ([`.github/workflows/bench.yml`](.github/workflows/bench.yml)) run from a release build on Linux, Windows and
macOS after every green run on `main`, weekly, and by hand: startup to the first painted frame, the audio graph
(`MpvfxAudioBench`), the colour grade on the CPU and the GPU (`MpvfxColorBench`) and preview playback
(`MpvfxPreviewBench`), every sample with p50, p95, max and peak memory, as a table in the run summary and
`bench-<os>.json` in the `bench-<os>` artifact ([`.github/ci/bench.py`](.github/ci/bench.py)).

## Repository layout

| Path | What it holds |
| --- | --- |
| [`mpvfx-swift/`](mpvfx-swift/) | the app's Swift package: sources, tests, docs, scripts, installers |
| [`Sources/MpvfxDesktop`](mpvfx-swift/Sources/MpvfxDesktop) | the app: platform shells, editor session, wiring (`main.swift`) |
| [`Sources/MpvfxRuntime`](mpvfx-swift/Sources/MpvfxRuntime) | projects, libraries, import, probing, export pipeline (no UI) |
| [`Sources/MpvfxPlayer`](mpvfx-swift/Sources/MpvfxPlayer) | preview compositor, decode lanes, the painter preview and export share |
| [`Sources/MpvfxColor`](mpvfx-swift/Sources/MpvfxColor), [`scripts/gpu`](mpvfx-swift/scripts/gpu) | colour grade: CPU reference, GPU renderers, shader generator |
| [`Sources/MpvfxAudio`](mpvfx-swift/Sources/MpvfxAudio), [`Sources/MpvfxAudioGraph`](mpvfx-swift/Sources/MpvfxAudioGraph) | live audio, stem decoding, bus/FX graph, offline mix |
| [`Sources/MpvfxTimeline`](mpvfx-swift/Sources/MpvfxTimeline), [`Sources/MpvfxPanels`](mpvfx-swift/Sources/MpvfxPanels), [`Sources/MpvfxCanvas`](mpvfx-swift/Sources/MpvfxCanvas) | timeline, inspector and side panels, drawing abstraction |
| [`Sources/MpvfxShared`](mpvfx-swift/Sources/MpvfxShared) | document schema, validation, export policy, shared types |
| [`Sources/OneTakeMedia`](mpvfx-swift/Sources/OneTakeMedia), [`Sources/OneTakeKeyframes`](mpvfx-swift/Sources/OneTakeKeyframes) | Swift adapters over the two engines' C interfaces |
| [`docs/`](mpvfx-swift/docs/) | [`STATUS.md`](mpvfx-swift/docs/STATUS.md), [`FEATURES.md`](mpvfx-swift/docs/FEATURES.md), [`PACKAGING.md`](mpvfx-swift/docs/PACKAGING.md), [`MEMORY.md`](mpvfx-swift/docs/MEMORY.md) |
| [`binaries.lock`](mpvfx-swift/binaries.lock) | engine versions, download URLs and SHA-256 per platform |
| [`.github/`](.github/) | CI, release publishing, strip check, benchmarks |

## Known limits

- macOS and Windows are built, tested and install-smoked in CI; Linux has had the most hands-on use.
- AAC is decoded, not encoded: exports carry FLAC or LPCM sound.
- HEVC decodes on one thread (about 33 fps at 1080p, 10 fps at 4K), so 4K phone clips do not preview in real time.
- Export is SDR only; a project whose media is HDR (PQ, HLG or BT.2020) imports and previews but is refused at export.

## Copyright

Copyright 2026 Arshiya Rahgozar. Licensed under the MIT license or the Apache License, Version 2.0, at your option
([`LICENSE-MIT`](LICENSE-MIT), [`LICENSE-APACHE`](LICENSE-APACHE)). The media and keyframe engines it links are
proprietary ([`LICENSE`](LICENSE)).

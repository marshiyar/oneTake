# MpVFX (Swift)

MpVFX is a native video editor written in Swift. A project is a folder holding one JSON document,
`.studio/project.json`. Media is decoded, previewed and exported by the project's own media engine, a
proprietary prebuilt library (`binaries.lock`, `scripts/fetch-binaries.py`) that the app calls through its own Swift
adapter, [`Sources/OneTakeMedia`](Sources/OneTakeMedia).

<p align="center"><img src="docs/images/readme/editor-demo-1440x900@1x.png" alt="The MpVFX editor on Linux with the built-in demo timeline: library panel, preview with transport controls, Design and Renders tabs, and a timeline with an image track, two video clips and a music track" width="760"></p>

<p align="center"><em>Linux shell, <code>MPVFX_DEMO=1</code>, 1440×900 at DPR 1, captured by <a href="scripts/capture-readme.sh"><code>scripts/capture-readme.sh</code></a>. The demo document names media files that do not exist, so the preview shows an empty frame.</em></p>

## What it does now

- **Editor:** the Linux shell (GTK 3 + Cairo) and the macOS shell (AppKit + Core Graphics) run the same
  custom-drawn editor: library, media bin, preview, timeline and inspector.
- **Editing:** timeline editing, keyframes on position, crop and other parameters, colour grading and stylize
  effects, text layers and 3D transforms. The preview and the export draw with the same painter.
- **Composition size:** with nothing selected, the Design tab sets the project's frame: Landscape 16:9, Portrait 9:16,
  Square 1:1, Vertical 4:5, 4K 16:9 or a custom width and height. Untouched clips refit; placed clips and text keep
  their size and place relative to the centre. The Renders tab's output size scales the composition and keeps its
  shape (720p of a 9:16 project renders 720×1280).
- **GPU grading:** the colour grade and stylize effects run on the GPU through Metal (macOS), Vulkan (Linux) or
  Direct3D 11 (Windows), and on the CPU when the machine has no usable device. `MPVFX_GPU=0` forces the CPU;
  `MPVFX_GPU=software` also accepts a software device (Mesa lavapipe, WARP). `swift run -c release MpvfxColorBench`
  times CPU against GPU at 1080p and 4K. The Vulkan and Direct3D kernels are generated from the Metal ones by
  [`scripts/gpu/gen-compute-shaders.py`](scripts/gpu/gen-compute-shaders.py) (needs glslang-tools and spirv-tools).
- **Audio:** playback through PulseAudio (Linux) or Core Audio (macOS), with a bus/FX graph that playback and export
  share.
- **Media:** import, probing, thumbnails, filmstrips, waveforms, silence detection, preview decoding, live audio and
  export all go through [`Sources/OneTakeMedia`](Sources/OneTakeMedia), the app's
  Swift adapter over the engine's C interface.
- **Projects:** saving (Cmd/Ctrl+S, close, autosave), media import, the library navigator and exports from the
  Renders tab run through `RuntimeDesktopBackend`. Publishing is not part of the app.
- **Older projects:** every project document opens, previews and exports. A missing or older `"mediaEngine"` value
  is read as the native timeline and the next save writes `"native"`. Layers from an earlier version of the editor
  that the renderer cannot draw stay in the project unchanged, are skipped in preview and export, and are named in
  one notice when the project opens.

[`docs/STATUS.md`](docs/STATUS.md) lists the state of every feature.

## Media formats

The media engine decides what each format supports; the app's list is `Sources/MpvfxRuntime/Media/ImportFormats.swift`.

- **Import:** MP4/M4V/MOV with H.264 video (8-bit 4:2:0) or HEVC video (Main and Main 10, 4:2:0, such as iPhone
  `.mov` clips) and LPCM, FLAC, AAC (AAC-LC, HE-AAC, HE-AAC v2) or MP2 sound; WAV, FLAC, M4A, ADTS `.aac` and MPEG
  audio Layer I/II (`.mp2`) files; PNG, JPEG and BMP images. Any other format is refused with a message that names
  it. HEVC and MP2 decode inside the media engine.
- **MP3 sound:** a file with MP3 (Layer III) sound imports without sound, and `.mp3` files are refused (not decided yet).
- **Export:**
  - MP4: H.264 video with FLAC sound, 48 kHz stereo 16-bit.
  - MOV with alpha: PNG frames (RGBA 8-bit) with 16-bit LPCM sound, 48 kHz stereo.
  - An export never replaces a file: if one appears at the output path while it renders, the export stops with a
    message and that file is left as it was.

## Quick start

Requirements: Swift 6.0 or newer and Python 3.11 or newer (for the engine download script).

- macOS 15 or newer: Xcode (SQLite and Core Audio come with the system).
- Linux: `libgtk-3-dev`, `libsqlite3-dev`, `pkg-config`; `libpulse-dev` for audio output.
- Windows 10 or 11: the Swift toolchain; put `.binaries\media\bin` and `.binaries\keyframes\bin` on `PATH` to run.

The media and keyframe engines are proprietary prebuilt libraries (see the repository's LICENSE).
[`binaries.lock`](binaries.lock) pins their versions and SHA-256 checksums; [`scripts/fetch-binaries.py`](scripts/fetch-binaries.py)
downloads and verifies them into `.binaries/`. The app's own Swift adapters over their C headers are
[`Sources/OneTakeMedia`](Sources/OneTakeMedia) and [`Sources/OneTakeKeyframes`](Sources/OneTakeKeyframes).

Installers (macOS disk image, Windows setup.exe, Ubuntu/Debian .deb) are built by CI; how to get, build and sign them: [`docs/PACKAGING.md`](docs/PACKAGING.md).

Run these from this folder, `mpvfx-swift/`:

```sh
python3 scripts/fetch-binaries.py   # engine libraries (again after binaries.lock changes)
swift build
swift run MpVFX                     # the standalone project (made on first launch)
MPVFX_DEMO=1 swift run MpVFX        # the built-in demo timeline
MPVFX_PROJECT=/path/to/project swift run MpVFX
sh scripts/check.sh                 # fetch, build, tests and the other checks CI runs first
```

If `swift build` reports "Could not find Package.swift", the shell is not in `mpvfx-swift/`; if it cannot find
`mpvfx_media.h` or `cvkf.h`, or the link step misses `mpvfx_media` or `cvkf`, run `python3 scripts/fetch-binaries.py`
first. `MPVFX_PROJECT` takes a project folder or its `.studio/project.json`.

## Repository layout

| Path | What it holds |
| --- | --- |
| [`Sources/MpvfxDesktop`](Sources/MpvfxDesktop) | the app: shells, editor session, wiring of every module (`main.swift`) |
| [`Sources/MpvfxRuntime`](Sources/MpvfxRuntime) | projects, libraries, import, probing, export pipeline (no UI) |
| [`Sources/MpvfxPlayer`](Sources/MpvfxPlayer) | preview compositor, decode lanes, the painter preview and export share |
| [`Sources/MpvfxColor`](Sources/MpvfxColor), [`Sources/CMpvfxVulkan`](Sources/CMpvfxVulkan), [`scripts/gpu`](scripts/gpu) | colour grade: CPU reference shader, renderer choice, Vulkan compute host, shader generator |
| [`Sources/MpvfxAudio`](Sources/MpvfxAudio), [`Sources/MpvfxAudioGraph`](Sources/MpvfxAudioGraph) | live audio, stem decoding, bus/FX graph, offline mix |
| [`Sources/MpvfxTimeline`](Sources/MpvfxTimeline), [`Sources/MpvfxPanels`](Sources/MpvfxPanels), [`Sources/MpvfxCanvas`](Sources/MpvfxCanvas) | timeline, inspector and side panels, drawing abstraction |
| [`Sources/MpvfxShared`](Sources/MpvfxShared) | document schema, validation, export policy, shared types |
| [`docs/`](docs/) | [`STATUS.md`](docs/STATUS.md), [`FEATURES.md`](docs/FEATURES.md), [`MEMORY.md`](docs/MEMORY.md) |
| [`scripts/`](scripts/) | [`check.sh`](scripts/check.sh), [`fetch-binaries.py`](scripts/fetch-binaries.py), [`capture-readme.sh`](scripts/capture-readme.sh) |

## Development and checks

From `mpvfx-swift/`, before every push:

```sh
sh scripts/check.sh          # engine libraries, fetch-script tests, copyright blocks, shaders, swift build, swift test
sh scripts/check.sh --fast   # the same without swift build and swift test
```

CI ([`../.github/workflows/mpvfx-ci.yml`](../.github/workflows/mpvfx-ci.yml)) builds, tests and packages the app on
Linux, Windows and macOS with the engine libraries pinned in [`binaries.lock`](binaries.lock); `ci-ok` is the
required check. How to contribute: [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

## Status and limitations

Measured at this revision:
- **Platforms:** Linux is built and tested here. macOS is built and tested in CI and has had little hands-on use.
  The Windows port (Win32 shell, Direct2D canvas, WASAPI, Win32 filesystem layer) is written but has never been
  compiled or run on Windows.
- **Formats:** files in any format the import list above does not name are refused with a message. AAC is
  decoded, not encoded: exports carry FLAC or LPCM sound.
- **HEVC speed:** HEVC decodes on one thread, about 33 fps at 1080p and 10 fps at 4K, so 4K phone clips do not
  preview in real time.
- **HDR:** export is SDR only. A project whose media the probe marks HDR (PQ or HLG transfer, or BT.2020 primaries)
  is refused at export with a message; it still imports and previews.
- **Packaging:** there is no app bundle or installer yet; a package must build the engine first.

## Copyright

Copyright 2026 Arshiya Rahgozar. Dual licensed under the MIT license or the Apache License, Version 2.0, at your
option ([`LICENSE-MIT`](../LICENSE-MIT), [`LICENSE-APACHE`](../LICENSE-APACHE)); it continues the Apache-2.0
[mpvfx](https://github.com/marshiyar/mpvfx). The media engine it links is proprietary ([`LICENSE`](../LICENSE)).

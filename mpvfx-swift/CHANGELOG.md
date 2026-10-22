# Changelog

All notable changes to oneTake. Versions follow `mpvfx-swift/packaging/VERSION`; a `v<version>` tag publishes that
version's installers as the latest release. Changes that have landed on `main` since the last release collect under
Unreleased; nightly builds of `main` are published as pre-releases named `nightly-<commit>` (see
[`docs/PACKAGING.md`](docs/PACKAGING.md)).

## Unreleased

Landed on `main` after 0.1.0 (the media engine is now pinned at 0.2.0 in `binaries.lock`); no version tag yet.

### Editing
- Dockable panels throughout: a program Scopes panel, a Markers panel and an audio Mixer open from Window / Panels
  and dock beside the preview; Design groups can be dragged out into their own panels.
- Sequence markers: M drops a named marker at the playhead; the Markers panel jumps, renames, recolours and deletes
  them, each edit one undo step.
- Cut transitions grow up: directional wipe and push join dissolve and dip, with direction, softness and duration
  in Design > Transition.
- Background generator clips (solid, linear gradient, radial gradient) from the Media panel menu, edited under
  Design > Background; canvas fills behind clips that do not cover the frame.
- Align and distribute selected visual clips against the frame or the selection.
- Grouped text looks in the Media sidebar (title, name strap, rolling credits, fade in/out, vertical-video styles)
  that land as ordinary editable text.
- Layer moves (in, out, loop) evaluated the same in preview and export.

### Grading
- Saved looks: name, rename, delete and re-apply a grade from Design > Saved looks.
- Auto balance and reference-clip look matching fit exposure, warmth, tint, contrast and offset from frame
  statistics in one undo step.
- Clip blend modes, a colour key with hue-following spill, and spill/GPU parity coverage.
- The media bin keeps its filter and sort between launches.

### Fixes and polish
- Stage system cursors stay synchronised with the transform box without pointer motion.
- The mask rasterizer meets its 1080p budget; Windows gains an on-device speech-to-captions adapter.

## 0.1.0

The first official release: one native editor for macOS (Apple silicon), Windows 10/11 x64 and Linux (Ubuntu 24.04+,
Debian 13), with a clean-room media engine and no FFmpeg.

### Editing
- Multi-track timeline with move, trim, split, ripple, multi-select and undo/redo that survives a restart.
- Keyframes with a stopwatch on every animated inspector row and Edit Easing… from the keyframe menu (#54).
- Clip copy and paste across tracks and projects (media and LUTs come along), Duplicate, and a "Keep audio pitch"
  option for clip speed (#54).
- Clips show their content and timecode on the timeline (#61).
- Composition sizes 16:9, 9:16, 1:1, 4:5, 4K or custom; colour grade and stylize effects on Metal, Vulkan or
  Direct3D 11, with a CPU fallback.
- Loop playback stays on the audio clock, and moving the loop range reaches the audio at once (#52, #54).

### Projects and media
- Open any project with File > Open (Cmd/Ctrl+O) and reopen recent ones (#76).
- A Settings window (Cmd/Ctrl+,) for appearance, audio output, preview cache size and default export folder (#77).
- Import Ogg Vorbis and SILK Opus; CELT and hybrid Opus are refused with a reason (#5).
- Imports stay in the selected library when another project is open (#70); preview decoding stays within its cache
  (#69).
- A getting started guide and a sample project (#59).

### Look
- Studio palette with clips coloured by kind (#30), flat panels with tab strips and a status line (#64), and a light
  mode with visible seams and outlined fields (#72).

### Installers
- macOS disk image (Developer ID signed), Windows per-user setup.exe and portable zip, Linux .deb and archive. Every
  shipped binary is stripped (#12).
- The macOS disk image may not be notarized yet: the first time, right-click MpVFX and choose Open.
- The Windows installer is not code-signed yet: SmartScreen asks for "More info > Run anyway" (#75).

### Known issues
- WebM and HDR export are not supported.
- The clipboard is the app's own, not the system clipboard.

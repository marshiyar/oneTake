# Changelog

All notable changes to oneTake. Versions follow `mpvfx-swift/packaging/VERSION`; a `v<version>` tag publishes that
version's installers as the latest release.

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
- macOS disk image (Developer ID signed and notarized), Windows per-user setup.exe and portable zip, Linux .deb and
  archive. Every shipped binary is stripped (#12).
- The Windows installer is not code-signed yet: SmartScreen asks for "More info > Run anyway" (#75).

### Known issues
- WebM and HDR export are not supported.
- The clipboard is the app's own, not the system clipboard.

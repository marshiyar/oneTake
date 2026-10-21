# Roadmap

What ships next and in what order. The GitHub milestones are the source of truth for which issue belongs to which
release; this page lists them in order with one line each. What already works is in [STATUS.md](STATUS.md).
Updated 2026-10-21.

Priority: P1 issues come before P2, and `launch-blocker` issues are what the release waits on. An issue labelled
`buildable` is scoped and ready to start. `blocked` names what it waits on, and `needs-owner` waits on a decision or
an account only the owner holds.

## Public beta ([milestone](https://github.com/marshiyar/oneTake/milestone/1))

The first public release: every editing basic works on Linux, macOS and Windows, with installers and a guide.

Launch blockers:

| Issue | What | State |
| --- | --- | --- |
| [#34](https://github.com/marshiyar/oneTake/issues/34) | Clips show content and timecode | in review ([#61](https://github.com/marshiyar/oneTake/pull/61)) |
| [#41](https://github.com/marshiyar/oneTake/issues/41) | Smooth preview playback and scrubbing | in progress; macOS not measured yet |
| [#48](https://github.com/marshiyar/oneTake/issues/48) | Getting started guide and sample project | in review ([#59](https://github.com/marshiyar/oneTake/pull/59)) |
| [#47](https://github.com/marshiyar/oneTake/issues/47) | Hands-on pass on macOS and Windows | needs-owner |
| [#49](https://github.com/marshiyar/oneTake/issues/49) | Release checklist and v0.2.0 release | blocked: macOS notarization credentials |

Also in the beta:

| Issue | What | State |
| --- | --- | --- |
| [#31](https://github.com/marshiyar/oneTake/issues/31) | Open any project from File > Open | in review ([#76](https://github.com/marshiyar/oneTake/pull/76)) |
| [#78](https://github.com/marshiyar/oneTake/issues/78) | Linux build without the Vulkan headers | buildable, P1 |
| [#50](https://github.com/marshiyar/oneTake/issues/50) | Swift 6 language mode for every target | first slice in review ([#62](https://github.com/marshiyar/oneTake/pull/62)) |
| [#35](https://github.com/marshiyar/oneTake/issues/35) | Visual refresh 4: compact track headers | buildable |
| [#36](https://github.com/marshiyar/oneTake/issues/36) | Visual refresh 5: inspector values and keyframe controls | buildable |
| [#37](https://github.com/marshiyar/oneTake/issues/37) | Visual refresh 6: markers, playhead timecode, audio meters | blocked on #61 |
| [#40](https://github.com/marshiyar/oneTake/issues/40) | Finish the library ("Save to…") | buildable |
| [#82](https://github.com/marshiyar/oneTake/issues/82) | Export never replaces a file on Windows | buildable |
| [#46](https://github.com/marshiyar/oneTake/issues/46) | Signed Windows installer | needs-owner |

## 1.0 ([milestone](https://github.com/marshiyar/oneTake/milestone/2))

Complete for everyday editing: captions, the remaining formats and the colourist's tools.

| Issue | What | State |
| --- | --- | --- |
| [#43](https://github.com/marshiyar/oneTake/issues/43) | Captions: track, editing, SRT, burn-in | split: [#81](https://github.com/marshiyar/oneTake/issues/81) (track and SRT) is buildable |
| [#42](https://github.com/marshiyar/oneTake/issues/42) | WebM export | needs the engine's encoders |
| [#44](https://github.com/marshiyar/oneTake/issues/44) | Decode every listed format | engine |
| [#79](https://github.com/marshiyar/oneTake/issues/79) | Spring and bounce eases in the curve editor | buildable |
| [#80](https://github.com/marshiyar/oneTake/issues/80) | Scopes of the composited program | buildable |

After these: the full-size scope view and the remaining scopes (RGB histogram, overlay waveform, CIE, false colour),
HDR export, caption styling and burn-in, and drawing frames from GPU textures instead of byte arrays.

## Not planned

- Publishing (Crosspost): refused on purpose by the backend.
- Telemetry, a crash prompt and a feedback card: not part of the product ([FEATURES.md](FEATURES.md) §9).

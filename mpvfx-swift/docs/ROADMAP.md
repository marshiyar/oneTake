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
| [#40](https://github.com/marshiyar/oneTake/issues/40) | Finish the library: "Save to…" and rename in review; delete events and projects next | buildable |
| [#82](https://github.com/marshiyar/oneTake/issues/82) | Export never replaces a file on Windows | buildable |
| [#46](https://github.com/marshiyar/oneTake/issues/46) | Signed Windows installer | needs-owner |

Playback ([#41](https://github.com/marshiyar/oneTake/issues/41), in measured slices):

| Issue | What | State |
| --- | --- | --- |
| [#92](https://github.com/marshiyar/oneTake/issues/92) | Preview bench decodes on Windows, and fails when nothing decoded | buildable, P1 |
| [#93](https://github.com/marshiyar/oneTake/issues/93) | Scrubbing shows a picture within 100 ms, then the exact frame | buildable, P1 |
| [#94](https://github.com/marshiyar/oneTake/issues/94) | macOS real-time playback reaches every frame at 1080p30 | buildable, P1 |
| [#95](https://github.com/marshiyar/oneTake/issues/95) | Canvas converts each frame to a surface once, not per draw | buildable, P1 |
| [#97](https://github.com/marshiyar/oneTake/issues/97) | Preview peak memory stays within its budgets | buildable |
| [#96](https://github.com/marshiyar/oneTake/issues/96) | Perf regression gate: per-metric bench budgets | buildable; Windows budgets after #92 |

Never lose work, and keyboard access:

| Issue | What | State |
| --- | --- | --- |
| [#100](https://github.com/marshiyar/oneTake/issues/100) | Save failures say what went wrong, once, and the unsaved state stays visible | buildable, P1 |
| [#101](https://github.com/marshiyar/oneTake/issues/101) | A project folder moved or deleted while open is detected | buildable, P1 |
| [#102](https://github.com/marshiyar/oneTake/issues/102) | Offline media is marked, and export names the missing files | buildable, P1 |
| [#103](https://github.com/marshiyar/oneTake/issues/103) | Keyboard focus moves between panes, and the focused pane is shown | buildable, P1 |
| [#104](https://github.com/marshiyar/oneTake/issues/104) | Settings card works from the keyboard | buildable |

Editing:

| Issue | What | State |
| --- | --- | --- |
| [#85](https://github.com/marshiyar/oneTake/issues/85) | Clip fades 1: fade in/out in the document, heard in playback and export | buildable, P1 |
| [#89](https://github.com/marshiyar/oneTake/issues/89) | Clip fades 2: video fade in preview and export | blocked on #85 |
| [#90](https://github.com/marshiyar/oneTake/issues/90) | Clip fades 3: fade handles on timeline clips | blocked on #85 |
| [#86](https://github.com/marshiyar/oneTake/issues/86) | Media fit mode: Fit / Fill / Stretch | buildable |

Checks and automation:

| Issue | What | State |
| --- | --- | --- |
| [#107](https://github.com/marshiyar/oneTake/issues/107) | CI runs the tests of every `.github/ci` script | buildable, P1 |
| [#108](https://github.com/marshiyar/oneTake/issues/108) | Builder PRs must name the issue they close | buildable |
| [#109](https://github.com/marshiyar/oneTake/issues/109) | Stale in-progress issues return to buildable | buildable |
| [#110](https://github.com/marshiyar/oneTake/issues/110) | Weekly external link check for the docs | buildable |
| [#111](https://github.com/marshiyar/oneTake/issues/111) | The no-optional-headers Linux build becomes required | blocked on #78 and a week green |

## 1.0 ([milestone](https://github.com/marshiyar/oneTake/milestone/2))

Complete for everyday editing: captions, the remaining formats and the colourist's tools.

| Issue | What | State |
| --- | --- | --- |
| [#43](https://github.com/marshiyar/oneTake/issues/43) | Captions: track, editing, SRT, burn-in | split: [#81](https://github.com/marshiyar/oneTake/issues/81) (track and SRT) is buildable |
| [#42](https://github.com/marshiyar/oneTake/issues/42) | WebM export | needs the engine's encoders |
| [#44](https://github.com/marshiyar/oneTake/issues/44) | Decode every listed format | engine |
| [#79](https://github.com/marshiyar/oneTake/issues/79) | Spring and bounce eases in the curve editor | buildable |
| [#80](https://github.com/marshiyar/oneTake/issues/80) | Scopes of the composited program | buildable |
| [#81](https://github.com/marshiyar/oneTake/issues/81) | Captions 1: caption track and SRT import/export | buildable |
| [#91](https://github.com/marshiyar/oneTake/issues/91) | Captions 2: caption lane on the timeline | blocked on #81 |
| [#87](https://github.com/marshiyar/oneTake/issues/87) | Slip edit | buildable |
| [#88](https://github.com/marshiyar/oneTake/issues/88) | Roll edit | buildable |
| [#98](https://github.com/marshiyar/oneTake/issues/98) | Export throughput bench, render overlapped with encode | buildable |
| [#105](https://github.com/marshiyar/oneTake/issues/105) | Screen readers 1: node tree and macOS NSAccessibility | blocked on #103 |
| [#106](https://github.com/marshiyar/oneTake/issues/106) | Interface size up to 200% | buildable |

After these: the full-size scope view and the remaining scopes (RGB histogram, overlay waveform, CIE, false colour),
HDR export, caption styling and burn-in, cut transitions beyond the cross-dissolve and dip (#236: timeline UI, motion kinds, a Transitions tab; the document schema is in place), screen readers on Linux (AT-SPI) and Windows (UIA), reduced motion, 4K playback from proxies, and drawing frames from GPU textures instead of byte arrays.

## Not planned

- Publishing (Crosspost): refused on purpose by the backend.
- Telemetry, a crash prompt and a feedback card: not part of the product ([FEATURES.md](FEATURES.md) §9).

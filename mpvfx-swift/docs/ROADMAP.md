# Roadmap

What ships next and in what order. The GitHub milestones are the source of truth for which issue belongs to which
release; this page summarises them and points at the evidence for anything already landed. What already works is in
[STATUS.md](STATUS.md); the full inventory, including gaps, is in [FEATURES.md](FEATURES.md).
Updated 2026-10-21, at `main` bfe862c (Public beta milestone: 45 open, 57 closed; 1.0 milestone: 10 open, 10 closed).

Priority: P1 issues come before P2, and `launch-blocker` issues are what the release waits on. An issue labelled
`buildable` is scoped and ready to start. `blocked` names what it waits on, and `needs-owner` waits on a decision or
an account only the owner holds. States below were read from the milestone and the code on the date above; when they
disagree, the milestone wins and this page needs the same pull request as the fix.

## Public beta ([milestone](https://github.com/marshiyar/oneTake/milestone/1))

The first public release: every editing basic works on Linux, macOS and Windows, with installers and a guide.
Version 0.1.0 is tagged (see [CHANGELOG.md](../CHANGELOG.md)); everything landed since collects there under
Unreleased until the next `v*` tag.

Landed since the beta list was first written (evidence in [STATUS.md](STATUS.md)):

| Area | What landed |
| --- | --- |
| Projects | Open any project (File > Open, Open Recent, the Media panel's Open project…), a moved or deleted project folder is detected, save failures surface once, undo survives a restart |
| Editing | Clips show content and timecode; slip and roll; media fit (Fit / Fill / Stretch); clip fades in the document, playback and export; cut transitions (dissolve, dip, wipe, push); align and distribute; background generators; layer moves |
| Grading | The full grade with `grade.*` keyframes, saved looks, auto balance, reference look matching, blend modes and a colour key; program scopes in the Grade row and a dockable Scopes panel |
| Audio and markers | The dockable Mixer, sequence markers and the Markers panel, grouped text looks |
| Platform and checks | The no-Vulkan-headers Linux build, the weekly doc link check and the doc reference check run in CI; preview memory stays within its budgets (measured, see [MEMORY.md](MEMORY.md)); each frame converts to a canvas surface once |

Still open for the beta (read the milestone for the live list):

| Issue | What | State |
| --- | --- | --- |
| [#41](https://github.com/marshiyar/oneTake/issues/41) | Smooth preview playback and scrubbing | in progress; measured on Linux and macOS runners, hands-on macOS still thin |
| [#47](https://github.com/marshiyar/oneTake/issues/47) | Hands-on pass on macOS and Windows | needs-owner |
| [#49](https://github.com/marshiyar/oneTake/issues/49) | Release checklist and next versioned release | waits on the hands-on pass and signing credentials |
| [#46](https://github.com/marshiyar/oneTake/issues/46) | Signed Windows installer | needs-owner (no certificate yet) |
| [#40](https://github.com/marshiyar/oneTake/issues/40) | Finish the library | Save to… and rename landed; deleting events and projects is the remaining piece |
| [#96](https://github.com/marshiyar/oneTake/issues/96) | Perf regression gate: per-metric bench budgets | benches run and report; budgets not enforced yet |

## 1.0 ([milestone](https://github.com/marshiyar/oneTake/milestone/2))

Complete for everyday editing: captions, the remaining formats and the colourist's tools.

Landed groundwork: the caption track and SRT import/export, speech-to-captions planning with macOS and Windows
on-device adapters, interface size to 200 %, and scopes of the composited program. Still to build:

| Issue | What | State |
| --- | --- | --- |
| [#43](https://github.com/marshiyar/oneTake/issues/43) | Captions: editing, styling, burn-in | track and SRT landed; the timeline lane, editing UI and burn-in remain |
| [#42](https://github.com/marshiyar/oneTake/issues/42) | WebM export | needs the engine's encoders |
| [#44](https://github.com/marshiyar/oneTake/issues/44) | Decode every listed format | engine (MP3 sound is the known gap: video imports without it, `.mp3` files are refused) |
| [#79](https://github.com/marshiyar/oneTake/issues/79) | Spring and bounce eases in the curve editor | shown disabled until the keyframe engine supports them |
| [#98](https://github.com/marshiyar/oneTake/issues/98) | Export throughput bench, render overlapped with encode | the overlapped encode pipeline landed; the bench gate remains |
| [#105](https://github.com/marshiyar/oneTake/issues/105) | Screen readers 1: node tree and macOS NSAccessibility | keyboard focus between panes landed first |

After these: a detached full-size scope view and the CIE diagram (the other scopes, including false colour, have
landed), HDR export, caption styling and burn-in, transition timeline handles and a Transitions browser, screen
readers on Linux (AT-SPI) and Windows (UIA), reduced motion, 4K playback from proxies, and drawing frames from GPU
textures instead of byte arrays.

## Not planned

- Publishing (Crosspost): refused on purpose by the backend.
- Telemetry, a crash prompt and a feedback card: not part of the product ([FEATURES.md](FEATURES.md) §9).

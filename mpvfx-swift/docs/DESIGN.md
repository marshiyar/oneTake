# Visual design

How the editor should look, and the rules every UI change follows. The values in the token table are checked by
`Tests/MpvfxThemeTests/VisualSpecTests.swift`: change a colour here and in `Sources/MpvfxTheme/ThemeTokens.swift`
together, or the test fails.

The direction is a calm, dense, professional editor in the style of desktop editing suites: the interface is
quiet grey so the footage carries the colour, and colour in the chrome only ever means "this is active".

## Principles

1. **One flat surface.** Panels are one grey (`panelBg`) and sit edge to edge. They are separated by the black shell
   showing through a thin seam, not by rounded cards, drop shadows or wide gaps.
2. **One accent.** Blue is the only accent. It marks the active tool, the focused panel, the playhead,
   selections and values the user has changed. The only other colours in the chrome are signals with a fixed
   meaning: red for recording and cutting (auto-keyframe armed, the razor guide) and errors, green for beat
   markers. Mint, violet and other identity colours are not used for chrome.
3. **Content is visible.** Clips show what they hold: video clips show frame thumbnails, audio clips show their
   waveform. The clip colour says what kind of media it is; over thumbnails the name sits on an 18 px strip of that
   colour, which also carries the hover state. The name is drawn at 92% ink (4.5:1 on the fill), the timecode at
   72% (3:1).
4. **Dense, not cramped.** 12 px body text, 11 px secondary text, 24–28 px rows. Empty space is a sign that a panel
   has nothing to show; show a short hint there instead.
5. **Time is timecode.** Times read `HH:MM:SS:FF` (or `MM:SS:FF` under an hour) in tabular figures, in the accent
   colour where the user can scrub them.
6. **Readable.** Body text reaches WCAG AA (4.5:1) on every surface it is drawn on; muted text at least 3:1.
   Light mode mirrors the dark palette and keeps the same contrast.

## Colour tokens (dark mode)

| Token | Dark | Use |
| --- | --- | --- |
| `studioBg` | `#000000` | The shell behind the panels: shows as the black seam between them |
| `panelBg` | `#1D1D1D` | Every panel body |
| `panelBgInset` | `#191919` | Grouped rows inside a panel (inspector sections) |
| `panelInput` | `#0E0E0E` | Text fields, search boxes, dropdowns |
| `panelSurface` | `#232323` | Raised controls (buttons, segmented controls) |
| `panelHover` | `#2C2C2C` | Hover wash on rows and buttons |
| `panelBorder` | `#000000` | Panel edges |
| `panelBorderInput` | `#333333` | Field outlines |
| `panelHairline` | `#141414` | Dividers inside a panel |
| `popover` | `#252525` | Menus and popovers |
| `timelineSurface` | `#1D1D1D` | Timeline background, ruler and toolbar strip |
| `timelineRow` | `#1D1D1D` | Track lanes (separated by `rowBorder` lines) |
| `timelineGutter` | `#212121` | Track headers (label column) |
| `viewport` | `#141414` | Around the picture in the viewer |
| `studioAccent` | `#4C8DF0` | The accent: active tool, selection, focus, changed values |
| `mint` | `#5A98F0` | The accent's line form: playhead, drop slots, timeline highlights |
| `accentEdge` | `#2F6BDF` | Filled accent controls (slider fill edge, active toggles) |
| `clipVideo` | `#1D4A64` | Video and image clips |
| `clipVideoHover` | `#245A79` | Video clip under the pointer |
| `clipAudio` | `#2F4A17` | Audio clips |
| `clipAudioHover` | `#3A5A1D` | Audio clip under the pointer |
| `waveform` | `#79C0F9` | Waveforms drawn on audio clips |

`mint` keeps its name for now because many views use it; it is the accent blue, a step lighter so a 1 px line stays
visible. Light mode uses `#1A5FCC` for both.

## Rollout

Each step is its own pull request, small enough to review on screenshots.

1. **Palette** — the token values above, the editor defaulting to the dark appearance, and clips filled by media
   kind. Light mode keeps working. *(this change)*
2. **Flat panels** — remove the rounded cards and gaps between the shell's panels; 1 px black seams; tab strips
   with an underlined active tab and a panel menu button; a status line at the bottom of the window for hints.
3. **Clips show content** — frame thumbnails across video clips, waveforms across audio clips, the clip name in a
   18 px header strip, clip durations and the ruler as timecode. *(done)*
4. **Track headers** — compact headers with a track tag (`V1`, `A1`) in the accent when targeted, lock, visibility,
   mute and solo, 28 px tall by default.
5. **Inspector** — label in grey, value in the accent when changed, a stopwatch toggle for animated properties and
   the previous/add/next keyframe buttons on the same row.
6. **Timeline extras** — coloured markers on the ruler, timecode on the playhead, audio meters docked beside the
   timeline.

## Checking a change

- Unit tests: `VisualSpecTests` (this table, single accent, contrast) and `ThemeTokensTests` (light mode, no raw
  colours outside the tokens, no colour captured once).
- Screenshots: the screenshot bot posts before/after images on each pull request that touches the UI; a reviewer
  compares them against the principles above.

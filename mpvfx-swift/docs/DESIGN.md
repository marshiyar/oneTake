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
   colour where the user can scrub them. The timeline ruler always reads `HH:MM:SS:FF`, so a minute never looks
   like an hour ([TIMELINE.md](TIMELINE.md)).
6. **Readable.** Body text reaches WCAG AA (4.5:1) on every surface it is drawn on; muted text at least 3:1.
   Light mode keeps the same contrast; its structure is tuned separately (see "Light mode").

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
| `trackControlIdle` | `#8C8C8C` | Track header lock, eye, speaker and solo while off (3:1 on the header) |
| `trackControlHover` | `#2E2E2E` | Under a track header control in the pointer |
| `trackTagText` | `#B4B4B4` | Track tag (`V1`, `A1`) of an untargeted track |
| `trackTagOutline` | `#4A4A4A` | Outline of an untargeted track tag |
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

## Light mode

Light is not the dark palette inverted. The neutral text ramp mirrors dark (`light(n) = dark(1000 − n)`), but the
surfaces are tuned so the same structure reads on white: panels are near-white and sit edge to edge, the seams
between them are a visible grey, fields are white with a clear outline, and clips are mid tones rather than pastels.
The light-palette rules in `ThemeTokensTests` still hold: every surface and the shell have a luminance above 0.7, and
text reaches 4.5:1 on every light surface. That caps how dark the shell can go (`#DADADE`).

- Shell and seams: `studioBg` `#DADADE`, `panelBorder` `#C8C8CE`, `panelHairline` `#DCDCE0`.
- Panels: `panelBg` `#FAFAFA`, `panelBgInset` `#F4F4F5` (the effect rack and grade curves are tuned against it), `panelInput` `#FFFFFF`.
- Controls: `panelSurface` `#E5E5E9`, `panelHover` `#D5D5DB`, field outline `panelBorderInput` `#B4B4BC`.
- Timeline: lanes `#FFFFFF`, track headers `#EFEFF2`. Clips: video `#8FBDE2` (hover `#7BB0DA`), audio `#A8D187`
  (hover `#93C46C`), waveform `#1E5F8E`; the clip name and timecode keep their dark ink at 4.5:1 and 3:1.

## Rollout

Each step is its own pull request, small enough to review on screenshots.

1. **Palette** — the token values above, the editor defaulting to the dark appearance, and clips filled by media
   kind. Light mode keeps working. *(this change)*
2. **Flat panels** — remove the rounded cards and gaps between the shell's panels; 1 px black seams; tab strips
   with an underlined active tab and a panel menu button; a status line at the bottom of the window for hints.
3. **Clips show content** — frame thumbnails across video clips, waveforms across audio clips, the clip name in a
   18 px header strip, clip durations and the ruler as timecode. *(done)*
4. **Track headers** — compact headers with a track tag (`V1`, `A1`) in the accent when targeted, lock, visibility,
   mute and solo, 28 px tall by default. Left to right: tag, name, clip count; right-aligned FX and solo (audio
   rows), eye or speaker, lock, each a 24 x 24 target in a column shared by every row. A control that is on is drawn
   in `mint` and changes shape (filled lock and headphones, slashed eye, crossed speaker, filled tag), so its state
   is never colour alone. Video tags count from the bottom (`V1` is the base layer), audio tags from the top. *(done)*
5. **Inspector** — label in grey, value in the accent when changed, a stopwatch toggle for animated properties and
   the previous/add/next keyframe buttons on the same row. Labels are `text2`, not `text3`: 11 px labels are body
   text and `text3` stays under 4.5:1 on the inspector's inset. *(done)*
6. **Timeline extras** — coloured markers on the ruler, timecode on the playhead, audio meters docked beside the
   timeline.

## Words

The editor speaks plainly, in the user's terms, and tells them what to do next.

1. **Errors say what failed and what to do.** A message never shows a raw Swift error (`"\(error)"` prints its
   debug form, such as `DesktopError(code: …, message: …)`); it uses the error's own message, or a sentence the user
   can act on.
2. **One ellipsis character.** Write "…" (U+2026), never three full stops: "Search assets…", "Rendering…".
3. **"…" on a command that asks for more before it acts** (opens a dialog, a file picker or a form): "Settings…",
   "Import media…", "Save as…". A title or a command that acts at once has none.
4. **Sentence case in the panels** ("Import media", "Remove silence from selected video"); the macOS menu bar keeps
   the platform's title case ("Close Window").

## Accessibility floors

- **Target size** (WCAG 2.2 SC 2.5.8, <https://www.w3.org/TR/WCAG22/#target-size-minimum>, read 2026-10-21): every
  pointer target is at least 24 × 24 pt, or spaced so a 24 pt circle on its centre touches no other target. A hit
  rect may be larger than the glyph it draws. The inspector's keyframe controls (stopwatch, previous, diamond, next)
  are four 24 pt squares laid edge to edge with each glyph centred, so none of them overlaps the next; a value's
  reset target is a 24 pt square ending 3 pt past its glyph.
- **Non-text contrast** (WCAG 2.2 SC 1.4.11, <https://www.w3.org/TR/WCAG22/#non-text-contrast>, read 2026-10-21):
  the focus ring, selected and active states, signal colours and field outlines reach 3:1 against the surfaces next
  to them.

## Layout grid

Every side panel lays out on one metric set, `PanelGrid` (`Sources/MpvfxPanels/PanelGrid.swift`). Use its values;
a new layout number is a new `PanelGrid` member, never a literal at the use site.

- **8 pt vertical grid.** Rows are whole steps tall: a control row (number field, slider, toggle, segmented control,
  buttons) is 32, a heading, section title or hint line 24, a wrapped note line 16. Gaps between rows are 0 or whole
  steps; an open group's body has 8 above and below its rows. A bespoke row (wheels, graphs, tiles) gets a slot
  rounded up to the grid. The clip header is 48 (with its hairline) and group headers 40, so every row starts on the
  grid counted from the panel's top.
- **Two columns.** Content sits 16 in from each panel edge. A row is a label column (a third of the content width
  on the grid, 72 to 96) and a control column 8 after it: every field, slider track and segmented control starts at
  the control column; the keyframe gutter (four 24 pt cells: stopwatch, previous, diamond, next) and the reset cell
  sit at the right end. Labels truncate at their column with an ellipsis.
- **Stack, never overlap.** When a row's controls do not fit in the control column at the panel's width (the six
  easing options at 280, a keyframed slider), the row stacks: the label line (with its reset and keyframe controls)
  on top, the control across the full width below it. When even that is too narrow, segmented options share the width
  and their labels truncate.
- **24 pt targets.** Every pointer target is at least 24 × 24 pt and no two overlap (a 12 px glyph sits centred in its
  24 pt cell).

`PanelLayoutAuditTests` checks all four rules at 280 pt, 364 pt (the 1280 × 800 default) and 409 pt (1440 × 900), in
dark and light.

## Tabs

Every tab row is `PanelTabBar` (`Sources/MpvfxPanels/PanelTabBar.swift`): the panel header strips (Design · Renders,
Media) in the `.strip` style, and the tab rows inside a panel (curve modes, scope modes, effect families) in the
`.inline` style on a 32 pt line over a hairline.

- **Selected.** The selected tab is full ink, medium weight, on a 2 px accent underline. The others are `text2`
  (at least 4.5:1 on the panel surfaces in both appearances), `text1` under the pointer. Selecting a tab never
  reflows the bar: each tab is measured in the selected weight.
- **Scales.** Tabs keep their natural width (label + 10 each side, at least 24) while they fit. When they do not, the
  bar shows the tabs that fit, always with the selected one, and puts the rest behind a 24 pt chevron at the end,
  whose menu lists them.
- **Keyboard.** A bar is one Tab stop, the selected tab. Left and Right move to the previous and next tab and select
  it (wrapping), Home and End go to the first and last. In the right panel the header (tab, hide, panel menu) comes
  before the inspector in the Tab order. The focus ring is the 2 px accent.
- **Close and drag.** A closable tab (`PanelTab.closable`, for dockable panels) carries a × with a 24 pt target inside
  the tab. `PanelTabDrag` reports a drag that starts on a tab once the pointer has moved 4 pt, so a click never starts one.

## Checking a change

- Unit tests: `VisualSpecTests` (this table, single accent, contrast) and `ThemeTokensTests` (light mode, no raw
  colours outside the tokens, no colour captured once).
- `NonTextContrastTests` (focus ring, states and field outlines at 3:1), `UICopyTests` (the rules under "Words":
  raw errors as a ratchet that only shrinks, the one-character ellipsis) and `TargetSizeTests` (MpvfxPanelsTests: the
  hit regions of the sidebar, inspector groups, Renders tab and Settings card at the default window widths, both
  appearances). Each keeps today's known findings in a list in the test that may only shrink: fix the UI, then
  remove the entry; never add one to make a change pass.
- Screenshots: the screenshot bot posts before/after images on each pull request that touches the UI; a reviewer
  compares them against the principles above.

# Timeline controls

How the timeline's zoom, track height, ruler, sequence end, clip badges and status-line hints look and behave. It
follows the principles in [DESIGN.md](DESIGN.md): one accent, red only for recording, cutting and errors, and every
control named where the user can read it. This is the target behaviour (specified 2026-10-21); each section names
the tests that hold it once its change has landed.

## Problems this replaces

Seen on a 41 s project at the default zoom (owner screenshots, 2026-10-21):

| Seen | Cause at `9039324` |
| --- | --- |
| Track height icon and slider, then zoom −, slider, + and "187%", with no names | `TimelineToolbar` writes `tooltip(_:)` for every item, but no host shows it; the two sliders are drawn by the same `drawSlider` |
| "187%" | Percent of the fit zoom, a number with no meaning on the ruler |
| No way to fit the sequence except double-clicking the slider or ⌘0 | No fit button and no ⇧Z |
| ⌘+ / ⌘− zoom about the left edge, so the playhead leaves the view | `setZoom(percent:anchorX:)` defaults the anchor to `contentOrigin` |
| Option+scroll scrolls instead of zooming | Hosts pass only Control (GTK, Windows: Ctrl) as the zoom modifier |
| A solid red block before the first clip | `TimelineView.originGapColor` fills the 32 px gutter before time 0 with `preRoll` `#FF5353` on any track holding video (blue for images, violet for audio). It is not an in/out range, a recording region or an error: it is the web app's pre-roll surface, and red there breaks Principle 2 |
| Ruler `00:00:00` to `01:00:00` over 41 s of clips | The ruler reads `MM:SS:FF`, so `01:00:00` is one minute and looks like one hour. The sequence keeps its longest length: `TimelineEditor.extendingDuration` only grows `sequence.durationFrames`, so moving or trimming the last clip back leaves seconds of black that play and export |
| Grey line across the empty area, no end mark | Fit spans `max(duration × 1.2, 60 s)`; nothing marks where the sequence ends |
| Loud orange "Color Grading" bar and a faint `fx` | Effect strips are filled with their identity colour behind 10 px bold dark text; the clip's `fx` is 10 px accent at 80% |
| Grey status-line hint | Drawn in `text3`, under 4.5:1 for 11 px text on `panelBg` |

## Zoom

- **Fit** shows the whole sequence: `[0, end + margin]` fills the track area, where `margin = max(1 s, 5% of end)`
  and an empty sequence spans at least 5 s. Fit is the zoom-out limit (100%); zooming out further only showed empty
  lanes. The zoom-in limit is unchanged: 48 px per frame at 30 fps.
- **Zoom to fit:** ⇧Z, ⌘0 (Ctrl+0), the Fit button, or a double-click on the zoom slider. It scrolls back to 0.
- **Zoom in / out:** ⌘+ / ⌘− (Ctrl on Linux and Windows) and the + / − buttons double or halve the zoom about the
  playhead when it is in view, else about the middle of the visible lanes. Dragging the slider anchors the same way.
- **Pointer zoom:** a trackpad pinch, ⌘ or Ctrl + scroll and Option (Alt) + scroll zoom about the pointer.
- **Readout:** the time one major ruler tick spans, for example `5 s/tick`, `10 f/tick` or `1 min/tick`, read from
  the ruler's own interval so it always matches the ticks. It replaces the percentage.
- **Disabled states:** − and Fit draw disabled at fit, + at the zoom-in limit.

Tests: `TimelineZoomTests` (fit span, limits, anchor), `TimelineZoomControlsTests` (keys, buttons, scroll,
readout).

## Track height

- Three presets in a segmented control after the track-height glyph: **S** (the minimum row height), **M** 48 px,
  **L** 72 px. The preset matching the current height is drawn pressed; a height saved from the old slider stays
  as it was and no preset is pressed.
- A 1 px divider and 8 px of space separate track height from zoom, so the two groups never read as one.

Tests: `TimelineZoomControlsTests.testTrackHeightPresets`.

## Toolbar names

Every toolbar control's name and shortcut is shown in the status line while the pointer is over it, for example
"Zoom to fit (⇧Z)", "Zoom in (⌘+)", "Medium tracks (48 px)", "Each ruler tick is 5 seconds". The text is the
existing `TimelineToolbar.tooltip(_:)`.

## Ruler and sequence end

- Ruler labels read `HH:MM:SS:FF` at every length, so a minute never looks like an hour.
- Ticks run from 0 to `end + margin` and stop there.
- **End marker:** a 1 px `timelineEndMarker` line from the ruler through every lane at the sequence end, with a
  6 px flag in the ruler. Pointing at it says "Sequence end 00:00:41:15: playback and export stop here".
- After the end, the ruler and lanes are shaded with `timelineOutOfRange`, so the space reads as outside the
  sequence rather than as unfinished lanes.
- **The sequence ends at its last clip.** Every edit sets `sequence.durationFrames` to the last clip end, so moving
  or trimming the last clip back shortens playback and export with it. A sequence with no clips keeps its length.

Tests: `TimelineSequenceEndTests`.

## Before the first clip

The 32 px gutter between the track headers and time 0 takes the lane colour. The red, blue and violet fills and the
`preRoll` token are removed: the clip colours and track tags already say what a track holds.

## Clip badges

- **`fx N`** sits right-aligned in the clip's header strip as a 14 px pill (ink at 12% behind ink at 80%, 9 px
  semibold), the same shape as an audio group's member count. N counts the clip's effects.
- **Effect strips** under the clip are quiet: a `timelineEffectStrip` fill with a 3 px edge in the effect's
  identity colour, and the effect name in 10 px medium `textSecondary` (4.5:1 in both modes).

Tests: `TimelineClipBadgeTests`, `ThemeTokensTests.testLightTextContrastIsAA`.

## Status line

Hints are drawn in `text2` (4.5:1 on `panelBg`). Over the timeline the line names the control or marker under the
pointer; elsewhere in the timeline it lists the main keys: "Space play · S split · I / O in and out · ⇧Z fit".

## Captures

Every change here is captured at 1440 × 900 and 1280 × 800 in dark and light (`TimelineControlsSnapshotTests`, PNGs
under `$MPVFX_SNAPSHOT_DIR`) and looked at before review.

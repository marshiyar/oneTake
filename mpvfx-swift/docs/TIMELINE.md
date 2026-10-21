# Timeline controls

How the timeline's zoom, track height, ruler, sequence end, clip badges and status-line hints look and behave. It
follows the principles in [DESIGN.md](DESIGN.md): one accent, red only for recording, cutting and errors, and every
control named where the user can read it. This is the target behaviour (specified 2026-10-21); each section names
the tests that hold it once its change has landed.

## Problems this replaces

Seen on a 41 s project at the default zoom (owner screenshots, 2026-10-21):

| Seen | Cause at `9039324` |
| --- | --- |
| Track height icon and slider, then zoom −, slider, + and "187%", with no names | The hover bubble (`TimelineRegion.drawTooltip`) says only "Track height", "Zoom out", "Zoom in" and, on the zoom slider, "187%": no shortcut and no meaning. The two sliders are drawn by the same `drawSlider` |
| "187%" | Percent of the fit zoom, a number with no meaning on the ruler |
| No way to fit the sequence except double-clicking the slider or ⌘0 | No fit button and no ⇧Z |
| ⌘+ / ⌘− zoom about the left edge, so the playhead leaves the view | `setZoom(percent:anchorX:)` defaults the anchor to `contentOrigin` |
| Option+scroll scrolls instead of zooming | Hosts pass only Control (GTK, Windows: Ctrl) as the zoom modifier |
| A solid red block before the first clip | The track colour: `TimelineView.originGapColor` fills the 32 px gutter before time 0 with `preRoll` `#FF5353` on any track holding video (blue for images, violet for audio). It is not an in/out range, a recording region or an error, but as a 32 px block in the lane area it reads as one, the user cannot change it, and red there breaks Principle 2 |
| Ruler `00:00:00` to `01:00:00` over 41 s of clips | The ruler reads `MM:SS:FF`, so `01:00:00` is one minute and looks like one hour. The sequence keeps its longest length: `TimelineEditor.extendingDuration` only grows `sequence.durationFrames`, so moving or trimming the last clip back leaves seconds of black that play and export |
| Grey line across the empty area, no end mark | Fit spans `max(duration × 1.2, 60 s)`; nothing marks where the sequence ends |
| Loud orange "Color Grading" bar and a faint `fx` | Effect strips are filled with their identity colour behind 10 px bold dark text; the clip's `fx` is 10 px accent at 80% |
| Grey status-line hint | Drawn in `text3`, under 4.5:1 for 11 px text on `panelBg` |

## Zoom

- **Fit** shows the whole sequence: `[0, end + margin]` fills the track area, where `margin = max(1 s, 5% of end)`
  and an empty sequence spans at least 5 s. Half the fit (50%) is the zoom-out limit: room to drag a clip past the
  end, never the minutes of empty lanes a tenth of the fit showed. The zoom-in limit is unchanged: 48 px per frame at
  30 fps.
- **Zoom to fit:** ⇧Z, ⌘0 (Ctrl+0), the Fit button, or a double-click on the zoom slider. It scrolls back to 0.
- **Zoom in / out:** ⌘+ / ⌘− (Ctrl on Linux and Windows) and the + / − buttons double or halve the zoom about the
  playhead when it is in view, else about the middle of the visible lanes. Dragging the slider anchors the same way.
- **Pointer zoom:** a trackpad pinch, ⌘ or Ctrl + scroll and Option (Alt) + scroll zoom about the pointer.
- **Readout:** the time one major ruler tick spans, for example `5 s/tick`, `10 f/tick` or `1 min/tick`, read from
  the ruler's own interval so it always matches the ticks. It replaces the percentage.
- **Disabled states:** − draws disabled at the zoom-out limit, Fit while the zoom is fit, + at the zoom-in limit.

Tests: `TimelineZoomFitTests` (fit span, limits, anchor, scroll), `TimelineZoomControlsTests` (⇧Z, buttons,
readout).

## Track height

- Three presets in a segmented control after the track-height glyph: **S** (the minimum row height), **M** 48 px,
  **L** 72 px. The preset matching the current height is drawn pressed; a height saved from the old slider stays
  as it was and no preset is pressed.
- A 1 px divider and 8 px of space separate track height from zoom, so the two groups never read as one.

Tests: `TimelineZoomControlsTests.testTrackHeightPresets`.

## Toolbar names

The hover bubble under each toolbar control gives its name and shortcut, for example "Zoom to fit (⇧Z)", "Zoom in
(⌘+)", "Medium tracks (48 px)", "Each ruler tick is 5 seconds". It never shows a bare number.

## Ruler and sequence end

- Ruler labels read `HH:MM:SS:FF` at every length, so a minute never looks like an hour.
- Ticks run from 0 to `end + margin` and stop there.
- **End marker:** a 1 px `timelineEndMarker` line from the ruler through every lane at the sequence end, with a
  6 px flag in the ruler pointing back into the sequence.
- After the end, the ruler and lanes are shaded with `timelineOutOfRange`, so the space reads as outside the
  sequence rather than as unfinished lanes.
- **The sequence ends at its last clip.** Every edit sets `sequence.durationFrames` to the last clip end, so moving
  or trimming the last clip back shortens playback and export with it. A sequence with no clips keeps its length.

Tests: `TimelineSequenceEndTests`.

## Track colour

- The 32 px gutter between the track headers and time 0 takes the lane colour; the `preRoll` token is removed.
- Each track's colour is a 3 px strip at the right edge of its header, beside the lanes (the left edge holds the audio
  group rail). Without a choice a track takes its kind's colour: video blue, audio green, anything else violet.
- Right-click a track header for its menu: eight colours (Blue, Teal, Green, Yellow, Orange, Red, Pink, Violet) and
  "Default". The choice is one undo step and is saved as `color` on the track in `project.json`; an unknown value
  reads as the default, never an error.
- Pointing at the strip shows "Track colour: Blue · right-click the header to change".
- Strips reach 3:1 on the header in dark and light.

Tests: `TimelineTrackColorTests`.

## Clip badges

- **`fx N`** sits right-aligned in the clip's header strip as a 14 px pill (ink at 12% behind ink at 80%, 9 px
  semibold), the same shape as an audio group's member count. N counts the clip's effects.
- **Effect strips** under the clip are quiet: a `timelineEffectStrip` fill with a 3 px edge in the effect's
  identity colour, and the effect name in 10 px medium `textSecondary` (4.5:1 in both modes).

Tests: `TimelineClipBadgeTests`, `ThemeTokensTests.testLightTextContrastIsAA`.

## Status line

Hints are drawn in `text2` (4.5:1 on `panelBg`; `text3` is under 4.5:1 for 11 px text). The timeline's hint lists
the main keys: "Space play · S split · I / O in and out · ⇧Z fit".

## Captures

Every change here is captured at 1440 × 900 and 1280 × 800 in dark and light (`TimelineControlsSnapshotTests`, PNGs
under `$MPVFX_SNAPSHOT_DIR`) and looked at before review.

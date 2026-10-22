# Keyframe Easing panel: spec

Owner request (2026-10-21): "for keyframe controls on easing and etc we could have its own seperate panel".
Today easing is the "Ease" segmented row at the end of the Transform group (and of Media for keyed volume) in the
Design inspector. At 280 pt its options draw over its label ("EasLinear", issue #154), and it can only show one
timing curve with no context: what the motion does over time, how fast it goes, or what the neighbouring keys do.

## 1. What the keyframe engine supports (cvkf.h API 1, keyframes 1.0.0 in binaries.lock)

| Capability | Engine | Panel |
| --- | --- | --- |
| Hold segment | yes (`CVKF_HOLD`) | Hold preset |
| Linear segment | yes (`CVKF_LINEAR`) | Linear preset |
| Cubic timing curve per segment, `(0,0) (x1,y1) (x2,y2) (1,1)`, x1/x2 in 0…1 (validated), y free | yes (`CVKF_CUBIC_BEZIER`) | Bézier handles, presets, influence and velocity |
| The curve belongs to the segment that **leaves** a key (`outgoing`) | yes | a key's out handle is its own `outgoing` (x1, y1); its in handle is the previous key's `outgoing` (x2, y2) |
| One timing curve for every component of a vec2 / rgba value | yes | position eases as one motion; no separate X/Y dimensions |
| Spatial path (curve / bezier) for vec2 segments | yes (`outgoingPath`) | not this panel (stage arc-motion rows) |
| Value at a frame, sampling | yes (`evaluate`, `sample`) | the value and speed graphs are drawn from engine-evaluated values, so the line shown is the motion rendered |
| Spring and bounce segments | no: engine issues #4/#5 | disabled "Spring" and "Bounce" presets |
| Direction of travel on a cubic that reverses (overshoot) | wrong today: engine issue #6 (tangentAngle) | the panel warns when an auto-rotating position key gets an overshooting curve |
| Per-dimension (separate X/Y) curves | supported by scalar position tracks | Separate dimensions converts straight position keys exactly; rejoin requires matching frames and easing |

Nothing in the panel needs an engine change: every edit is `setOutgoing` on authored keys through the existing
keyframe commands, so preview and export read it as they read the inspector's edits today.

## 2. Ease maths (MpvfxShared `KeyframeEase`)

- `progress(i, t)`: eased progress at segment fraction t (hold 0 until 1, linear t, cubic: solve x(s) = t, return y(s)).
- `slope(i, t)`: dy/dx, the normalised speed (1 = the linear speed of the segment).
- Influence and velocity, the After Effects model on this engine's curve:
  out influence = x1, out slope = y1 / x1; in influence = 1 − x2, in slope = (1 − y2) / (1 − x2).
  Velocity in units per second = slope × |Δvalue| / Δseconds of that segment.
  Converting back clamps influence to 0.1 %…100 % (x stays inside 0…1, as the engine validates) and y to the
  inspector's −1…2 range.
- Tested against the engine: `progress` × range equals the engine's evaluated value on every frame of number
  tracks with each preset and with overshooting curves, and the recorded golden (ease-in 0.42/0/1/1, 0→100 over 100
  frames, frame 50 = 31.5357) holds. Golden values are never changed.

## 3. The panel

A self-contained panel view, `KeyframeEasingPanel` (MpvfxPanels), registered with the docking model:
`id "keyframe-easing"`, title "Keyframe Easing", default dock `bottom` (beside the timeline), minimum size
360 × 300 pt (the tab layout scrolls when its column is taller than the panel). It also opens as a third tab of
the right panel, "Easing", beside Design and Renders.

Layout, top to bottom:
1. Header: property picker (the clip's animated, easable properties: position, x/y, size, rotation, scale, opacity,
   3D transform, volume), the key count ("3 keys selected" or "Key at playhead"), Copy ease, Paste ease.
2. Graph area, with a Value / Speed switch:
   - Value graph: the property's engine-evaluated value across its keyed range (one line per component), keys as
     diamonds (selected ones filled), playhead line.
   - Speed graph: |dvalue/dt| in units per second from the same samples; the selected segment's handles are drawn
     here and drag (horizontal = influence, vertical = velocity), as in a graph editor's speed view.
   - Zoom (⌘-scroll, or the − / + buttons) and pan (scroll, or drag on empty graph) of the time axis; "Fit" returns
     to the whole keyed range.
3. Segment curve: the normalised timing curve of the focused segment with its two draggable handles (the editor the
   inspector had), and a live preview of the motion: a dot that runs the eased progress next to a linear reference.
4. Presets: Linear, Ease in, Ease out, Ease in & out, Hold, then disabled Spring and Bounce (engine #4/#5), then the
   project's custom presets and "Save preset…".
5. Numbers: out influence %, out velocity, in influence %, in velocity (units/s of the property), and X1 Y1 X2 Y2.
6. "Separate dimensions" converts straight position keys to scalar X/Y tracks in one undo step, preserving key times and timing curves. Position X and Position Y then appear in the property picker. Toggle again to join when frames and easing match. Spatial paths, auto-orient, scalar static overrides, or independent X/Y key times/easing disable conversion with a status hint; conversion never samples or approximates motion.

Following the selection:
- Clip: the timeline/inspector selection. Property: the selected keys' property; else the last chosen property;
  else the clip's first animated easable property.
- Keys: the keys selected on the timeline on that clip and property; with none, the key at or before the playhead.
- Every apply (preset, paste, numbers, handle release, F9) edits **every** target key in **one** undo step labelled
  "Edit keyframe easing"; a drag commits once, on release.

Custom presets per project: `project.json` gains an optional `easingPresets: [{id, name, outgoing}]` (additive;
absent stays absent; validated: non-empty id, unique, name 1…64 characters, outgoing a valid interpolation).
Saving or deleting a preset is one undo step.

Copy / paste: Copy takes the focused key's outgoing curve; Paste applies it to every target key (one undo step).
The clipboard lives for the session.

## 4. Inspector, menu, shortcuts

- The inspector's "Keyframe easing" block shrinks to one row: the heading with its key count and an "Easing…"
  button that opens the panel on those keys. The segmented row, the curve and the four fields leave the inspector
  (fixes #154 for this row).
- The timeline keyframe menu's "Edit Easing…" opens the panel instead of scrolling the inspector.
- Menus: macOS View > "Keyframe Easing"; Linux and Windows have no menu bar, so the right panel's ☰ menu gets
  "Keyframe easing".
- Shortcuts (checked against the shortcuts the app binds, `ShortcutsPanel.swift` and the key handlers: no F-key
  is bound today; H already toggles hold / bezier and stays):
  F9 Easy ease, ⇧F9 Easy ease in, ⌘⇧F9 (Ctrl+Shift+F9) Easy ease out, on the selected keys, as After Effects binds
  them (https://helpx.adobe.com/after-effects/using/keyboard-shortcuts-reference.html, read 2026-10-21).
  Easy ease is influence 33.33 %, velocity 0 on that side of each key: its out side is the key's own outgoing curve,
  its in side the previous key's.

## 5. Tests first

- Ease maths: engine parity per frame, the 31.5357 golden, influence/velocity round trips, hostile input (NaN,
  x outside 0…1, zero-length segments).
- Model: target resolution (selection, property, playhead fallback, other clips ignored), apply-to-all, copy/paste,
  presets saved and deleted, easy ease in/out/both on first and last keys.
- Undo grouping: every apply over N keys is one undo step and undo restores every key.
- Interaction: handle drags (one commit on release), zoom/pan bounds, numeric fields clamp, disabled controls do
  nothing.
- Snapshots: the panel in dark and light at 1440 × 900 (window size; the panel at its docked size).

## 6. Slices

All four are built (2026-10-21); each is its own pull request, stacked in this order.

1. Ease maths + engine parity tests (MpvfxShared).
2. Custom presets in `project.json` (MpvfxShared) and the panel model with its edits (MpvfxPanels).
3. The panel view, the Easing tab, the inspector "Easing…" button (MpvfxPanels).
4. Wiring: selection following, "Edit Easing…", the menu items, F9 / ⇧F9 / ⌘⇧F9 (MpvfxDesktop, MpvfxTimeline).

<!-- markdownlint-disable-file MD043 -- the required-headings rule has no heading list configured, so any heading fails it -->

# Feature inventory

Every user-facing ability of the MpVFX editor, with its status at this revision. The editor is native on every
host: it is drawn on its own 2D canvas and edits one JSON project document; nothing runs HTML, CSS, JavaScript
or a web view. The design audit in §11 is the floor for how the editor looks.

Status words:

- **done**: implemented natively, wired into the running editor, covered by tests.
- **partial**: some of it works; the gap is named.
- **missing**: no native code yet. The owner lane named after it is who builds it.
- **dropped**: deliberately not built. Each one says why.
- **n/a**: no user-facing behaviour of its own.

Owner lanes: **panels** (side panels behaviour: left sidebar, inspector, Renders tab), **panels-visual** (the look
of `Sources/MpvfxPanels`), **timeline**, **preview** (player/stage), **export**, **backend**, **color-engine**
(`Sources/MpvfxColor`), **audio**, **mac-shell** (hosts, dialogs, menus), **unowned** (nobody has it yet).

Visual match (last column): **exact** = drawn from the design tokens with the design's sizes, spacing, type
and states; **close** = tokens and layout match, a detail (icon glyph, animation, metric) differs; **n/a** = not
drawn yet. Panel visuals are being re-matched pixel by pixel by panels-visual (6f7c223 left sidebar, 6f8e67e right
panel); rows marked exact for panels are its target, checked by its snapshot tests.

Design tokens live in `Sources/MpvfxPanels/PanelTheme.swift` and `Sources/MpvfxTheme/ThemeTokens.swift` (the
`studio.*` / `panel.*` colours, the Tailwind neutral/zinc palette and the body type).

## 1. Shell layout

The shell is `[left sidebar | preview | right panel]` over a full-width timeline (`PanelFit`).

| Ability | Swift status | Visual |
| --- | --- | --- |
| Three-column top row over full-width timeline | done (`PanelLayout`, `EditorShellLayout`) | exact |
| Panel width fitting (preview floor 360, left 200…384, right 280…424, 40% cap, seams 3 px) | done | exact |
| Auto-collapse to rails below 860 / 700 px, "reopened" override | done | exact |
| Drag-resize seams (13 px hit zone, 52 px hairline, hover/active tints) | done | exact |
| Keyboard nudge of a focused seam (±16 px) | missing (panels) | n/a |
| Collapse / show sidebars (rail with show button), "Hide sidebar" | done | exact |
| Persist widths, collapsed state, right tab, left tab | done (`<userData>/panel-layout.json`) | n/a |
| Dockable Scopes panel (Window / Panels → Scopes), Program frame at the playhead, waveform / parade / vectorscope / histogram; Tab/Enter and arrows choose the kind, saved with panel layout preferences | done (`DockedScopesPanelTests`, `ScopesDockShellTests`); closed by default, dock beside the preview or anywhere in the workspace | n/a |
| Timeline height resize (min 100, preview floor 200), persisted | done (shell router, `panel-layout.json`); arrow-key resize missing | close |
| Splash ("Starting video editor…", "Connecting to project…") | missing (mac-shell) | n/a |
| Toasts (dismiss, technical details) | partial: player toasts (recording, remove silence); no technical-details expander (preview) | close |
| Save queue paused banner ("Retry saving") | missing: save failures raise an error dialog (mac-shell) | n/a |
| External file conflict banner (keep / reload, copy or download the draft) | partial: native reload-or-keep dialog on external change (e6aa32a); copy/download of the draft missing (mac-shell) | n/a |
| Error boundary ("Something went wrong", Reload Studio) | n/a (no React tree); crash reporting missing | n/a |

## 2. Left sidebar

| Ability | Swift status | Visual |
| --- | --- | --- |
| Media-first header row: the library ▸ event switcher (one menu of libraries and events), Import (the primary button) and "…" | done (panels UI over `DesktopBackend` libraries; `LeftSidebarPanel+Header.swift`, `MediaPanelTests`) | n/a |
| "…" menu: New library, Open library, New event, Import into the event (copy into library / link originals), Show library in Finder (Files, File Explorer), Rename event, the event's projects (switch), Rename project, New project, Open project…, Open existing standalone project, Recent projects | done (`LeftSidebarPanel+Menus.swift`, `testMoreMenuRunsEveryLibraryAndProjectAction`) | n/a |
| Library media (files of the event not yet in this project) and Exports as grid sections and filter choices; add to the timeline, relink and Save to… on the tile (hover button, context menu, Enter) | done (`MediaSections.swift`, `testLibraryMediaAndExportsAreSectionsWithoutDuplicates`, `testTileHoverActionAddsAttachesAndSaves`) | n/a |
| Export records "Save to…" | done: a finished export's tile saves with the export extension and reports errors without replacing an unapproved destination (`LibrarySaveToTests`, `LibraryServiceTests`) | n/a |
| The standalone project status | done: the switcher's tooltip and status-line hint | n/a |
| Tab bar Media / Scenes / Elements (Scenes only with sub-compositions, Elements only with blocks) | done (Elements never shows: blocks dropped) | exact |
| Tab persisted, ←/→ and ⌘1/⌘2 tab switching | done | n/a |
| "+ Import media" button (file dialog) | done | exact |
| Drag-and-drop import from Finder / desktop onto the bin | done: MacCanvasHost (file URLs) and GtkCanvasHost (text/uri-list) hand dropped files to the session, which imports them through the backend (the bin lists them); dropped over the timeline's tracks the clips are also placed from the drop time on, one after another, with the drop outline while hovering (`EditorSession+AssetDrag.swift`). The import probes each picture's natural size (sample aspect, rotation, JPEG EXIF orientation) so the first frame drawn is already the fitted box on every insert path; a clip whose size is still probing is not drawn | close |
| Grouped text looks in the Media sidebar: title, name strap, rolling credits, animated in/out and vertical-video styles | done: six plain-data recipes; click/Enter or drag adds editable text at the playhead, one undo; only the platform default installed sans-serif, no unimported resources (`TextLookPresetTests`, `TextLookSidebarSessionTests`, `TextLookPresetRenderingTests`) | shared text painter |
| Search media, filter menu (kind, timeline use, order) with its summary line and Clear, "No media matches", Clear search / Clear filters; the choice is kept between launches (`media-bin.json` in the user-data folder) and the Filter button opens from the keyboard (Tab, Enter) | done (`testFilterNarrowsByKindAndTimelineUseAndSorts`, `testEmptyStatesOfferTheWayBack`, `MediaBinFilterPersistenceTests`) | n/a |
| Sections Video / Images / Audio / Fonts / Library media / Exports with counts, timeline media first by default | done | n/a |
| Tiles on one inset and grid (2 columns at 280 and 364 pt, 3 at 409 pt): thumbnails filling a 16:9 tile, duration badge, a check when in the timeline, "Missing" for a library file whose original is gone, names on two end-truncated lines with the full name in a tooltip; hover, selection and focus states | done (shared `MediaThumbnails`; `MediaPanelLayoutAuditTests`, `MediaPanelSnapshotTests`) | n/a |
| Keyboard: Tab through the header and into the grid, arrows across and down the grid, Enter adds, Shift+Enter opens the tile's menu, Escape clears | done (`testKeyboardMovesTheSelectionAndRunsTheAction`, `testTabWalksTheControlsThenTheGrid`) | n/a |
| Audio rows: icon, name, duration, waveform bars | done | exact |
| Asset preview overlay / audition (play an asset) | missing (panels) | n/a |
| Drag from bin to timeline (insert at drop time/track) | done: a 4 px drag starts it, the drop inserts at the pointer's time on the track under it when the kind fits and the track is unlocked (`EditorSession+AssetDrag.swift`); while over the tracks the drop outline shows (1 px accent/60 inside the tracks area, `AssetDropOutline`); edge auto-scroll during the drag is missing | close |
| Drag from bin to stage | done: the shell router keeps pointer capture and converts to player points; the player highlights the drop and inserts at the playhead | close |
| Asset context menu: Add at playhead, Copy path, Rename, Delete (+ remove placements, undoable) | done | exact |
| Double-click / Enter adds asset to timeline | done | n/a |
| Scenes tab: list compositions, select, add, render, delete | partial: the native document has one sequence; the tab lists it | close |
| Elements (blocks) tab, block search/categories, add at current time, block params | dropped: no native equivalent | n/a |
| Empty state "Drop media files here" | done | exact |

## 3. Right panel (inspector + renders)

The flat inspector is the one inspector: one accordion group open at a time.

| Ability | Swift status | Visual |
| --- | --- | --- |
| Header: hide button + Design / Renders (n) tabs | done | exact |
| Empty selection: the Composition section | done: with nothing selected the Design tab edits the composition size (preset select: Landscape 16:9, Portrait 9:16, Square 1:1, Vertical 4:5, 4K 16:9, Custom; W and H fields; the current size and ratio). One undo step, saved in `project.json`; untouched media clips refit, placed clips and text keep their size and offset from the centre (`InspectorPanel+Composition.swift`, `TimelineEditor.setCanvasSize`, `NativeCompositionSize.swift`) | close |
| Multi-select card with Group / Hide | partial: count and clear; Group and Hide missing (panels) | close |
| Element header: kind icon, name, meta, reset all, clear selection | done | close |
| Header hide toggle, Ungroup (⌘⇧G) | missing (panels) | n/a |
| Accordion: one open group, others as summary rows | done | exact |
| Value tiers (default / explicit default / custom + reset ↺) | done | exact |
| Transform: X, Y, W, H, rotation, scale | done (undoable, keyframes at the playhead when animated; audit tests 0996b1e) | exact |
| Transform: layer order | done: the Layer order field writes the clip's `layout.zIndex`, the stacking key preview and export share (the stage menu's z-order writes the same key); empty / reset returns to track order; test | close |
| Transform: flex align/justify/direction/gap | dropped: flex layout of web containers has no native counterpart | n/a |
| Keyframe diamond and prev/next per property | done: with the stopwatch (start / stop animating, keeping the playhead's value) on the same row | close |
| Keyframe easing presets (hold / linear / ease in/out) | done (setOutgoing) | close |
| Keyframe easing custom curve handles, per-segment ease list, apply to all | done in the Keyframe Easing panel (the right panel's Easing tab; the inspector's "Easing…", the keyframe menu's "Edit Easing…", the ☰ menu and macOS View > Keyframe Easing open it): value and speed graphs with draggable speed handles, zoom and pan, the segment curve with handles and a motion preview, presets plus the project's own (saved in `project.json`), copy / paste, influence and speed numbers, F9 / ⇧F9 / ⌘⇧F9 easy ease; every edit applies to every selected key in one undo step. Spring and bounce (#192) and separate dimensions (#193) are shown disabled until the engine or the document supports them (`docs/KEYFRAME_EASING.md`) | close |
| Ease curve editor (cubic bezier handles, spring, bounce params) | partial: cubic bezier handles work; spring and bounce parameters are missing (panels) | close |
| Arc motion (needs 2+ position keyframes; auto-rotate; reset control points) | done: Transform group rows (the note under 2 keyframes, Arc Motion switch, Auto-Rotate, curviness 0-3 per segment) write `setMotionPath` / `setAutoRotate`; preview and export draw the same curved path, and export now adds the auto-rotate tangent like the preview (it ignored it before); one audit test per control. Not ported: Reset of hand-placed bezier control points (no stage handles for them) | close |
| 3D transform: tilt X/Y, roll, depth, perspective, scale; cube widget; keyframe; reset orientation | missing (panels; recording writes 3D rotation, the inspector has no rows) | n/a |
| Style: opacity | done | exact |
| Style: blend modes (Normal, Multiply, Screen, Overlay, Add, Soft light, Darken, Lighten) | done: a Blend select beside Opacity in the Style group, one undo step per pick, reset back to Normal; saved as `clip.style.blend` (absent = Normal). Each blended layer is painted alone, then mixed pixel by pixel with what is under it by `BlendShader` (the W3C separable blend functions); a preview frame holding a blended layer is painted on the raster surface export uses, so the two give the same bytes. The shading body (`MpvfxColor.metal`) carries the same functions and the Vulkan and Direct3D 11 sources are regenerated from it | close |
| Style: solid fill, stroke (width 0-200, none/solid, color), shadow presets (none/soft/lift/glow) | done: stored on the clip as `clip.style` (validated, JSON round-trip tests); the preview draws fill, inside stroke and shadows with the clip's transform; export pads the box with the fill, draws the stroke with `drawbox` and lays Gaussian-blurred shadows under the box on both the static and the keyframed path (real-render tests); one audit test per control | close |
| Style: gradient / image fill, dashed and other stroke styles, blend, layer blur, backdrop, border radius, overflow | missing (panels + preview + export) | n/a |
| Color picker (hue, alpha, hex, mixed) | partial: fill and stroke take a hex field (#rgb, #rrggbb, #rrggbbaa, "transparent"); the hue/alpha picker popover is missing (panels) | n/a |
| Crop: start/apply/cancel/reset, per-side and All insets, link edges | done | exact |
| Mask inset rows | missing (panels) | n/a |
| Clip timing: start, end, duration | removed on purpose (2026-10-13): the timeline rows move, trim and split clips; speed stays as Rate in Media (see §13) | n/a |
| Media: volume, muted, rate, media start, play video sound | done | exact |
| Media: fit (Fit, Fill, Stretch) | done: the Media group's Fit select on video and image clips, one undo step, with the reset back to Fit; saved as `clip.fit` (absent = Fit, so older projects open and save unchanged). Fill covers the box keeping the aspect and clips the overflow; Stretch maps the picture onto the box; an untouched Fill or Stretch clip's box is the whole frame. Preview and export draw it with one painter (`NativeClipLayout.swift` `nativeMediaRect`, `PreviewComposition.swift`, `InspectorPanel+MediaFit.swift`) | close |
| Media: loop, object position | missing in the native document (panels + preview) | n/a |
| Align / distribute | done (#449): six align buttons in Transform, frame/selection reference; three or more visual clips distribute with equal edge gaps. Multi-selection supports the same keyboard-operable controls. Existing position parameters are written at the playhead when animated, in one undo step. Only the changed component is keyed, preserving 2D path tangents and the untouched axis; a single selection uses the frame reference; preview/export share their existing painter (`AlignmentTests`, `AlignmentInspectorTests`, `AlignmentPainterTests`) | exact |
| Text: content, multiple fields, font picker, size, weight, color, align, letter spacing, line height, case/style | partial: native text layers (`clip.text` on a Text element asset; T adds one at the playhead). The Text group comes first, in this order: Content (`\n` breaks a line), Font (family name), Size, Weight (number or label), Letter spacing (px/em), Line height (multiple, %, px, normal), Align L/C/R/J, Case · Style, Color (hex). Preview and export draw one layout (`TextLayout`: wrap at the box width, half-leading line boxes, justify, per-character spacing); export rasterizes it with the preview's renderer into a still the clip renders like an image, so transform, crop, style and opacity apply. Missing: several text fields per layer, the font picker popover, the colour picker | close |
| Import local font files | partial: fonts import into the media bin (Fonts category); a text layer uses an installed family by name, not an imported file yet | n/a |
| Grade: presets, intensity, primary adjust, color wheels (shadows/midtones/highlights with hue/amount/level and reset) | done; renders in preview and export (color-engine, 3fe63d2 / 5dbd897), on the GPU (Metal) on macOS, graded off the main thread at display size in preview | close |
| Grade: curves Master/R/G/B and Hue vs Hue/Sat/Luma; click or Enter adds a point; delete; reset | done; renders | close |
| Grade: secondaries (add/delete selection, hue/sat/luma qualifier, correction) | done; renders. Eyedropper ("Click a color to initialize this selection") missing (panels) | close |
| Grade: custom LUT dropdown and import, LUT strength | done; renders | close |
| Grade: finish (vignette midpoint/roundness/feather, grain size/roughness) | done; renders | close |
| Grade: copy grade to current file media / all project media | done | close |
| Saved looks: save, rename and delete named grade/effect looks in user data, apply to selected clips | implemented (#456): Design’s Saved looks group; name field and buttons are keyboard-operable. Durable `looks.json` writes; one apply undo step; missing LUT is a typed actionable error. Saved effects use the existing preview/export painter (`UserLookTests`, `UserLookDurableWriteTests`, `UserLookRenderParityTests`) | close |
| Grade: Auto balance (Exposure, Warmth and Tint from the frame's statistics; one undo step; Tab + Enter) | done (`AutoBalanceTests`) | close |
| Grade: Match reference look (choose another visual clip; Exposure, Contrast and Offset from exact frames and alpha-weighted channel/luma statistics; context-bound pending work; editable, one undo step; Tab/Enter) | done (`LookMatchTests`, `LookMatchInspectorTests`, `LookMatchPainterTests`) | close |
| Grade: scopes (histogram, RGB parade, vectorscope, refresh) | partial: luma waveform, RGB overlay, RGB parade, vectorscope with targets, skin line and zoom, luma + RGB histogram and false colour work for the selected clip or the composited program (Clip / Program switch), up to four at once (`docs/SCOPES.md`); CIE diagram and a full-size view are missing | close |
| Grade: hold to show original; captured-frame preset preview thumbnails | missing (panels) | n/a |
| Effects: amount per stylize effect (18), reset effects | done; renders in preview and export (Metal kernels on macOS, incl. blur/bloom/Kuwahara passes) (schema in `docs/EFFECTS.md`) | close |
| Effects: families with add-effect menu (apply defaults), per-effect settings (sizes, angles, glitch blocks…), palette picker and custom palette | missing (panels; the renderer already reads every setting and the palette) | n/a |
| Clip effects other than the grade (listed with enable toggle and remove) | partial: listed and toggleable; not rendered, and export refuses them | close |
| Audio FX: presets by family, EQ (Tone) bands, signal chain with bypass / remove / clear | done (edits `audioFxChain`, undoable; playback and export hear it) | close |
| Audio FX: add menu with descriptions, per-node parameter editing, move up/down | missing (panels; coordinate with swift-audiofx-hang on these rows) | n/a |
| Audio FX: voiceover carve, leveller ("even out its loud and quiet parts"), audition, preset run amount | missing UI (panels); DSP exists in `MpvfxAudioGraph` | n/a |
| Audio group bus rack (opened from the timeline group header FX / name buttons) | done (de10f47): the inspector shows the bus's FX chain and Group volume; a popover form is not drawn (panels-visual) | close |
| Audio group volume | done | exact |
| Dockable Mixer (`mixer`): per audio track gain in dB, pan, mute/solo, and live peak/RMS | done: Window/Panels; persisted gain/pan and undo; same graph for playback/export | n/a |
| Renders tab: format / output size / frame rate / quality, custom width, Export | done (settings in `preferences.json`; export through `RenderRun`, 38d06b3). Output size scales the composition with its aspect kept: "Composition" (its own size), 720p … 8K by the short edge (720p of a 9:16 composition is 720×1280), or a custom width with the height following (`CompositionRenderResolution.swift`); a fixed preset saved earlier reads as its short edge. Formats are the media engine's: MP4 and MOV (PNG, alpha); WebM is not offered (a saved WebM setting shows "WebM (not supported yet)" and Export refuses it) | close |
| Render list: progress, stage, cancel, delete, reveal, retry, hide finished, history across launches, thumbnails | done (38d06b3; real-render test) | close |
| Render list: ETA | missing (panels) | n/a |
| Caption property panel (style, animation entrance/exit/highlight, transform) | missing (unowned) | n/a |
| Classic inspector (Layout, Stacking, Z-index, classic style/media/text sections) | dropped: the flat inspector is the product | n/a |

## 4. Preview / canvas (preview and mac-shell lanes)

| Ability | Swift status |
| --- | --- |
| Multi-track composited preview with crop, transform, opacity; hidden tracks and hidden clips left out | done (player) |
| Move / resize / rotate handles, crop handles, marquee, shift multi-select, group move | done (player): the transform box has eight handles (edges stretch Size W or H; corners scale, keeping the aspect on images and video unless ⇧, free on text and shapes unless ⇧; ⌥ scales about the anchor), rotation by the chip or just outside a corner (⇧ 15° steps), a draggable anchor that scale and rotation pivot on (double-click recentres it; kept for the session, not saved: the document has no anchor parameter), ⇧ axis lock on moves, ⌘/Ctrl drags without snapping, resize snapping of the dragged side, a W × H / angle / X Y readout beside the cursor, one undo step per drag, keyframes at the playhead on animated properties, locked tracks refused; 24 pt targets at any zoom (`PlayerController+Transform.swift`, `TransformBox*Tests`). Native system cursors on GTK, AppKit and Win32 follow the box and stay synchronized after modifier/capture changes and Settings redraws without pointer motion (`StageHostCursorTests`, `StageHostCursorRefreshTests`). Not built: flip by dragging past the opposite side, skew (no document parameter) |
| Snap guides & toolbar, grid overlay (thirds/quarters/center, snap to grid) | done (player) |
| Arrow-key nudge (1 / 10 px, one commit per burst), Esc cancels a drag | done (player) |
| Record motion (position, rotation, 3D rotation, opacity, scale, depth): Record or R arms; a press on the selected layer or a handle starts a take that plays from the playhead, the layer keeps its grab offset, release commits one "Record motion" undo step, Esc cancels or disarms; locked and hidden layers refused; one sample per frame, simplified | done (player; `PlayerController+Record.swift`, `GestureRecording.swift`; `RecordMotionTests`, `RecordMotionShellTests`) |
| Canvas context menu (z-order, delete) with the crossed-sibling flash | partial: z-order and delete work; copy and paste are missing |
| Asset drop on the stage (insert at playhead) | done: bin cards drag into it (`EditorSession+AssetDrag.swift`) |
| Preview zoom / pan (wheel, pinch, middle-button drag), zoom readout, fit button | done (player, hosts forward the middle button) |
| Stage frame at the composition size (landscape, portrait, square, custom), letterboxed in the viewport; follows a size change at once | done (player; `PortraitPreviewTests`) |
| Snap, grid, zoom, playback rate, mute, volume persisted (`<userData>/ui-preferences.json`) | done |
| Reverse playback / J-K-L shuttle without per-frame seeks | done (chunked reverse decode) |
| Fullscreen (button, F, Esc), chrome hidden while playing | done |
| Inline text editing toolbar | missing: text layers exist (edited in the inspector's Text group); no on-canvas editing yet |
| Composition breadcrumb | n/a: no sub-compositions in the native document |
| Color grade and stylize effects in the preview | done: raw frames cached, graded off the main thread at display size (Metal on macOS with the source frame kept on the GPU between edits, CPU shader on Linux with a 960x540 draft first); draws never wait, rapid edits coalesce to the newest value; a grade edit never restarts a decoder or flushes the cache |

Deliberate deviation (user decision, 2026-10-13): every outline that marks a media item's real bounds on the stage is a
square, pixel-aligned rectangle (radius 0, edges snapped to device pixels). Handles keep
their shape (`PlayerView+Outlines.swift`).

- Selection outline / transform frame: square 2px.
- Multi-select member outlines and group box: square 1px / 2px.
- Marquee candidates and marquee box: square, pixel-aligned.
- Crop frame and its edge lines: square, pixel-aligned; the crop mask clips the media to a square, pixel-aligned box.
- Hover outline: square 2px.
- Asset drop target on the stage: square 2px over the composition frame.
- Stage / composition frame (project-resolution rectangle) and its clip: square, pixel-aligned 1px border.
- Z-order crossed flash: square 2px.
- Snap guide lines: pixel-aligned 1px.
- Media content: drawn and exported with square corners (no rounded clipping in preview or export).

## 5. Timeline (timeline lane)

| Ability | Swift status |
| --- | --- |
| Move, trim, split, multi-select, marquee, razor (⇧ splits all tracks), delete | done |
| Split at scene changes (#447) | implemented: selected constant-speed video, toolbar scissors or Cmd/Ctrl+Alt+S while timeline/player focused; RGB frame difference at 64×64, threshold 10–90% (click percentage to cycle, Cmd/Ctrl+Alt+[ / ] to adjust), progress, click again or Esc to cancel, one undo step. Speed ramps and held frames are refused. Threshold is a transient analysis option; resulting clips use the existing document format. Swift tests pending compilation. |
| Slip (Y tool, ⌘/Ctrl+⌥ drag) and roll (roll tool, ⇧ drag on a shared edge) | done (one track; no two-up source monitor during the slip) |
| Ripple edits, close gap / close all gaps, track add/remove/reorder, snapping, copy/paste | done |
| Toolbar: tools, snap, keyframe, auto-keyframe, split, remove silence, add beat, track height 32–96, zoom slider/in/out/percent (1e3a90f) | partial: everything works except Add beat, which stays disabled until beat analysis exists |
| Remove silence (backend silence detection → one undo step, result toast) | done (de10f47) |
| Add beat at playhead, beat strip (drag to move, ⌥-click delete), music beat analysis, beat edits persisted | missing (unowned: needs a native beat analysis and the beat file) |
| Keyframe lanes, keyframe navigation in lane headers, group keyframe toggle (6671f11) | done |
| Keyframe diamond context menu (delete, delete all, ease presets) | partial: right-click a diamond for Move to Playhead, Linear / Ease In / Ease Out / Ease In-Out / Hold (checked when every target key shares it), Edit Easing… (opens the Keyframe Easing panel on the keys), Delete Keyframe(s) and Delete All Keyframes (the clip bar's channels, or the lane's group); it acts on the key selection when the diamond is part of it, each edit one undo step (`TimelineKeyframeMenu.swift`); "Edit Incoming Segment Ease…" is not ported |
| Audio groups: create, header FX count, FX button / name open the bus rack, detach/reattach audio, mute | done |
| Detach / Reattach audio from the clip menu: offered on any video clip with a media file (native clips carry no preview binding); detach probes the file for an audio stream, puts a linked audio clip on a new audio row with the same timing, trim, rate, gain, group, FX and automation and mutes the video (its Mute row hidden); reattach refuses after a move / trim / retime or a broken link with a message naming why; one undo step each; preview and export play the sound once | done |
| Clip fades: fade-in and fade-out lengths on a clip (`fadeInFrames` / `fadeOutFrames`, independent of keyframes), a linear gain ramp on the clip's sound heard the same in playback and export; split keeps the fade-in on the left part and the fade-out on the right, trims and speed changes clamp them (#85) | partial: in the document, playback and export (`NativeClipFade.swift`, `AudioGraph.swift` `ClipFadeRamp`); video opacity and timeline fade handles not yet built |
| Volume automation lanes, automation selection menu (Simplify), value input | partial: automation plays and exports; lane editing UI partial |
| Filmstrips and waveforms from the shared media cache, Show thumbnails toggle (314d72a, 71fdbd6) | done |
| Undo history persists across sessions per project (751c6c7) | done |
| Clip context menu (split, cut, copy, paste, duplicate, thumbnails, mute, keep audio pitch, detach / reattach audio, delete), track gap context menu | done |

The timeline lane's 314d72a added its own filmstrip cache; 71fdbd6 moved strips and peaks onto the session's one
`MediaThumbnails` cache.

## 6. Export (export lane)

| Ability | Swift status |
| --- | --- |
| Media-engine export of the native document (MP4 H.264 + FLAC, MOV PNG + LPCM with alpha; WebM refused; multi-track, crop, keyframes, audio groups/FX/automation, presets, fps, quality, range) | done |
| Color grade and stylize effects in export (5dbd897) | done; graded on the GPU (Metal) on macOS, CPU shader on Linux |
| Other clip effects | refused with a message (no renderer) |
| Render queue UI, history, cancel, reveal (Renders tab) | done (panels, 38d06b3) |
| Library exports (snapshot, export record) | done (backend; Renders tab tracks them) |

## 7. Project, history, files (backend lane)

| Ability | Swift status |
| --- | --- |
| Create / open / save project, durable transactions, autosave each edit | done |
| Media import with codec policy | done |
| Undo/redo, persisted across sessions | done |
| External file change detection, reload or keep | done |
| Open projects saved by earlier versions (older `mediaEngine` names or none; element layers from an earlier version of the editor kept unchanged, skipped in preview and export, one notice on open) | done (`NativeMediaEngine`, `isUndrawnElementClip`; `ExportStartOutcomeTests`, `MediaTimelineTests`, `NativeProjectDocumentTests`) |

## 8. Menus, dialogs, shortcuts

| Ability | Swift status |
| --- | --- |
| Playback: Space, J/K/L, M, ⇧L, ←/→, ⇧←/⇧→, F | done |
| Keyframes: K, Del, , / ., H, U, R | partial (K, Del, , / . nudge, U, R done; H missing) |
| Editing: ⌘C/⌘V/⌘X, S, ⌘G/⌘⇧G, Del, ⌘D | partial (timeline lane) |
| Undo/redo ⌘Z / ⌘⇧Z / Ctrl+Y | done |
| Panels: ⌘1 / ⌘2 switch left sidebar tab | done |
| Work area: I, O, ⇧I, ⇧O, A, E | done |
| Import ⌘I, Save ⌘S | done |
| Shortcuts panel (every shortcut by section) | done (`ShortcutsPanel.swift`) |
| Speed menu, volume popover, loop playback | done |
| Native menu bar (File / Edit / View) | partial (mac-shell `MenuModel`) |
| Settings window | done: Cmd/Ctrl+, (macOS: MpVFX > Settings…) opens a Settings card over the editor with appearance (System/Light/Dark), interface size (100–200 %), audio output device, preview cache size and the default export folder, persisted in `<userData>/preferences.json` and fully keyboard-operable (`SettingsPanel.swift`, `InterfaceScaleTests`; see the Settings rows in [STATUS.md](STATUS.md)) |

## 9. Recording, captions, other

| Ability | Swift status |
| --- | --- |
| Record motion (Record control with armed and recording states, stage outline and banner, trail, auto-stop, one undo step) | done (preview) |
| Captions: caption track in the document, SRT import and export (backend) | partial: no menu entry yet (see `STATUS.md`) |
| Captions: overlay, caption timeline, caption editing, caption property panel, Edit captions entry in the preview | missing (unowned) |
| Telemetry, crash prompt, feedback card | not part of the product |
| Packaging and installers | partial: macOS disk image, Windows per-user setup.exe and Linux .deb; CI has built, installed and launched all three, and their smoke checks passed (see `STATUS.md`) |

## 10. Conditional features

Features that only show in some states, and what the editor does with each.

| Feature | Status |
| --- | --- |
| Flat inspector | done: the only inspector |
| Timeline row virtualization | n/a: the canvas timeline draws visible rows only |
| Show thumbnails toggle | done (toggle persisted) |
| Test hooks | `MPVFX_SMOKE_*` environment hooks |
| Feedback card, crash feedback prompt, telemetry | not part of the product |
| Scenes (sub-sequences) | partial (one sequence) |
| Inline text toolbar (bold / italic / underline / colour) | missing |

## 11. Design audit (2026-10-13)

Every item of the owner's screenshot review, with its status now.

| Item | Status |
| --- | --- |
| Libraries header with New library / Open | done; moved into the Media panel's "…" menu (2026-10-21) |
| Library picker; Event/"Media" picker + New event; Project picker + New project | done; the library ▸ event switcher, projects and New event / New project in "…" (2026-10-21) |
| Collapsible "Library media (N)" and "Library exports (N)" | done; now the Library media and Exports sections of the grid (2026-10-21) |
| Show library in Finder; Open existing standalone project | done; in "…" (2026-10-21) |
| "+ Import media" button; collapse-sidebar control | done; Import is the header row's primary button (2026-10-21) |
| Search assets field | done; Search media with the filter menu (2026-10-21) |
| Media bin grouped by type with real thumbnails, duration badge, "Added" badge, filenames | done; the "Added" badge is a check now, names wrap to two lines (2026-10-21) |
| Player top bar: Record, Crop, snap/magnet toggle, grid/guides dropdown | done (preview) |
| Real decoded video frame | done (preview) |
| Selection outline with corner handles | done (preview) |
| Transport: timecode, play, volume, speed, loop, fullscreen, captions | partial: everything works except the captions button |
| Right panel collapse toggle; Design / Renders (N) tabs | done |
| Selected clip header: name, reset, visibility, close | partial: name, reset and close work; visibility is missing (panels) |
| Color wheels Shadows / Midtones / Highlights with wheel, slider, Hue / Amount / Level, per-wheel reset | done |
| Curves Master, R, G, B, Hue/Hue, Hue/Sat, Hue/Luma; editable graph; reset | done |
| Secondary color: add / delete selection | done (eyedropper missing) |
| Custom LUT dropdown | done |
| Finish section and the other sections (transform, crop, opacity) | done |
| Timeline toolbar: select, blade, link/ripple, keyframe add/navigate, tools, track height, zoom | done (timeline) |
| Track header: name, clip count, eye, speaker, FX | done (timeline) |
| Filmstrips, waveforms, adjustment ("Color") strip | done (timeline) |
| Selected clip outline; mm:ss ruler; playhead | done (timeline) |
| Same palette, typography, spacing and icons | in progress (panels-visual; snapshot tests) |

## 12. Dropped on purpose

| Ability | Why |
| --- | --- |
| Elements/blocks registry tab and block params | No native equivalent |
| Telemetry and feedback card | Not part of the product |
| Animation cards (tween presets) | Native keyframes cover animation |
| Attribute / style / source patching panels | Every edit is a native document command |
| Classic inspector | The flat inspector is the product |
| Inspector Clip timing group (start / end / duration fields) | Removed 2026-10-13 at the user's request: unnecessary and confusing next to the timeline thumbnail rows, which already move, trim and split clips. The document model and the timeline trim/split/move commands are unchanged; playback speed stays in the Media group (Rate). Timing coverage moved to timeline-gesture tests (InspectorRenderAuditTests `testTimeline*`). |

## 13. Recently landed

| Ability | Swift status | Visual |
| --- | --- | --- |
| Background generator clips (#452) | done: the Media panel menu adds Solid colour, Linear gradient or Radial gradient at the playhead (keyboard: Tab to the menu, Enter, arrows, Enter). Design > Background edits alpha-capable colours, linear angle in degrees, and radial centre coordinates from 0 to 1. Every insertion/edit is one undo step. The generator is saved on its element clip in `project.json`, validates and round-trips, and preview/export/scopes share the procedural painter. Transform, crop, masks and opacity use the ordinary clip path; unrelated element layers stay undrawn | n/a |
| Cut transitions (dissolve, dip, wipe, push) | done: select either clip at a touching cut and open Design > Transition. Add/remove a transition, choose Dissolve, Dip, Wipe or Push, and edit duration in frames. Wipe and Push have Left/Right/Up/Down directions; Wipe has edge softness; Dip offers black or white. Tab reaches every control; Space selects an option and Enter commits duration. Each edit is one undo step. Wipe and Push need source handles on both sides, with shared picture/audio timing. Preview and export use the same canvas-space painter. Still missing: timeline handles to add, resize or remove a transition, and a Transitions tab | close |
| Sequence markers (#409) | done: M in the focused timeline adds a named marker at the playhead. The Window menu opens the dockable Markers panel (`markers`), initially closed. Click/Enter jumps; double-click/F2 edits the name, Tab chooses time in seconds, #RRGGBB color and note, Enter saves, Escape cancels, Delete removes. Add/edit/delete each undo in one step. Optional `sequence.markers` preserves older projects and unknown marker fields (`Tests/MpvfxPanelsTests/MarkersPanelTests.swift`) | n/a |
| Dockable Mixer (#408) | done: Window / Panels opens the Mixer (`mixer`); each audio track has gain −60…+12 dB, pan −1…+1, mute, solo and live peak/RMS meters. Gain/pan persist on the track and share the playback/export graph (`MixerPanelTests`, `MixerGraphTests`) | n/a |
| Voice recording (#317) | done: transport Record button and ⌥Space with 0–5 s count-in and microphone selection in Settings, live meter with clip latch, Space keeps the WAV as an ordinary audio clip on the Voice track and Esc discards it; overlapping takes are muted and retained, one undo step per kept take; sub-frame silence aligns the first sample with input latency. Punch-in and pre-roll remain #318 (`VoiceTransportTests`, `TimelineVoiceTests`) | n/a |
| Saved looks, auto balance, reference look matching | done: Design > Saved looks stores named grades durably (`looks.json`); Auto balance and Match look fit ordinary grade values from frame statistics in one undo step (`UserLookTests`, `AutoBalanceTests`, `LookMatchTests`) | close |

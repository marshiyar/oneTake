//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (c) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
import Foundation
import MpvfxShared
import MpvfxCanvas

/// Pure interaction logic for the timeline. Hosts (GTK/Win32/AppKit) forward pointer, wheel and
/// key events in view coordinates and redraw when `needsDisplay` fires.
public final class TimelineController {
    public let view: TimelineView
    public let playback: PlaybackState
    public let editor: TimelineEditor?
    public var viewport = CanvasSize(0, 0) { didSet { relayout() } }
    public private(set) var zoomMode: TimelineZoomMode = .fit
    public private(set) var manualZoomPercent = 100.0
    public var needsDisplay: (() -> Void)?
    public static let dragThresholdPx = 3.0

    enum Gesture {
        case scrub
        case pendingMove(clipId: String, row: Int, x: Double, y: Double)
        case move(ids: [String], grabbed: String, anchorRow: Int, x: Double, y: Double)
        case trim(clipId: String, edge: TrimEdge, ripple: Bool)
        case slip(clipId: String, x: Double)
        case roll(clipId: String, edge: TrimEdge)
        case pendingMarquee(x: Double, y: Double, base: Set<String>)
        case marquee(x: Double, y: Double, base: Set<String>)
    }
    public enum Tool: Equatable, Sendable { case select, razor, slip, roll }
    /// Toolbar tool. Razor: click splits the clip, ⇧click splits every track. Slip (Y): drag a clip to change which part
    /// of its media plays. Roll: drag the edge between two touching clips (TimelineController+SlipRoll.swift).
    public var tool: Tool = .select { didSet { if tool != .razor { view.razorGuideX = nil }; needsDisplay?() } }
    public static let marqueeThresholdPx = 4.0
    public static let splitEpsilon = 1e-3
    /// The last ⌘C / ⌘X. It outlives a project switch in the window, so clips paste into the other project.
    public internal(set) var clipboard: TimelineClipboard?
    /// The last grade copied with ⌥⌘C. It is intentionally separate from the ordinary clip clipboard.
    public internal(set) var gradeClipboard: TimelineGradeClipboard?
    /// Actionable status for menus, tooltips, and the host status line.
    public private(set) var gradePasteStatus = "Copy a grade before pasting"
    /// Timeline snapping (clip edges, playhead, beats) for moves and trims; N toggles it.
    public var snapEnabled = true { didSet { if snapEnabled != oldValue { onSnapChange?(snapEnabled) } } }
    /// Magnet toggled (N / toolbar); hosts persist it (studioUiPreferences timelineSnapEnabled).
    public var onSnapChange: ((Bool) -> Void)?
    /// Clip menu "Show thumbnails" flipped the timeline-wide thumbnail mode.
    public var onThumbnailModeChange: ((Bool) -> Void)?
    var gesture: Gesture?
    /// A press on a keyframe diamond (select on click, retime on drag); takes priority over every clip gesture.
    var keyframeGesture: KeyframeGesture?
    /// Keys selected when a marquee started (⇧ marquee adds to them).
    var marqueeKeyframeBase: Set<TimelineKeyframeRef> = []
    /// The live clip drag resolved against the document (rows, overlap, new track); committed on release.
    var movePlan: TimelineMovePlan?
    /// Option/Alt held: a clip drop onto a busy row keeps the original placement instead of swapping. Hosts set it from
    /// the pointer's modifiers; a change mid-drag re-resolves the landing at the last pointer position.
    public var dragSwapDisabled = false {
        didSet { if dragSwapDisabled != oldValue, case .move? = gesture, let p = lastMovePoint { pointerMove(x: p.x, y: p.y) } }
    }
    var lastMovePoint: (x: Double, y: Double)?
    /// Header FX button on a single-audio-clip track: open the FX popover / rack for the clip, anchored at the rect.
    public var onOpenClipFx: ((_ clipId: String, _ anchor: CanvasRect) -> Void)?
    /// Header group pointer: ask for a group name (clip count, default label); the host then calls groupSelectedAudio(label:).
    public var onRequestGroupName: ((_ clipCount: Int, _ defaultLabel: String) -> Void)?
    public internal(set) var lastHeaderAction: HeaderAction?
    /// Group header FX button: open the group's FX popover anchored at the rect (TimelineFxPopover on the bus chain).
    public var onOpenGroupFx: ((_ groupId: String, _ anchor: CanvasRect) -> Void)?
    /// Group name button: open the group's FX rack (onOpenFxRack).
    public var onOpenGroupFxRack: ((_ groupId: String) -> Void)?
    /// Toolbar auto-keyframe (playerStore autoKeyframeEnabled): manual property edits may start animation.
    public var autoKeyframeEnabled = false { didSet { needsDisplay?() } }
    /// Track height changed from the toolbar; hosts persist it (studio UI preferences).
    public var onTrackHeightChange: ((Double) -> Void)?
    /// Zoom mode / manual percent changed (buttons, slider, pinch, fit); hosts persist them
    /// (studioUiPreferences timelineZoomMode / timelineManualZoomPercent).
    public var onZoomChange: ((TimelineZoomMode, Double) -> Void)?

    public init(view: TimelineView, playback: PlaybackState, editor: TimelineEditor? = nil) {
        self.view = view; self.playback = playback; self.editor = editor
        view.laneNavigation = { [weak self] id, lane in self?.laneNavigation(clipId: id, lane: lane) ?? TimelineKeyframeNavigation() }
        view.laneRowNavigation = { [weak self] id, row in self?.laneNavigation(clipId: id, row: row) ?? TimelineKeyframeNavigation() }
        if let editor { reload(from: editor) }
        editor?.onChange = { [weak self] in guard let self, let e = self.editor else { return }; self.reload(from: e) }
    }

    /// Clips that already had lanes (auto-expand only fires when a clip first gains them).
    var clipsWithLanes: Set<String> = []
    public var hasAudioStream: (String) -> Bool = { _ in true }
    public enum NativeAudioAction: String, Sendable { case detach, reattach }
    /// Clip menu Detach / Reattach audio (timelineCallbacks onNativeAudioAction). Unset: the editor edits directly.
    public var onNativeAudioAction: ((_ clipId: String, _ action: NativeAudioAction) -> Void)?
    /// Paste from another project: copies `paths` (absolute media and LUT files outside this project) into it and
    /// calls `done` with each path's copy (project-relative), or nil when any of them could not be brought in (the
    /// host says why); the paste then goes ahead with the copies, or not at all. Unset: the paste keeps the
    /// absolute paths, which preview can play but export refuses.
    public var importForPaste: ((_ paths: [String], _ done: @escaping ([String: String]?) -> Void) -> Void)?
    /// T: put a text layer at the playhead (the host adds it and opens its Text section). Unset: T does nothing.
    public var onAddText: ((_ time: Double) -> Void)?
    /// ⇧H / ⌥⇧H: how long a new hold lasts, in seconds (the host sets it from Settings).
    public var holdSeconds = TimelineEditor.defaultHoldSeconds
    /// An edit key was refused, with the reason to show (a locked track, no clip under the playhead). Unset: silent.
    public var onEditRefused: ((_ message: String) -> Void)?
    /// Keyframe menu "Edit Easing…": show the inspector's easing editor on these keys of the clip. Unset: the item is
    /// disabled.
    public var onEditKeyframeEasing: ((_ clipId: String, _ refs: Set<TimelineKeyframeRef>) -> Void)?

    func reload(from e: TimelineEditor) {
        let all = e.tracks
        let groups = e.timelineGroups
        view.groups = groups
        view.collapsedGroups = view.collapsedGroups.intersection(groups.map(\.id))
        let visible = all.filter { t in t.groupId.map { !view.collapsedGroups.contains($0) } ?? true }
        view.groupAnchors = groups.compactMap { g in
            guard let first = all.firstIndex(where: { $0.groupId == g.id }) else { return nil }
            let before = all[..<first].filter { t in visible.contains { $0.id == t.id } }.count
            return (g.id, before)
        }
        view.tracks = visible; view.allTracks = all
        view.markers = e.document.sequence.markers ?? []
        // A keyed clip starts with its one summary row; expanded rows and folded kinds are kept per clip while it exists.
        let clipIds = Set(all.flatMap(\.clips).map(\.id))
        view.expandedClips.formIntersection(clipIds)
        view.collapsedKinds = view.collapsedKinds.filter { clipIds.contains($0.key) }
        clipsWithLanes = Set(all.flatMap(\.clips).filter { !$0.lanes.isEmpty }.map(\.id))
        view.duration = max(e.duration, 0)
        view.frameRate = e.fps
        playback.duration = view.duration; playback.fps = e.fps
        if playback.currentTime > view.duration { playback.seek(view.duration) }
        let ids = Set(view.tracks.flatMap(\.clips).map(\.id))
        view.selection = view.selection.intersection(ids)
        pruneKeyframeSelection()
        relayout()
    }

    public var fitPixelsPerSecond: Double {
        TimelineZoom.fitPixelsPerSecond(viewportWidth: viewport.width, duration: view.duration, contentOrigin: TimelineLayout.contentOrigin)
    }

    public func relayout() {
        view.pixelsPerSecond = TimelineZoom.pixelsPerSecond(fit: fitPixelsPerSecond, mode: zoomMode, manual: manualZoomPercent)
        clampScroll(); syncFromPlayback()
    }

    public func syncFromPlayback() { view.currentTime = playback.currentTime; needsDisplay?() }

    func clampScroll() {
        let extent = TimelineZoom.span(duration: view.duration) * view.pixelsPerSecond
        let maxX = max(0, TimelineLayout.contentOrigin + extent - viewport.width)
        let maxY = max(0, view.contentHeight - viewport.height)
        view.scrollX = max(0, min(maxX, view.scrollX)); view.scrollY = max(0, min(maxY, view.scrollY))
    }

    /// Where a button, key or slider zoom is anchored: the playhead while it is in view, else the middle of the lanes.
    public var zoomAnchorX: Double {
        TimelineZoom.anchorX(playheadX: view.x(for: view.currentTime), contentLeft: TimelineLayout.contentOrigin, viewportWidth: viewport.width)
    }

    /// Zoom keeping the time under `anchorX` (default `zoomAnchorX`) fixed on screen.
    public func setZoom(percent: Double, anchorX: Double? = nil) {
        applyZoom(TimelineZoom.clamp(percent, fit: fitPixelsPerSecond), anchorX: anchorX)
    }
    func applyZoom(_ clampedPercent: Double, anchorX: Double?) {
        let ax = anchorX ?? zoomAnchorX
        let anchorTime = view.time(forX: ax)
        zoomMode = .manual; manualZoomPercent = clampedPercent
        view.pixelsPerSecond = TimelineZoom.pixelsPerSecond(fit: fitPixelsPerSecond, mode: zoomMode, manual: manualZoomPercent)
        view.scrollX = TimelineLayout.contentOrigin + anchorTime * view.pixelsPerSecond - ax
        clampScroll(); onZoomChange?(zoomMode, manualZoomPercent); needsDisplay?()
    }
    /// Zoom to an exact absolute scale (within the zoom limits), whatever the fit is at this viewport and duration.
    public func setZoom(pixelsPerSecond pps: Double, anchorX: Double? = nil) {
        let fit = fitPixelsPerSecond
        applyZoom(TimelineZoom.clamp(pps / max(fit, 1e-9) * 100, fit: fit, rounded: false), anchorX: anchorX)
    }
    public func zoom(in dirIn: Bool) { setZoom(percent: TimelineZoom.next(dirIn, mode: zoomMode, manual: manualZoomPercent, fit: fitPixelsPerSecond)) }
    public func zoomToFit() { zoomMode = .fit; view.scrollX = 0; relayout(); onZoomChange?(zoomMode, manualZoomPercent) }
    /// Restore a persisted zoom without reporting it back (studioUiPreferences on startup).
    public func restoreZoom(mode: TimelineZoomMode, manualPercent: Double) {
        zoomMode = mode
        if manualPercent.isFinite, manualPercent > 0 { manualZoomPercent = manualPercent }
        relayout()
    }

    // MARK: Hit testing

    public enum Hit: Equatable {
        case ruler, header(row: Int), clip(id: String, row: Int, edge: TrimEdge?), empty(row: Int?)
        /// Audio-group header row; `caret` when on the 24px collapse toggle.
        case groupHeader(id: String, caret: Bool)
        /// An effect strip or expanded property lane under a clip's media bar.
        case clipExtra(id: String, row: Int)
    }

    public func hitTest(x: Double, y: Double) -> Hit {
        if y < TimelineLayout.rulerHeight { return x >= TimelineLayout.contentOrigin ? .ruler : .empty(row: nil) }
        guard let (band, localY) = view.band(atY: y) else { return .empty(row: nil) }
        let row: Int
        switch band {
        case .group(let id): return .groupHeader(id: id, caret: x >= 6 && x <= 30 && abs(localY - TimelineLayout.groupHeaderHeight / 2) <= 12)
        case .track(let i): row = i
        }
        if x < TimelineLayout.contentOrigin { return .header(row: row) }
        if localY >= view.trackHeight {
            // Below the media bar: effect strips / lanes belong to the clip spanning x.
            let t = view.time(forX: x)
            if let c = view.tracks[row].clips.last(where: { t >= $0.start && t <= $0.end }) {
                let used = Double(c.effects.count) * TimelineLayout.effectStripHeight
                    + (c.lanes.isEmpty ? 0 : Double(view.trackLaneRows(row).count)) * TimelineLayout.laneHeight
                let effTop = Double(view.effectLaneCount(track: row)) * TimelineLayout.effectStripHeight
                let off = localY - view.trackHeight
                let inEffects = off < Double(c.effects.count) * TimelineLayout.effectStripHeight
                let inLanes = !c.lanes.isEmpty && off >= effTop && off < effTop + Double(view.trackLaneRows(row).count) * TimelineLayout.laneHeight
                if used > 0 && (inEffects || inLanes) { return .clipExtra(id: c.id, row: row) }
            }
            return .empty(row: row)
        }
        for clip in view.tracks[row].clips.reversed() {
            let r = view.clipRect(track: row, clip, preview: false)
            guard x >= r.x, x <= r.maxX, y >= r.y, y <= r.maxY else { continue }
            // Trim handles: 14px strips, shown when hovered/selected (showHandles).
            let w = min(TimelineLayout.clipHandleWidth, r.width / 3)
            let edge: TrimEdge? = x <= r.x + w ? .start : x >= r.maxX - w ? .end : nil
            return .clip(id: clip.id, row: row, edge: edge)
        }
        return .empty(row: row)
    }

    func clip(_ id: String) -> (row: Int, clip: TimelineClipModel)? {
        for (i, t) in view.tracks.enumerated() { if let c = t.clips.first(where: { $0.id == id }) { return (i, c) } }
        return nil
    }

    public enum Cursor: Equatable { case normal, resize, move, pointer, slip, roll }
    public internal(set) var cursor: Cursor = .normal

    // MARK: Pointer

    /// `alt` on a trim handle makes the trim ripple (later clips on the lane follow the edge).
    public func pointerDown(x: Double, y: Double, shift: Bool = false, alt: Bool = false) {
        pointerDown(x: x, y: y, keys: TimelineGestureKeys(shift: shift, alt: alt))
    }

    /// A press with every modifier: `command` (⌘/Ctrl) adds to the selection like `shift`; on a clip ⌘/Ctrl+⌥ slips it
    /// and ⇧ on an edge rolls the cut (`clipPointerDown`).
    public func pointerDown(x: Double, y: Double, keys: TimelineGestureKeys) {
        if menuPointerDown(x: x, y: y) { return }
        let shift = keys.shift || keys.command
        let hit = hitTest(x: x, y: y)
        if tool == .razor, x >= TimelineLayout.contentOrigin, y >= TimelineLayout.rulerHeight {
            razorClick(x: x, hit: hit, shift: shift); return
        }
        // Diamonds sit above the clip body and trim handles (TimelineClipDiamonds z-index 5, pointerdown stops there).
        if let kh = view.keyframeHit(x: x, y: y) { keyframePointerDown(kh, x: x, y: y, shift: shift); return }
        hitPointerDown(hit, x: x, y: y, keys: keys)
        needsDisplay?()
    }

    func scrub(to x: Double) {
        let t = max(0, min(view.duration, view.time(forX: x)))
        if playback.isPlaying { playback.pause() }
        playback.seek(t); syncFromPlayback()
    }

    var snapClips: [(key: String, start: Double, duration: Double)] {
        view.tracks.flatMap(\.clips).map { ($0.id, $0.start, $0.duration) }
    }

    public func pointerMove(x: Double, y: Double) {
        if view.gapMenu != nil { gapMenuHover(x: x, y: y); return }
        if let m = view.clipMenu {
            let a = m.item(atX: x, y: y)?.action
            if a != m.hovered { view.clipMenu?.hovered = a; needsDisplay?() }
            return
        }
        if let m = view.keyframeMenu {
            let a = m.item(atX: x, y: y)?.action
            if a != m.hovered { view.keyframeMenu?.hovered = a; needsDisplay?() }
            return
        }
        if tool == .razor && gesture == nil {
            let gx: Double? = x >= TimelineLayout.contentOrigin ? x : nil
            if gx != view.razorGuideX { view.razorGuideX = gx; needsDisplay?() }
        }
        if keyframeGesture != nil { keyframePointerMove(x: x); return }
        guard let g = gesture else {
            if tool == .select, keyframeHover(x: x, y: y) { return }
            let hit = hitTest(x: x, y: y); updateHeaderHover(hit, x: x, y: y)
            let (hovered, cur) = hoverState(hit)
            if hovered != view.hoveredClip || cur != cursor { view.hoveredClip = hovered; cursor = cur; needsDisplay?() }
            return
        }
        switch g {
        case .scrub: scrub(to: x)
        case let .pendingMarquee(x0, y0, base):
            guard abs(x - x0) >= Self.marqueeThresholdPx || abs(y - y0) >= Self.marqueeThresholdPx else { return }
            gesture = .marquee(x: x0, y: y0, base: base); pointerMove(x: x, y: y)
        case let .marquee(x0, y0, base):
            let r = CanvasRect(x: min(x0, x), y: min(y0, y), width: abs(x - x0), height: abs(y - y0))
            view.marquee = r
            var ids = base
            for (i, t) in view.tracks.enumerated() {
                for c in t.clips {
                    var cr = view.clipRect(track: i, c, preview: false); cr.width = max(cr.width, 4)
                    if cr.x < r.maxX && cr.maxX > r.x && cr.y < r.maxY && cr.maxY > r.y { ids.insert(c.id) }
                }
            }
            // Keys under the box win; the clip selection stays as it was (useTimelineRangeSelection keyRects).
            let keys = view.keyframeRefs(in: r)
            if keys.isEmpty { view.selection = ids; view.selectedKeyframes = marqueeKeyframeBase }
            else { view.selectedKeyframes = marqueeKeyframeBase.union(keys) }
            needsDisplay?()
        case let .pendingMove(id, row, x0, y0):
            guard hypot(x - x0, y - y0) >= Self.dragThresholdPx else { return }
            gesture = .move(ids: Array(view.selection.contains(id) ? view.selection : [id]).sorted(), grabbed: id, anchorRow: row, x: x0, y: y0)
            cursor = .move; pointerMove(x: x, y: y)
        case let .move(ids, grabbed, anchorRow, x0, y0):
            lastMovePoint = (x, y)
            guard let lead = ids.compactMap({ clip($0) }).min(by: { $0.clip.start < $1.clip.start }) else { return }
            let raw = lead.clip.start + (x - x0) / view.pixelsPerSecond
            let targets = snapEnabled ? TimelineSnapping.targets(clips: snapClips, playhead: playback.currentTime, beats: view.beats.map(\.time), excluding: Set(ids)) : []
            let groupEnd = ids.compactMap { clip($0)?.clip.end }.max() ?? lead.clip.end
            let snapped = TimelineSnapping.snapMove(start: raw, duration: groupEnd - lead.clip.start, targets, pps: view.pixelsPerSecond,
                                                    timelineDuration: .greatestFiniteMagnitude)
            if let editor {
                updateMovePlan(editor, ids: ids, grabbed: grabbed, anchorRow: anchorRow, deltaSeconds: snapped.start - lead.clip.start,
                               snapTime: snapped.snap?.time, x0: x0, y0: y0, y: y)
                view.snapType = snapped.snap?.type
                needsDisplay?(); return
            }
            let rowNow = view.trackIndex(nearY: y)
            let minRow = ids.compactMap { clip($0)?.row }.min() ?? anchorRow, maxRow = ids.compactMap { clip($0)?.row }.max() ?? anchorRow
            let td = max(-minRow, min(view.tracks.count - 1 - maxRow, rowNow - anchorRow))
            view.drag = .move(clipIds: ids, deltaSeconds: snapped.start - lead.clip.start, trackDelta: td, snapTime: snapped.snap?.time)
            view.snapType = snapped.snap?.type
            needsDisplay?()
        case let .trim(id, edge, _):
            guard let (_, c) = clip(id) else { return }
            let minDur = 1 / max(playback.fps, 1)
            let targets = snapEnabled ? TimelineSnapping.targets(clips: snapClips, playhead: playback.currentTime, beats: view.beats.map(\.time), excluding: [id]) : []
            let s = TimelineSnapping.snap(view.time(forX: x), targets, thresholdSecs: TimelineSnapping.snapPx / max(view.pixelsPerSecond, 1))
            let t = edge == .start ? max(0, min(c.end - minDur, s.time)) : max(c.start + minDur, s.time)
            view.drag = .trim(clipId: id, edge: edge, time: t, snapTime: s.target?.time)
            view.snapType = s.target?.type
            needsDisplay?()
        default: slipRollMove(g, x: x)   // .slip, .roll
        }
    }

    public func pointerUp(x: Double, y: Double) {
        if keyframeGesture != nil { keyframePointerUp(); return }
        let rippleTrim: Bool = { if case .trim(_, _, true)? = gesture { return true }; return false }()
        defer { gesture = nil; movePlan = nil; view.dropTarget = nil; view.dragLiftY = 0; view.drag = nil; view.snapType = nil; view.marquee = nil; view.scrubbing = false; cursor = .normal; needsDisplay?() }
        guard let editor, let drag = view.drag else { return }
        let fps = editor.fps
        switch drag {
        case let .move(ids, delta, td, _):
            if let plan = movePlan {
                if editor.commitMove(plan) { view.selection = Set(plan.clipIds) }
                return
            }
            guard delta != 0 || td != 0 else { return }
            let moves: [NativeProjectClipMove] = ids.compactMap { id in
                guard let (row, c) = clip(id), let addr = editor.address(clipId: id) else { return nil }
                let dest = view.tracks[max(0, min(view.tracks.count - 1, row + td))].id
                return NativeProjectClipMove(address: addr, destination: .init(trackId: dest, startFrame: max(0, ((c.start + delta) * fps).rounded())))
            }
            if moves.count == 1 { editor.apply(.move(address: moves[0].address, destination: moves[0].destination)) }
            else if !moves.isEmpty { editor.apply(.moveMany(moves)) }
        case let .trim(id, edge, t, _):
            guard let addr = editor.address(clipId: id) else { return }
            let frame = (t * fps).rounded()
            if rippleTrim { editor.rippleTrim(clipId: id, edge: edge, toFrame: frame); return }
            editor.apply(edge == .start ? .trimIn(address: addr, startFrame: frame) : .trimOut(address: addr, endFrameExclusive: frame))
        default: commitSlipRoll(drag)    // .slip, .roll
        }
    }

    /// Wheel: `ctrl` (the host's zoom modifier: ⌘, Ctrl or Option / Alt held, or a pinch; `PointerModifiers.zoomsWheel`)
    /// zooms at the pointer, Shift = horizontal scroll, else vertical scroll (horizontal deltas from touchpads scroll
    /// horizontally).
    public func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool) {
        if ctrl {
            setZoom(percent: TimelineZoom.pinch(deltaY: dy, mode: zoomMode, manual: manualZoomPercent, fit: fitPixelsPerSecond), anchorX: max(x, TimelineLayout.contentOrigin))
            return
        }
        if shift { view.scrollX += dy + dx } else { view.scrollX += dx; view.scrollY += dy }
        clampScroll(); needsDisplay?()
    }

    // MARK: Keyboard (timeline-owned edit shortcuts; playback keys fall through to PlaybackState)

    @discardableResult public func keyDown(_ k: EditorKey) -> Bool {
        if case .function(9) = k.code { return easyEaseSelectedKeyframes(k) }
        if k.command, case .char(let ch) = k.code {
            switch Character(ch.lowercased()) {
            case "z":
                view.selectedKeyframes = []   // keyframeHistoryState: undo/redo clear the key selection
                return k.shift ? (editor?.redo() ?? false) : (editor?.undo() ?? false)
            case "y" where !k.meta: return editor?.redo() ?? false
            case "=", "+", "-", "0": return zoomKey(Character(ch.lowercased()))
            case "a" where !k.shift && !k.alt: return selectAll()
            case "d" where !k.shift && !k.alt: return duplicateSelection()
            case "c" where k.alt: return copyGradeSelection()
            case "v" where k.alt: return pasteGradeSelection()
            case "c": return copySelection()
            case "x": guard copySelection() else { return false }; return deleteSelection()
            case "v": return pasteClipboard()
            case "k" where !k.alt: return keySelectedProperties(animatedOnly: k.shift)
            default: return false
            }
        }
        if !k.command, !k.alt, k.shift, case .char(let ch) = k.code, ch.lowercased() == "z" { zoomToFit(); return true }
        if let held = holdKey(k) { return held }
        if !k.command && !k.alt {
            switch k.code {
            case .delete where !view.selectedKeyframes.isEmpty, .backspace where !view.selectedKeyframes.isEmpty:
                return deleteSelectedKeyframes()
            case .char(let ch) where (ch == "," || ch == "." || ch == "<" || ch == ">") && !view.selectedKeyframes.isEmpty:
                // , / . nudge the selected keys one frame (⇧ ten).
                return nudgeSelectedKeyframes(direction: ch == "," || ch == "<" ? -1 : 1, large: k.shift) || true
            case .delete, .backspace:
                // ⇧Delete: ripple delete (the lane closes up behind the removed clips).
                return k.shift ? rippleDeleteSelection() : deleteSelection()
            case .escape:
                if view.gapMenu != nil { view.gapMenu = nil; view.gapHighlight = [] }
                else if view.clipMenu != nil { view.clipMenu = nil }
                else if view.keyframeMenu != nil { view.keyframeMenu = nil }
                else if keyframeGesture != nil { keyframeGesture = nil; view.keyframeDrag = nil; view.keyframeSnapTime = nil; view.snapType = nil }
                else if view.drag != nil || view.marquee != nil { gesture = nil; view.drag = nil; view.marquee = nil }
                // dispatchPlainAppKey: Esc in razor clears the selection if any, else returns to select.
                else if tool == .razor && view.selection.isEmpty { tool = .select }
                else { view.selection = []; view.selectedKeyframes = [] }
                needsDisplay?(); return true
            case .char(let ch) where (ch == "m" || ch == "M") && !k.shift:
                if !k.isRepeat { _ = editor?.addMarker(at: playback.currentTime) }; return true
            case .char(let ch) where (ch == "b" || ch == "B") && !k.shift:
                tool = tool == .razor ? .select : .razor; return true
            case .char(let ch) where (ch == "v" || ch == "V") && !k.shift:
                tool = .select; return true
            case .char(let ch) where (ch == "y" || ch == "Y") && !k.shift:
                tool = tool == .slip ? .select : .slip; return true
            case .char(let ch) where (ch == "n" || ch == "N") && !k.shift:
                // N toggles timeline snapping (TimelineToolbar).
                snapEnabled.toggle(); needsDisplay?(); return true
            case .char(let ch) where (ch == "t" || ch == "T") && !k.shift && onAddText != nil:
                onAddText?(playback.currentTime); return true
            case .char(let ch) where (ch == "u" || ch == "U") && !k.shift:
                return toggleExpandSelection()
            case .char(let ch) where ch == "s" || ch == "S":
                return splitAtPlayhead()
            default: break
            }
        }
        let handled = playback.keyDown(k)
        if handled { syncFromPlayback() }
        return handled
    }

    /// S: split selected clips under the playhead (else every clip under it).
    @discardableResult public func splitAtPlayhead() -> Bool {
        guard let editor else { return false }
        let frame = (playback.currentTime * editor.fps).rounded()
        let t = frame / editor.fps
        let under = view.tracks.flatMap(\.clips).filter { $0.start < t && $0.end > t }
        let chosen = under.filter { view.selection.contains($0.id) }
        return editor.split((chosen.isEmpty ? under : chosen).map(\.id), atFrame: frame)
    }

    @discardableResult func deleteSelection() -> Bool {
        guard let editor, !view.selection.isEmpty else { return false }
        let addrs = view.selection.sorted().compactMap { editor.address(clipId: $0) }
        if editor.apply(addrs.count == 1 ? .delete(address: addrs[0]) : .deleteMany(addrs)) { view.selection = [] }
        return true
    }

    // MARK: Clipboard (⌘C / ⌘X / ⌘V)
    @discardableResult public func copySelection() -> Bool {
        guard let editor, !view.selection.isEmpty, let board = editor.copyClips(view.selection) else { return false }
        clipboard = board; return true
    }

    @discardableResult public func copyGradeSelection() -> Bool {
        guard let editor, let id = view.selection.first, let board = editor.copyGrade(id) else {
            gradePasteStatus = "Select a video or image clip with a grade to copy"; return false
        }
        gradeClipboard = board; gradePasteStatus = "Grade copied"; needsDisplay?(); return true
    }

    @discardableResult public func pasteGradeSelection() -> Bool {
        guard let editor, let board = gradeClipboard else { gradePasteStatus = "Copy a grade before pasting"; return false }
        guard !view.selection.isEmpty else { gradePasteStatus = "Select at least one video or image clip to paste a grade"; return false }
        let selection = view.selection
        let files = editor.filesToImport(board)
        guard let importForPaste, !files.isEmpty else { return finishGradePaste(board, onto: selection) }
        let projectId = editor.document.id, dir = editor.projectDirectory
        importForPaste(files) { [weak self] copies in
            guard let self, let copies, let editor = self.editor, editor.document.id == projectId, editor.projectDirectory == dir else { return }
            _ = self.finishGradePaste(board.rebased(copies), onto: selection)
        }
        return true
    }

    @discardableResult private func finishGradePaste(_ board: TimelineGradeClipboard, onto ids: Set<String>) -> Bool {
        guard let editor else { return false }
        guard let result = editor.pasteGrade(board, onto: ids) else {
            gradePasteStatus = editor.lastFailure?.message ?? "The grade could not be pasted"; needsDisplay?(); return false
        }
        gradePasteStatus = result.message; needsDisplay?(); return true
    }

    /// Pastes at the playhead onto `trackId`; nil = onto the track of the topmost selected clip, or with nothing
    /// selected back onto the tracks the clips came from (TimelineEditor.paste).
    @discardableResult public func pasteClipboard(onto trackId: String? = nil) -> Bool {
        guard let editor, let clipboard else { return false }
        let target = trackId ?? view.tracks.first { t in t.clips.contains { view.selection.contains($0.id) } }?.id
        let time = playback.currentTime
        let files = editor.filesToImport(clipboard)
        guard let importForPaste, !files.isEmpty else { return paste(clipboard, at: time, onto: target) }
        let projectId = editor.document.id, dir = editor.projectDirectory
        importForPaste(files) { [weak self] copies in
            // The project may have been switched while the files were copied: paste only into the same one.
            guard let self, let copies, let editor = self.editor, editor.document.id == projectId, editor.projectDirectory == dir else { return }
            self.paste(clipboard.rebased(copies), at: time, onto: target)
        }
        return true
    }

    @discardableResult private func paste(_ board: TimelineClipboard, at time: Double, onto target: String?) -> Bool {
        guard let editor else { return false }
        let ids = editor.paste(board, at: time, onto: target)
        if !ids.isEmpty { view.selection = Set(ids) }
        needsDisplay?(); return !ids.isEmpty
    }

    // MARK: Razor
    func razorClick(x: Double, hit: Hit, shift: Bool) {
        guard let editor else { return }
        let t = view.time(forX: x)
        if shift {
            // Split every clip under the pointer, all tracks (onRazorSplitAll).
            let frame = (t * editor.fps).rounded()
            let under = view.tracks.flatMap(\.clips).filter { $0.start + Self.splitEpsilon < frame / editor.fps && frame / editor.fps < $0.end - Self.splitEpsilon }
            editor.split(under.map(\.id), atFrame: frame)
        } else if case let .clip(id, _, _) = hit, let (_, c) = clip(id), let a = editor.address(clipId: id) {
            let clamped = max(c.start + Self.splitEpsilon, min(c.end - Self.splitEpsilon, t))
            let frame = (clamped * editor.fps).rounded()
            if frame / editor.fps > c.start && frame / editor.fps < c.end { editor.apply(.split(address: a, splitFrame: frame)) }
        }
        needsDisplay?()
    }

    // MARK: Gap context menu (TrackGapContextMenu, drawn)
    /// Right-click on empty lane space opens the gap menu; elsewhere it closes it.
    public func secondaryClick(x: Double, y: Double) {
        view.clipMenu = nil; view.keyframeMenu = nil
        // Diamonds sit above the clip body here too: their own menu, never the clip's.
        if let kh = view.keyframeHit(x: x, y: y) { openKeyframeMenu(kh, x: x, y: y); view.gapMenu = nil; needsDisplay?(); return }
        let hit = hitTest(x: x, y: y)
        switch hit {
        case let .clip(id, _, _), let .clipExtra(id, _): openClipMenu(id, x: x, y: y); view.gapMenu = nil; needsDisplay?(); return
        default: break
        }
        guard case let .empty(row?) = hit, x >= TimelineLayout.contentOrigin else { view.gapMenu = nil; needsDisplay?(); return }
        let track = view.tracks[row], t = view.time(forX: x)
        let g = TimelineGaps.gap(at: t, in: track.clips)
        let any = !TimelineGaps.intervals(track.clips).isEmpty
        var m = TimelineView.GapMenu(x: x, y: y, row: row, time: t, gapWidth: g.map { $0.gapEnd - $0.gapStart },
                                     canCloseGap: g != nil && editor != nil, canCloseAll: any && editor != nil, hasAnyGaps: any)
        // Flip like the original (menuWidth 200, height 68) when it would overflow the viewport.
        if m.x + TimelineView.GapMenu.width > viewport.width { m.x -= TimelineView.GapMenu.width }
        let over = m.y + TimelineView.GapMenu.height - viewport.height
        if over > 0 { m.y -= over + 8 }
        view.gapMenu = m; view.gapHighlight = []
        needsDisplay?()
    }

    func gapMenuHover(x: Double, y: Double) {
        guard let m = view.gapMenu else { return }
        let item = m.item(atX: x, y: y)
        let track = view.tracks[m.row]
        var hl: [(row: Int, start: Double, end: Double)] = []
        if item == 0, m.canCloseGap, let g = TimelineGaps.gap(at: m.time, in: track.clips) { hl = [(m.row, g.gapStart, g.gapEnd)] }
        if item == 1, m.canCloseAll { hl = TimelineGaps.intervals(track.clips).map { (m.row, $0.start, $0.end) } }
        if item != m.hovered || hl.count != view.gapHighlight.count { view.gapMenu?.hovered = item; view.gapHighlight = hl; needsDisplay?() }
    }

    func gapMenuClick(x: Double, y: Double) {
        guard let m = view.gapMenu else { return }
        let item = m.item(atX: x, y: y)
        let trackId = view.tracks[m.row].id
        if item == 0 && m.canCloseGap { editor?.closeGap(trackId: trackId, at: m.time) }
        if item == 1 && m.canCloseAll { editor?.closeAllGaps(trackId: trackId) }
        if item != nil && !(item == 0 ? m.canCloseGap : m.canCloseAll) { return }   // disabled row: menu stays
        view.gapMenu = nil; view.gapHighlight = []
        needsDisplay?()
    }
}

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
import MpvfxTimeline
import MpvfxAudioGraph

/// Builds the flat inspector's groups for the selected clip, in this order:
/// Text (text clips), Transform, Style, Effects, Audio FX, Media. Every row edits through TimelineEditor. There is no Clip timing group
/// (start / end / duration): the timeline rows move, trim and split clips (docs/FEATURES.md).
extension InspectorPanel {
    struct Selected {
        let id: String
        let track: NativeProjectTrack
        let clip: NativeProjectClip
        let asset: NativeProjectAsset?
        var kind: NativeProjectAssetKind { asset?.kind ?? .element }
        var isVisual: Bool { kind == .video || kind == .image || kind == .element }
        var hasAudio: Bool { kind == .audio || kind == .video }
    }

    func selected() -> Selected? {
        guard let editor, selection.count == 1, let id = selection.first, let (t, c) = editor.clip(id) else { return nil }
        return Selected(id: id, track: t, clip: c, asset: editor.document.assets.first { $0.id == c.assetId })
    }

    /// The audio group whose bus rack is open (opened from a timeline group header) while no clip is selected.
    func selectedBus() -> NativeAudioGroup? {
        guard let editor, selection.isEmpty, let id = audioGroupId else { return nil }
        return editor.audioGroup(id)
    }

    func buildGroups() -> [InspectorGroup] {
        if let editor, let g = selectedBus() { return [busFxGroup(editor, g)] }
        if let editor, showsComposition { return [compositionGroup(editor)] }
        guard let editor, let s = selected() else { return [] }
        var groups: [InspectorGroup] = []
        if let text = textGroup(editor, s) { groups.append(text) }
        if s.isVisual { groups.append(transformGroup(editor, s)); groups.append(styleGroup(editor, s)) }
        if s.kind == .video || s.kind == .image {
            groups.append(gradeGroup(editor, s))
            groups.append(stylizeGroup(editor, s))
        }
        if s.clip.effects.contains(where: { $0.effectId != ColorGrading.effectId }) { groups.append(effectsGroup(editor, s)) }
        if s.hasAudio { groups.append(audioFxGroup(editor, s)) }
        if s.kind != .element { groups.append(mediaGroup(editor, s)) }
        if editor.isClipLocked(s.id) {   // a locked track refuses edits: say so instead of offering dead controls
            return groups.map { InspectorGroup(id: $0.id, title: $0.title, summary: $0.summary,
                                               rows: [.init(.note("This clip's track is locked. Unlock the track in the timeline to edit it."))]) }
        }
        return groups
    }

    // MARK: Shared row factories

    /// Runs one inspector edit as a named undo step (TimelineEditor.withHistory), then refreshes the host.
    func edited(_ op: @autoclosure () -> Bool, label: String? = nil) {
        let title = label ?? buildGroupTitle()
        let ok = editor?.withHistory(title) { op() } ?? op()
        if ok { onEdited?() }
    }
    private func buildGroupTitle() -> String {
        switch openGroupId {
        case "text": "Edit text"; case "layout": "Edit transform"; case "style": "Edit style"; case "grade": "Edit color grade"
        case "effects": "Edit effects"; case "audio-fx": "Edit audio effects"; case "media": "Edit media"; default: "Edit properties"
        }
    }

    func keyframe(_ editor: TimelineEditor, _ s: Selected, _ pid: String, fallback: NativeParameterValue) -> InspectorRow.Keyframe {
        let animated = editor.isAnimated(clipId: s.id, pid)
        let on = editor.hasKeyframe(clipId: s.id, pid, time: time)
        let t = time
        return InspectorRow.Keyframe(
            state: on ? .onKey : (animated ? .animated : .none),
            toggle: { [weak self] in self?.edited(editor.toggleKeyframe(clipId: s.id, pid, time: t, fallback: fallback)) },
            stopwatch: { [weak self] in self?.edited(editor.setAnimated(clipId: s.id, [(pid, fallback)], !animated, time: t)) },
            // KeyframeNavigation: a stepper is live only when there is a keyframe that way.
            prev: (animated ? editor.adjacentKeyframeTime(clipId: s.id, pid, time: t, forward: false) : nil).map { v in { [weak self] in self?.onSeek?(v) } },
            next: (animated ? editor.adjacentKeyframeTime(clipId: s.id, pid, time: t, forward: true) : nil).map { v in { [weak self] in self?.onSeek?(v) } })
    }

    func tier(_ editor: TimelineEditor, _ s: Selected, _ pid: String, isDefault: Bool) -> PropertyValueTier {
        guard editor.isExplicit(clipId: s.id, pid) else { return .default }
        return isDefault ? .explicitDefault : .explicitCustom
    }

    func numberRow(key: String, label: String, value: Double, decimals: Int = 1, suffix: String = "", tier: PropertyValueTier,
                   step: Double, apply: @escaping (Double) -> Bool, reset: (() -> Bool)? = nil, keyframe: InspectorRow.Keyframe? = nil) -> InspectorRow.Number {
        let fmt: (Double) -> String = { PanelFormat.number($0, decimals: decimals) + suffix }
        return InspectorRow.Number(
            key: key, label: label, text: fmt(value), tier: tier,
            commit: { [weak self] text in if let v = PanelFormat.parse(text) { self?.edited(apply(v)) } },
            reset: reset.map { r in { [weak self] in self?.edited(r()) } },
            keyframe: keyframe,
            scrub: (value, step, { [weak self] v in self?.edited(apply(v)) }, fmt))
    }

    // MARK: Transform

    func transformGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup {
        let t = time
        let cw = editor.document.canvas.width, ch = editor.document.canvas.height
        let tr = editor.transform(clipId: s.id, time: t)
        let x = tr.x ?? 0, y = tr.y ?? 0, w = tr.width ?? cw, h = tr.height ?? ch, r = tr.rotation ?? 0
        // Media: the fit of its natural size is the default box; an untouched size reads as that default.
        let fit = editor.defaultLayout(clipId: s.id), natural = editor.naturalLayout(clipId: s.id) != nil
        func sizeTier(_ pid: String, _ isDefault: Bool) -> PropertyValueTier { natural ? .default : tier(editor, s, pid, isDefault: isDefault) }
        var scale = 1.0
        if case .vec2(let v)? = editor.parameterValue(clipId: s.id, parameterId: TimelineEditor.scaleId, time: t) { scale = v.x }
        else if case .number(let v)? = editor.parameterValue(clipId: s.id, parameterId: TimelineEditor.scaleId, time: t) { scale = v }
        let pos = TimelineEditor.positionId
        let posTier = tier(editor, s, pos, isDefault: x == 0 && y == 0)
        let posKf = keyframe(editor, s, pos, fallback: .vec2(Vec2Value(x: x, y: y)))
        let px = numberRow(key: "x", label: "X", value: x, decimals: 0, suffix: "px", tier: posTier, step: 1,
                           apply: { editor.applyTransform(clipId: s.id, time: t, ClipTransform(x: $0, y: y)) },
                           reset: { editor.clearStaticParameter(clipId: s.id, pos) }, keyframe: posKf)
        let py = numberRow(key: "y", label: "Y", value: y, decimals: 0, suffix: "px", tier: posTier, step: 1,
                           apply: { editor.applyTransform(clipId: s.id, time: t, ClipTransform(x: x, y: $0)) },
                           reset: { editor.clearStaticParameter(clipId: s.id, pos) })
        // GeometryGroupKeyframes: one navigation for W and H together.
        let wk = keyframe(editor, s, TimelineEditor.widthId, fallback: .number(w)), hk = keyframe(editor, s, TimelineEditor.heightId, fallback: .number(h))
        let sizeKf = InspectorRow.Keyframe(
            state: wk.state == .onKey || hk.state == .onKey ? .onKey : (wk.state == .animated || hk.state == .animated ? .animated : .none),
            toggle: { [weak self] in
                let on = wk.state == .onKey || hk.state == .onKey
                self?.edited({
                    var ok = false
                    for (pid, v) in [(TimelineEditor.widthId, w), (TimelineEditor.heightId, h)]
                    where editor.hasKeyframe(clipId: s.id, pid, time: t) == on {
                        ok = editor.toggleKeyframe(clipId: s.id, pid, time: t, fallback: .number(v)) || ok
                    }
                    return ok
                }(), label: "Edit transform")
            },
            stopwatch: { [weak self] in
                let on = wk.state == .none && hk.state == .none
                self?.edited(editor.setAnimated(clipId: s.id, [(TimelineEditor.widthId, .number(w)), (TimelineEditor.heightId, .number(h))],
                                                on, time: t), label: "Edit transform")
            },
            prev: wk.prev ?? hk.prev, next: wk.next ?? hk.next)
        let pw = numberRow(key: "w", label: "W", value: w, decimals: 0, suffix: "px", tier: sizeTier(TimelineEditor.widthId, w == fit.width), step: 1,
                           apply: { editor.applyTransform(clipId: s.id, time: t, ClipTransform(width: max(1, $0))) },
                           reset: { editor.resetSize(clipId: s.id) },
                           keyframe: sizeKf)
        let ph = numberRow(key: "h", label: "H", value: h, decimals: 0, suffix: "px", tier: sizeTier(TimelineEditor.heightId, h == fit.height), step: 1,
                           apply: { editor.applyTransform(clipId: s.id, time: t, ClipTransform(height: max(1, $0))) },
                           reset: { editor.resetSize(clipId: s.id) })
        let rot = numberRow(key: "rotation", label: "Rotation", value: r, decimals: 0, suffix: "°",
                            tier: tier(editor, s, TimelineEditor.rotationId, isDefault: r == 0), step: 0.5,
                            apply: { editor.applyTransform(clipId: s.id, time: t, ClipTransform(rotation: $0)) },
                            reset: { editor.clearStaticParameter(clipId: s.id, TimelineEditor.rotationId) },
                            keyframe: keyframe(editor, s, TimelineEditor.rotationId, fallback: .number(r)))
        let sc = numberRow(key: "scale", label: "Scale", value: scale * 100, decimals: 0, suffix: "%",
                           tier: tier(editor, s, TimelineEditor.scaleId, isDefault: scale == 1), step: 1,
                           apply: { editor.setParameter(clipId: s.id, TimelineEditor.scaleId, .vec2(Vec2Value(x: max(0.01, $0 / 100), y: max(0.01, $0 / 100))), time: t) },
                           reset: { editor.clearStaticParameter(clipId: s.id, TimelineEditor.scaleId) },
                           keyframe: keyframe(editor, s, TimelineEditor.scaleId, fallback: .vec2(Vec2Value(x: scale, y: scale))))
        var rows: [InspectorRow] = [
            .init(.pair(label: "Position", px, py)), .init(.pair(label: "Size", pw, ph), padY: 4),
            .init(.number(rot)), .init(.number(sc)), layerOrderRow(editor, s),
        ]
        rows += transform3DRows(editor, s)
        // Keyframe easing (NativeInterpolationEditor) for the eased channels: the selected keys, else the playhead's.
        let channels = Self.transformEasedChannels.filter { editor.isAnimated(clipId: s.id, $0) }
        if !channels.isEmpty { rows += easingRows(editor, s, channels: channels) }
        rows += arcMotionRows(editor, s)
        return InspectorGroup(id: "layout", title: "Transform",
                              summary: "\(PanelFormat.number(x, decimals: 0))px,\(PanelFormat.number(y, decimals: 0))px · \(Int(w.rounded()))×\(Int(h.rounded()))",
                              rows: rows, spacing: 6)
    }

    // MARK: Style

    func styleGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup {
        let t = time
        let op = editor.numberValue(clipId: s.id, TimelineEditor.opacityId, time: t) ?? 1
        let pct = Int((op * 100).rounded())
        let slider = InspectorRow.Slider(
            key: "opacity", label: "Opacity", position: op * 100, min: 0, max: 100, display: "\(pct)%",
            format: { "\(Int($0.rounded()))%" }, tier: tier(editor, s, TimelineEditor.opacityId, isDefault: op == 1),
            commit: { [weak self] v in self?.edited(editor.setParameter(clipId: s.id, TimelineEditor.opacityId, .number(max(0, min(1, v / 100))), time: t)) },
            reset: { [weak self] in self?.edited(editor.clearStaticParameter(clipId: s.id, TimelineEditor.opacityId)) },
            keyframe: keyframe(editor, s, TimelineEditor.opacityId, fallback: .number(op)))
        return InspectorGroup(id: "style", title: "Style", summary: Self.styleSummary(s.clip.style, opacityPercent: pct),
                              rows: styleRows(editor, s) + [.init(.slider(slider))])
    }

    // MARK: Effects

    func effectsGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup {
        let active = s.clip.effects.filter { $0.enabled && $0.effectId != ColorGrading.effectId }.count
        var rows: [InspectorRow] = s.clip.effects.filter { $0.effectId != ColorGrading.effectId }.map { e in
            .init(.fxNode(.init(key: "effect:\(e.id)", label: Self.titleCase(e.effectId), detail: e.effectId, enabled: e.enabled,
                                toggle: { [weak self] in self?.edited(editor.setEffectEnabled(clipId: s.id, effectId: e.id, !e.enabled)) },
                                remove: { [weak self] in self?.edited(editor.removeEffect(clipId: s.id, effectId: e.id)) })))
        }
        // The grade and its stylize effects render in preview and export; other effect nodes are only kept (export refuses them).
        if !rows.isEmpty { rows.append(.init(.note("These effects are kept in the project; only the grade and its stylize effects render, and export refuses the rest."))) }
        return InspectorGroup(id: "clip-effects", title: "Clip effects", summary: active > 0 ? "\(active) active" : "none", rows: rows)
    }

    static func titleCase(_ v: String) -> String {
        v.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Audio FX

    func audioFxGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup {
        let chain = (try? s.clip.audioFxChain.map(AudioFx.parseChain)) ?? nil ?? FxChain()
        var rows = audioFxRackRows(chain, owner: "clip:\(s.id)", subject: "track") { next in
            editor.setClipFxChain(clipId: s.id, next.nodes.isEmpty ? nil : AudioFx.serializeChain(next))
        }
        // Group volume when the clip belongs to an audio group.
        if let gid = s.clip.audioGroupId, let g = editor.document.sequence.audioGroups?.first(where: { $0.id == gid }) {
            rows.append(contentsOf: groupVolumeRows(editor, g))
        }
        return InspectorGroup(id: "audio-fx", title: "Audio FX", summary: Self.audioFxSummary(chain), rows: rows, spacing: 0)
    }

    /// The audio-group bus rack (TimelineGroupRow openGroupFxRack: the bus selected in the inspector): its FX chain and volume.
    func busFxGroup(_ editor: TimelineEditor, _ g: NativeAudioGroup) -> InspectorGroup {
        let chain = (try? g.fxChain.map(AudioFx.parseChain)) ?? nil ?? FxChain()
        var rows = audioFxRackRows(chain, owner: "bus:\(g.id)", subject: "group") { next in
            editor.setAudioGroupFxChain(g.id, next.nodes.isEmpty ? nil : AudioFx.serializeChain(next))
        }
        rows.append(contentsOf: groupVolumeRows(editor, g))
        return InspectorGroup(id: "audio-fx", title: "Audio FX", summary: Self.audioFxSummary(chain), rows: rows, spacing: 0)
    }

    func groupVolumeRows(_ editor: TimelineEditor, _ g: NativeAudioGroup) -> [InspectorRow] {
        let gid = g.id, gv = g.volume ?? 1
        return [.init(.spacer(8)), .init(.slider(.init(
            key: "groupVolume", label: "Group volume", position: AudioGainFader.position(gain: gv), min: AudioGainFader.min, max: AudioGainFader.max,
            display: AudioGainFader.text(gv), format: { AudioGainFader.text(AudioGainFader.gain(position: $0)) },
            tier: gv == 1 ? .default : .explicitCustom, centerTick: true,
            commit: { [weak self] p in self?.edited(editor.setAudioGroupVolume(gid, AudioGainFader.gain(position: p))) },
            reset: { [weak self] in self?.edited(editor.setAudioGroupVolume(gid, 1)) })))]
    }

    static func audioFxSummary(_ chain: FxChain) -> String {
        let names = chain.enabledNodes.compactMap { $0.fromPreset.flatMap(AudioFxPresets.preset)?.label }
        return chain.nodes.isEmpty ? "none" : (Array(Set(names)).sorted().first.map { "\($0) · \(chain.enabledNodes.count) on" } ?? "\(chain.enabledNodes.count) on")
    }

    // MARK: Media

    func mediaGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup {
        var rows: [InspectorRow] = []
        let t = time
        if s.kind == .video || s.kind == .image {
            rows.append(contentsOf: cropRows(editor, s))
        }
        if s.hasAudio {
            let vol = AudioGainFader.clamp(editor.numberValue(clipId: s.id, TimelineEditor.volumeId, time: t) ?? 1)
            rows.append(.init(.slider(.init(
                key: "volume", label: "Volume", position: AudioGainFader.position(gain: vol), min: AudioGainFader.min, max: AudioGainFader.max,
                display: AudioGainFader.text(vol), format: { AudioGainFader.text(AudioGainFader.gain(position: $0)) },
                tier: vol == 1 ? .default : .explicitCustom, centerTick: true,
                commit: { [weak self] p in
                    let g = AudioGainFader.gain(position: p)
                    self?.edited(editor.isAnimated(clipId: s.id, TimelineEditor.volumeId)
                                 ? editor.setParameter(clipId: s.id, TimelineEditor.volumeId, .number(g), time: t)
                                 : editor.setClipVolume(clipId: s.id, (g * 1_000_000).rounded() / 1_000_000), label: "Set volume")
                },
                reset: { [weak self] in self?.edited(editor.clearStaticParameter(clipId: s.id, TimelineEditor.volumeId)) },
                keyframe: keyframe(editor, s, TimelineEditor.volumeId, fallback: .number(vol))))))
            if editor.isAnimated(clipId: s.id, TimelineEditor.volumeId) { rows += easingRows(editor, s, channels: [TimelineEditor.volumeId]) }
        }
        if s.kind == .video || s.kind == .audio {
            let rate = editor.playbackRate(clipId: s.id)
            rows.append(.init(.slider(.init(
                key: "rate", label: "Rate", position: rate * 100, min: 25, max: 300, display: "\(PanelFormat.number(rate))x",
                format: { "\(PanelFormat.number($0 / 100))x" }, tier: rate == 1 ? .default : .explicitCustom,
                commit: { [weak self] p in self?.edited(editor.setPlaybackRate(clipId: s.id, (p).rounded() / 100)) },
                reset: { [weak self] in self?.edited(editor.setPlaybackRate(clipId: s.id, 1)) }))))
            let fps = editor.fps
            rows.append(.init(.number(.init(key: "mediaStart", label: "Media start", text: String(format: "%.2fs", s.clip.sourceInFrame / fps),
                                            tier: s.clip.sourceInFrame == 0 ? .default : .explicitCustom, commit: { _ in }, disabled: true))))
            let label = s.kind == .video ? "Play video sound" : "Muted"
            let on = s.kind == .video ? !s.clip.muted : s.clip.muted
            rows.append(.init(.toggle(.init(key: "muted", label: label, on: on, tier: s.clip.muted ? .explicitCustom : .default, set: { [weak self] v in
                self?.edited(editor.setMuted(clipId: s.id, s.kind == .video ? !v : v))
            }))))
        }
        return InspectorGroup(id: "media", title: "Media", summary: s.kind.rawValue, rows: rows)
    }

    func cropRows(_ editor: TimelineEditor, _ s: Selected) -> [InspectorRow] {
        let crop = editor.crop(clipId: s.id) ?? NativeClipCrop()
        guard cropActive == s.id else {
            return [.init(.subheader("Crop", buttons: [.init(key: "crop:start", label: "Crop", style: .accent) { [weak self] in
                self?.cropActive = s.id; self?.cropLinkAll = false; self?.onEdited?()
            }]))]
        }
        var rows: [InspectorRow] = [.init(.subheader("Crop", buttons: [
            .init(key: "crop:reset", label: "↺", style: .muted) { [weak self] in self?.edited(editor.setCrop(clipId: s.id, nil)) },
            .init(key: "crop:cancel", label: "Cancel", style: .muted) { [weak self] in
                if let before = self?.cropBefore { _ = editor.setCrop(clipId: s.id, before) }
                self?.cropActive = nil; self?.onEdited?()
            },
            .init(key: "crop:apply", label: "Apply", style: .accent) { [weak self] in self?.cropActive = nil; self?.cropBefore = nil; self?.onEdited?() },
        ]))]
        rows.append(.init(.segmented(.init(key: "crop:links", label: "Link edges",
                                           options: [(key: "all", label: "All", active: cropLinkAll), (key: "sides", label: "Sides", active: !cropLinkAll)],
                                           select: { [weak self] k in self?.cropLinkAll = k == "all"; self?.onEdited?() }))))
        func set(_ edge: String, _ v: Double) -> Bool {
            var c = editor.crop(clipId: s.id) ?? NativeClipCrop()
            let px = max(0, v)
            if cropLinkAll { c = NativeClipCrop(top: px, right: px, bottom: px, left: px) }
            else { switch edge { case "top": c.top = px; case "right": c.right = px; case "bottom": c.bottom = px; default: c.left = px } }
            return editor.setCrop(clipId: s.id, c)
        }
        if cropLinkAll {
            rows.append(.init(.quad([numberRow(key: "crop:all", label: "All", value: crop.top, decimals: 0, suffix: "px",
                                               tier: crop.isZero ? .default : .explicitCustom, step: 1, apply: { set("top", $0) })])))
        } else {
            rows.append(.init(.quad([("top", "T", crop.top), ("right", "R", crop.right), ("bottom", "B", crop.bottom), ("left", "L", crop.left)].map { e in
                numberRow(key: "crop:\(e.0)", label: e.1, value: e.2, decimals: 0, suffix: "", tier: e.2 == 0 ? .default : .explicitCustom,
                          step: 1, apply: { set(e.0, $0) })
            })))
        }
        return rows
    }
}

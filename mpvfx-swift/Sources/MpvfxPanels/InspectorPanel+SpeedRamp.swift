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
// The Media group's speed ramp rows: a Constant | Ramp switch, the speed graph with the starting shapes under it, a Keep
// length switch, and typed fields for the focused point. Every pointer action on the graph has a key (see
// `SpeedGraph.keyDown`); each edit is one undo step.
import Foundation
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline

extension InspectorPanel {
    /// The ramp rows for the selected video clip; none for other clips.
    func speedRampRows(_ editor: TimelineEditor, _ s: Selected) -> [InspectorRow] {
        guard s.kind == .video else { return [] }
        if s.clip.speedRamp != nil, !editor.isRamped(s.id) {
            return [.init(.note("This clip's speed ramp is from a newer version of the editor and is kept as it is."))]
        }
        let ramp = editor.speedRamp(of: s.id)
        var rows: [InspectorRow] = [.init(.segmented(.init(key: "speedMode", label: "Speed",
            options: [("constant", "Constant", ramp == nil), ("ramp", "Ramp", ramp != nil)],
            select: { [weak self] value in
                guard let self else { return }
                self.edited(editor.applySpeedRamp(clipId: s.id, value == "ramp" ? .setShape(.slowMiddle) : .clear, keepLength: self.speedKeepLength),
                            label: value == "ramp" ? "Set speed shape" : "Remove speed ramp")
            })))]
        guard let ramp else { return rows }
        rows.append(.init(.custom(speedGraphRow(editor, s))))
        for pair in stride(from: 0, to: NativeSpeedRampShape.allCases.count, by: 3) {
            let shapes = NativeSpeedRampShape.allCases[pair..<min(pair + 3, NativeSpeedRampShape.allCases.count)]
            rows.append(.init(.buttons(shapes.map { shape in
                .init(key: "speedShape:\(shape.rawValue)", label: shape.title, style: .chip, action: { [weak self] in
                    guard let self else { return }
                    self.edited(editor.applySpeedRamp(clipId: s.id, .setShape(shape), keepLength: self.speedKeepLength), label: "Set speed shape")
                })
            })))
        }
        rows.append(.init(.toggle(.init(key: "speedKeepLength", label: "Keep length", on: speedKeepLength, tier: speedKeepLength ? .default : .explicitCustom,
                                        set: { [weak self] on in self?.speedKeepLength = on; self?.onEdited?() }))))
        rows.append(contentsOf: speedPointRows(editor, s, ramp))
        return rows
    }

    /// The graph: 120 pt, drawn and driven by `SpeedGraph`; its actions become editor commands.
    private func speedGraphRow(_ editor: TimelineEditor, _ s: Selected) -> InspectorCustomRow {
        InspectorCustomRow(id: "speedGraph", height: SpeedGraph.height, draw: { [weak self] c, r, _ in
            guard let self else { return }
            self.syncSpeedGraph(editor, s)
            self.speedGraph.draw(c, in: r)
        }, pointer: { [weak self] _, p, phase in
            guard let self else { return }
            self.syncSpeedGraph(editor, s)
            let actions = phase == 0 ? self.speedGraph.pointerDown(p) : phase == 1 ? self.speedGraph.pointerMove(p) : self.speedGraph.pointerUp(p)
            self.applySpeedGraph(actions, editor, s)
        }, key: { [weak self] _, k in
            guard let self else { return false }
            self.syncSpeedGraph(editor, s)
            let actions = self.speedGraph.keyDown(k)
            self.applySpeedGraph(actions, editor, s)
            return !actions.isEmpty
        })
    }

    /// Reads the clip's ramp, length and the playhead into the graph (not while a point is being dragged).
    private func syncSpeedGraph(_ editor: TimelineEditor, _ s: Selected) {
        guard speedGraph.draggingIndex == nil, let ramp = editor.speedRamp(of: s.id), let clip = editor.clip(s.id)?.clip else { return }
        let focus = speedGraph.focused
        speedGraph.points = ramp.points
        speedGraph.durationFrames = clip.durationFrames
        speedGraph.fps = editor.fps
        speedGraph.playheadFrame = max(0, min(clip.durationFrames, (time * editor.fps).rounded() - clip.startFrame))
        speedGraph.focused = focus.flatMap { ramp.points.indices.contains($0) ? $0 : nil }
    }

    /// Turns the graph's actions into ramp commands, each one undo step; a focus change edits nothing.
    private func applySpeedGraph(_ actions: [SpeedGraphAction], _ editor: TimelineEditor, _ s: Selected) {
        for action in actions {
            let command: NativeSpeedRampCommand
            switch action {
            case .focusPoint(let i): speedGraph.focused = i; onEdited?(); continue
            case .addPoint(let t, let speed): command = .addPoint(t: t, speed: speed)
            case .movePoint(let i, let t, let speed): command = .movePoint(index: i, t: t, speed: speed)
            case .removePoint(let i): command = .removePoint(index: i)
            case .setShape(let shape): command = .setShape(shape)
            case .setEase(let i, let ease): command = .setEase(index: i, ease: ease)
            }
            edited(editor.applySpeedRamp(clipId: s.id, command, keepLength: speedKeepLength), label: Self.speedEditLabel(command))
            if let ramp = editor.speedRamp(of: s.id) {
                speedGraph.points = ramp.points
                if case .addPoint(let t, _) = command { speedGraph.focused = ramp.points.firstIndex { $0.t == t } }
                if case .removePoint = command { speedGraph.focused = nil }
            }
        }
    }

    private static func speedEditLabel(_ command: NativeSpeedRampCommand) -> String { TimelineEditor.speedRampLabel(command) }

    /// Typed time and speed for the focused point, and the ease of the segment after it.
    private func speedPointRows(_ editor: TimelineEditor, _ s: Selected, _ ramp: NativeSpeedRamp) -> [InspectorRow] {
        guard let i = speedGraph.focused, ramp.points.indices.contains(i) else {
            return [.init(.note("Click the graph or press Enter to add a point at the playhead. Tab picks a point; arrows move it."))]
        }
        let point = ramp.points[i], fps = editor.fps
        func move(t: Double, speed: Double) {
            edited(editor.applySpeedRamp(clipId: s.id, .movePoint(index: i, t: t, speed: speed), keepLength: speedKeepLength), label: "Move speed point")
        }
        var rows: [InspectorRow] = []
        rows.append(.init(.number(.init(key: "speedPointTime", label: "Point time", text: SpeedGraph.formatTime(frame: point.t, fps: fps),
                                        tier: .default, commit: { text in
            if let frame = Self.parseSpeedTime(text, fps: fps) { move(t: frame, speed: point.speed) }
        }))))
        rows.append(.init(.number(.init(key: "speedPointSpeed", label: "Point speed", text: SpeedGraph.formatSpeed(point.speed),
                                        tier: .default, commit: { text in
            if let speed = Self.parseSpeedValue(text) { move(t: point.t, speed: speed) }
        }))))
        if i + 1 < ramp.points.count {
            let isHold = point.ease == .hold, isLinear = point.ease == .linear
            rows.append(.init(.segmented(.init(key: "speedPointEase", label: "Ease after",
                options: [("linear", "Linear", isLinear), ("hold", "Hold", isHold)],
                select: { [weak self] value in
                    self?.edited(editor.applySpeedRamp(clipId: s.id, .setEase(index: i, ease: value == "hold" ? .hold : .linear), keepLength: self?.speedKeepLength ?? true),
                                 label: "Change speed ease")
                }))))
        }
        return rows
    }

    /// "2", "2×", "0.5x": a speed.
    static func parseSpeedValue(_ text: String) -> Double? {
        PanelFormat.parse(text.replacingOccurrences(of: "×", with: "").replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// "MM:SS:FF" or a plain frame count: a clip frame.
    static func parseSpeedTime(_ text: String, fps: Double) -> Double? {
        let parts = text.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        let nums = parts.compactMap { $0 }
        let base = max(1, fps.rounded())
        switch nums.count {
        case 1: return nums[0]
        case 2: return nums[0] * base + nums[1]
        case 3: return (nums[0] * 60 + nums[1]) * base + nums[2]
        default: return nil
        }
    }
}

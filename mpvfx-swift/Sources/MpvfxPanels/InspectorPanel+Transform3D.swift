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
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import MpvfxTheme

/// The Transform group's collapsible 3D transform (compact, as the flat panel shows it):
/// the orientation cube (Transform3DCube: drag to tilt, reset to flat), then Depth, Tilt X, Tilt Y, Roll and
/// Perspective, each keyframeable with its own reset. Roll is `transform.rotation` (rotation about Z is the same value).
/// Every row draws through NativeTransform3D, the projection preview and export share.
extension InspectorPanel {
    /// The cube's drag sensitivity: degrees per pixel.
    static let cubeSensitivity = 0.6

    static func wrapDegrees(_ d: Double) -> Double {
        var v = d.truncatingRemainder(dividingBy: 360)
        if v > 180 { v -= 360 } else if v <= -180 { v += 360 }
        return v
    }

    /// Several document commands as one undo step (a fresh coalesce key folds them into the first entry).
    static func oneStep(_ editor: TimelineEditor, _ label: String, _ body: () -> Bool) -> Bool {
        editor.withHistory(label, coalesceKey: "3d-\(UUID().uuidString)", body)
    }

    func transform3DRows(_ editor: TimelineEditor, _ s: Selected) -> [InspectorRow] {
        let t = time
        func value(_ pid: String) -> Double { editor.numberValue(clipId: s.id, pid, time: t) ?? 0 }
        let rx = value(NativeTransform3D.rotationXId), ry = value(NativeTransform3D.rotationYId)
        let z = value(NativeTransform3D.zId), lens = value(NativeTransform3D.perspectiveId)
        let roll = value(TimelineEditor.rotationId)
        var rows: [InspectorRow] = [.init(.spacer(6)), .init(.custom(transform3DHeader()))]
        guard transform3DOpen else { return rows }
        rows.append(.init(.custom(cubeRow(editor, s, pose: (rx, ry, roll), z: z, lens: lens))))
        rows.append(.init(.note("Drag to tilt · the ↺ under the cube resets to flat")))
        // Comp-derived lens (naturalDepthPerspective): the composition height, one comp-height back.
        let naturalLens = editor.document.canvas.height.rounded()
        func row(_ key: String, _ label: String, _ pid: String, _ v: Double, suffix: String, step: Double,
                 apply: @escaping (Double) -> Bool) -> InspectorRow {
            .init(.number(numberRow(key: key, label: label, value: v, decimals: 0, suffix: suffix,
                                    tier: tier(editor, s, pid, isDefault: v == 0), step: step, apply: apply,
                                    reset: { editor.clearStaticParameter(clipId: s.id, pid) },
                                    keyframe: keyframe(editor, s, pid, fallback: .number(v)))))
        }
        rows.append(row("depth", "Depth", NativeTransform3D.zId, z, suffix: "px", step: 1) { nz in
            // Depth only foreshortens under a lens: the first time depth is set, the comp-derived lens comes with it
            // (onDepthCommit), and depth stays in front of the lens.
            let l = lens > 0 ? lens : naturalLens
            return Self.oneStep(editor, "Edit transform") {
                var ok = editor.setParameter(clipId: s.id, NativeTransform3D.zId, .number(min(nz, NativeTransform3D.maxDepth(perspective: l))), time: t)
                if lens <= 0, nz != 0 { ok = editor.setParameter(clipId: s.id, NativeTransform3D.perspectiveId, .number(l), time: t) || ok }
                return ok
            }
        })
        rows.append(row("tiltX", "Tilt X", NativeTransform3D.rotationXId, rx, suffix: "°", step: 0.5) {
            editor.setParameter(clipId: s.id, NativeTransform3D.rotationXId, .number($0), time: t)
        })
        rows.append(row("tiltY", "Tilt Y", NativeTransform3D.rotationYId, ry, suffix: "°", step: 0.5) {
            editor.setParameter(clipId: s.id, NativeTransform3D.rotationYId, .number($0), time: t)
        })
        rows.append(row("roll", "Roll", TimelineEditor.rotationId, roll, suffix: "°", step: 0.5) {
            editor.applyTransform(clipId: s.id, time: t, ClipTransform(rotation: $0))
        })
        rows.append(row("perspective", "Perspective", NativeTransform3D.perspectiveId, lens, suffix: "px", step: 1) {
            editor.setParameter(clipId: s.id, NativeTransform3D.perspectiveId, .number(max(0, $0)), time: t)   // parsePxNonNeg
        })
        return rows
    }

    /// `text-[10px] font-medium uppercase tracking-wider` toggle with its caret (collapsed by default).
    func transform3DHeader() -> InspectorCustomRow {
        InspectorCustomRow(id: "3d:toggle", height: 24, draw: { [weak self] c, r, panel in
            guard let self else { return }
            let hot = panel.hovered == .custom("3d:toggle", 0)
            PanelDraw.text(c, "3D TRANSFORM", in: CanvasRect(x: r.x, y: r.y, width: r.width - 16, height: r.height),
                           font: PanelTheme.font(10, .medium), color: hot ? PanelTheme.text2 : PanelTheme.text4)
            let caret = CanvasRect(x: r.maxX - 9, y: r.y + (r.height - 9) / 2, width: 9, height: 9)
            (self.transform3DOpen ? PanelIcon.groupCaretDown : PanelIcon.groupCaretRight).draw(c, in: caret, color: hot ? PanelTheme.text2 : PanelTheme.text4)
            panel.addHit(r, .custom("3d:toggle", 0))
        }, pointer: { [weak self] _, _, phase in
            guard let self, phase == 0 else { return }
            self.transform3DOpen.toggle()
        })
    }

    /// The orientation cube (Transform3DCube): a unit cube turned by the pose, faces shaded by how much they face
    /// the viewer, scaled by depth under the lens. Drag tilts X/Y (committed on release as one step); part 1 is the
    /// ↺ reset under it (recenter: tilt, depth and lens back to flat).
    func cubeRow(_ editor: TimelineEditor, _ s: Selected, pose: (x: Double, y: Double, roll: Double), z: Double, lens: Double) -> InspectorCustomRow {
        let id = "3d:cube", t = time
        return InspectorCustomRow(id: id, height: 128, draw: { [weak self] c, r, panel in
            guard let self else { return }
            let shown = self.cubeDrag.map { ($0.x, $0.y, pose.roll) } ?? pose
            let w = min(r.width, 184.0), h = 112.0 * w / 132
            let frame = CanvasRect(x: r.x + (r.width - w) / 2, y: r.y, width: w, height: min(h, r.height - 16))
            self.cubeBox = frame
            c.fillRoundedRect(frame, radius: 8, PanelTheme.panelBg)
            c.strokeRoundedRect(frame.insetBy(0.5), radius: 7.5, PanelTheme.panelBorderInput, width: 1)
            let depthScale = lens > 0 ? max(0.4, min(2.2, lens / (lens - z))) : 1
            let radius = frame.height * 0.24 * depthScale
            let t3 = NativeTransform3D(rotationX: shown.0, rotationY: shown.1)
            func corner(_ x: Double, _ y: Double, _ zz: Double) -> (p: CanvasPoint, depth: Double) {
                // Rotate (x, y, zz) like NativeTransform3D (tilt X, tilt Y, roll), weak perspective for the cube itself.
                var hx = x, hy = y, hz = zz
                let ax = t3.rotationX * .pi / 180, ay = t3.rotationY * .pi / 180, az = shown.2 * .pi / 180
                (hy, hz) = (hy * cos(ax) - hz * sin(ax), hy * sin(ax) + hz * cos(ax))
                (hx, hz) = (hx * cos(ay) + hz * sin(ay), -hx * sin(ay) + hz * cos(ay))
                (hx, hy) = (hx * cos(az) - hy * sin(az), hx * sin(az) + hy * cos(az))
                let k = 6 / (6 - hz)
                return (CanvasPoint(frame.x + frame.width / 2 + hx * radius * k, frame.y + frame.height / 2 + hy * radius * k), hz)
            }
            let faces: [[(Double, Double, Double)]] = [
                [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)], [(-1, -1, -1), (-1, 1, -1), (1, 1, -1), (1, -1, -1)],
                [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)], [(-1, 1, -1), (-1, 1, 1), (1, 1, 1), (1, 1, -1)],
                [(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, 1, -1)], [(1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1)],
            ]
            let projected = faces.map { f in f.map { corner($0.0, $0.1, $0.2) } }
                .sorted { $0.reduce(0) { $0 + $1.depth } < $1.reduce(0) { $0 + $1.depth } }
            c.withState {
                c.clip(frame)
                for f in projected {
                    let facing = max(0, min(1, (f.reduce(0) { $0 + $1.depth } / 4 + 1) / 2))   // 0 away … 1 toward
                    var path = CanvasPath()
                    for (k, q) in f.enumerated() { if k == 0 { path.move(to: q.p) } else { path.line(to: q.p) } }
                    path.close()
                    c.fill(path, PanelTheme.mint.withAlpha(0.15 + 0.45 * facing))
                    c.stroke(path, PanelTheme.mint.withAlpha(0.5 + 0.4 * facing), StrokeStyle(width: 1.1))
                }
            }
            panel.addHit(frame, .custom(id, 0))
            let reset = CanvasRect(x: frame.x + frame.width / 2 - 6, y: frame.maxY + 3, width: 12, height: 12)
            PanelIcon.reset.draw(c, in: reset, color: panel.hovered == .custom(id, 1) ? PanelTheme.text1 : PanelTheme.text4)
            panel.addHit(reset.insetBy(-3), .custom(id, 1))
        }, pointer: { [weak self] part, p, phase in
            guard let self else { return }
            if part == 1 {
                guard phase == 0 else { return }
                self.edited(Self.oneStep(editor, "Reset 3D transform") {
                    var ok = false
                    for pid in NativeTransform3D.parameterIds where editor.isExplicit(clipId: s.id, pid) {
                        ok = (editor.isAnimated(clipId: s.id, pid)
                              ? editor.setParameter(clipId: s.id, pid, .number(0), time: t)
                              : editor.clearStaticParameter(clipId: s.id, pid)) || ok
                    }
                    return ok
                }, label: "Reset 3D transform")
                return
            }
            switch phase {
            case 0: self.cubeDrag = CubeDrag(startX: p.x, startY: p.y, x: pose.x, y: pose.y, moved: false)
            default:
                guard var d = self.cubeDrag else { return }
                let dx = p.x - d.startX, dy = p.y - d.startY
                if dx != 0 || dy != 0 { d.moved = true }
                d.x = Self.wrapDegrees(pose.x + dy * Self.cubeSensitivity)
                d.y = Self.wrapDegrees(pose.y + dx * Self.cubeSensitivity)
                self.cubeDrag = phase == 2 ? nil : d
                guard phase == 2, d.moved else { return }
                // Commit only the axes that changed (whole degrees), one step for the whole pose.
                let nx = d.x.rounded(), ny = d.y.rounded()
                self.edited(Self.oneStep(editor, "3D rotation pose") {
                    var ok = false
                    if nx != pose.x.rounded() { ok = editor.setParameter(clipId: s.id, NativeTransform3D.rotationXId, .number(nx), time: t) || ok }
                    if ny != pose.y.rounded() { ok = editor.setParameter(clipId: s.id, NativeTransform3D.rotationYId, .number(ny), time: t) || ok }
                    return ok
                }, label: "3D rotation pose")
            }
        })
    }
}

/// A cube drag in flight: where it started and the live tilt it shows.
public struct CubeDrag: Equatable {
    public var startX: Double, startY: Double
    public var x: Double, y: Double
    public var moved: Bool
}

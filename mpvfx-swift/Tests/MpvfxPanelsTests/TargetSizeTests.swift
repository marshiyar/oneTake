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
import XCTest
#if os(macOS)
import CoreGraphics
import ImageIO
#endif
import MpvfxCanvas
import MpvfxTheme
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// WCAG 2.2 SC 2.5.8 Target Size (Minimum), Level AA: a pointer target is at least 24 by 24 CSS pixels (points here),
/// except when it is spaced so that a 24 px circle centred on its bounding box intersects no other target and no
/// other undersized target's circle, or another listed exception holds (Equivalent, Inline, User Agent Control,
/// Essential) (https://www.w3.org/TR/WCAG22/#target-size-minimum; docs/DESIGN.md "Accessibility floors"). A slider is one target (Note 1).
///
/// The audit reads the hit regions every panel records on draw (`HitMap`), the same rects pointer events resolve
/// against. Panels are drawn on the deterministic `PanelMeasureCanvas` (text widths from the font size alone), so
/// the geometry is the same on every OS and in both appearances. Widths are the 1440 × 900 window's defaults
/// (`PanelFit.defaults(1440)`: left 370, right 409); the height is tall enough that the open inspector group is laid
/// out whole, so the controls a user reaches by scrolling are measured too.
///
/// A region that fails both the size and the spacing rule fails the test unless it is in `exceptions` (a WCAG
/// exception, with its reason) or `knownUndersized` (today's findings, a ratchet: an entry that no longer fails must
/// be removed, so the list only shrinks; never add one to make a change pass).
final class TargetSizeTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    static let minimum = 24.0

    /// Targets below 24 × 24 that a WCAG 2.5.8 exception covers, by "<state> <action>" (any size), with the reason.
    static let exceptions: [String: String] = [:]

    /// Undersized, unspaced targets at this revision ("<state> <action> <w>x<h>"). Remove an entry when its target
    /// is fixed; the test fails while a listed entry passes.
    static let knownUndersized: Set<String> = []

    /// One audited region: where it was drawn and what it does.
    struct Region { let state: String, action: String, rect: CanvasRect, container: Bool }

    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String((v * 10).rounded() / 10) }

    /// Regions of one hit map drawn in `bounds`; zero-sized and fully off-panel ones are not reachable and skipped.
    static func regions<H>(_ state: String, _ hits: HitMap<H>, in bounds: CanvasRect, container: (H) -> Bool) -> [Region] {
        hits.regions.compactMap { r in
            let x = r.rect
            guard x.width > 0, x.height > 0, x.maxX > bounds.x, x.x < bounds.maxX, x.maxY > bounds.y, x.y < bounds.maxY else { return nil }
            return Region(state: state, action: String(describing: r.action), rect: x, container: container(r.action))
        }
    }

    /// Distance from `p` to the nearest point of `r` (0 inside).
    static func distance(_ px: Double, _ py: Double, _ r: CanvasRect) -> Double {
        let dx = max(r.x - px, 0, px - r.maxX), dy = max(r.y - py, 0, py - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The regions of one map (one panel state) that fail 2.5.8: under 24 in either dimension and not spaced.
    /// Containers (a panel body that catches the presses between controls) are not targets for the spacing rule.
    static func failing(_ map: [Region]) -> [Region] {
        let targets = map.filter { !$0.container }
        let small = targets.filter { $0.rect.width < minimum || $0.rect.height < minimum }
        func centre(_ r: CanvasRect) -> (Double, Double) { (r.x + r.width / 2, r.y + r.height / 2) }
        return small.filter { s in
            let (cx, cy) = centre(s.rect), radius = minimum / 2
            let hitsTarget = targets.contains { $0.action != s.action && distance(cx, cy, $0.rect) < radius }
            let hitsCircle = small.contains { o in
                guard o.action != s.action else { return false }
                let (ox, oy) = centre(o.rect)
                return ((cx - ox) * (cx - ox) + (cy - oy) * (cy - oy)).squareRoot() < minimum
            }
            return hitsTarget || hitsCircle
        }
    }

    // MARK: Fixtures (the states PanelSnapshotTests draws, on the measuring canvas)

    static func frame() -> CanvasImage { CanvasImage(width: 32, height: 18, rgba: [UInt8](repeating: 200, count: 32 * 18 * 4)) }

    static func sidebar() -> LeftSidebarPanel {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        s.items = [
            .init(id: "v1", name: "interview-take-1.mp4", path: "media/interview-take-1.mp4", category: .video, duration: 336, used: true),
            .init(id: "v2", name: "b-roll.mp4", path: "media/b-roll.mp4", category: .video, duration: 92, used: false),
        ]
        s.library.available = true
        s.library.libraries = [.init(id: "L", name: "test", events: [.init(id: "E", name: "Media")], projects: [.init(id: "P", name: "jk", eventId: "E")],
                                     assets: (0..<3).map { .init(id: "A\($0)", name: "clip-\($0).mp4", kind: "video", eventId: "E") },
                                     exports: (0..<3).map { .init(id: "J\($0)", label: "jk", status: "complete") })]
        s.library.currentProjectId = "P"
        s.onLibrary = { _ in }
        let f = frame()
        s.thumbnail = { _ in f }
        return s
    }

    /// The keyframe-capable properties the keyed fixture animates, with the value each key holds.
    static let keyedParameters: [(id: String, value: NativeParameterValue)] = [
        (TimelineEditor.positionId, .vec2(Vec2Value(x: 0, y: 0))), (TimelineEditor.widthId, .number(1280)),
        (TimelineEditor.heightId, .number(720)), (TimelineEditor.rotationId, .number(15)),
        (TimelineEditor.scaleId, .vec2(Vec2Value(x: 1.2, y: 1.2))), (TimelineEditor.opacityId, .number(0.8)),
        (TimelineEditor.volumeId, .number(0.7)),
    ]

    /// `keyed`: every keyframe-capable property has keys at 0.5 s and 2.5 s and the playhead is at 1.5 s, so each
    /// row shows its stopwatch, ‹ › (both live) and the diamond; rotation also has a key at 1.5 s (diamond on a key).
    static func design(open group: String, keyed: Bool = false) throws -> RightPanel {
        let r = RightPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        if keyed {
            for p in keyedParameters {
                for t in [0.5, 2.5] { XCTAssertTrue(editor.toggleKeyframe(clipId: "clip:a", p.id, time: t, fallback: p.value), "key \(p.id) at \(t)") }
            }
            XCTAssertTrue(editor.toggleKeyframe(clipId: "clip:a", TimelineEditor.rotationId, time: 1.5, fallback: .number(15)))
            r.inspector.time = 1.5
        }
        r.inspector.editor = editor
        r.inspector.selection = ["clip:a"]
        if r.inspector.openGroupId != group { r.inspector.toggleGroup(group) }
        return r
    }

    static func renders(_ variant: String) -> RightPanel {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        let r = RightPanel(layout: layout)
        let now = 1_800_000_000.0
        r.now = { now }
        let done = RenderJobView(id: "1", name: "jk_2026-10-13.mp4", status: .complete, progress: 1, thumbnail: frame(),
                                 createdAt: now - 3600, sizeBytes: 48_200_000, durationMs: 42_000)
        if variant == "mixed" {
            r.jobs = [done,
                      .init(id: "2", name: "jk_2026-10-13_2.mp4", status: .failed, error: "Encoder exited with code 1", createdAt: now - 120),
                      .init(id: "3", name: "jk_2026-10-13_3.mp4", status: .cancelled, createdAt: now - 60),
                      .init(id: "4", name: "jk_2026-10-13_4.mp4", status: .rendering, stage: "Encoding frames", progress: 0.375, createdAt: now - 5)]
        } else {
            r.jobs = [done]
            r.lastRenderSeconds = 42
        }
        if variant == "error" { r.actionError = "Could not delete jk_2026-10-13.mp4: permission denied" }
        return r
    }

    /// Every audited panel state, drawn in the current appearance, as one region list per hit map.
    static func audit() throws -> [[Region]] {
        var maps: [[Region]] = []
        let c = PanelMeasureCanvas()

        let left = sidebar(), leftSize = CanvasSize(370, 1040)
        left.draw(c, size: leftSize)
        maps.append(regions("sidebar", left.hits, in: CanvasRect(x: 0, y: 0, width: leftSize.width, height: leftSize.height)) {
            $0 == .binArea
        })

        let rightSize = CanvasSize(409, 2000), rightBounds = CanvasRect(x: 0, y: 0, width: 409, height: 2000)
        for group in ["layout", "style", "grade", "effects", "audio-fx", "media"] {
            let r = try design(open: group)
            r.draw(c, size: rightSize)
            maps.append(regions("design", r.hits, in: rightBounds) { $0 == .content })
            maps.append(regions("design/\(group)", r.inspector.hits, in: rightBounds) { $0 == .body })
        }
        for group in keyedGroups {
            let r = try design(open: group, keyed: true)
            r.draw(c, size: rightSize)
            maps.append(regions("design/\(group)/keyed", r.inspector.hits, in: rightBounds) { $0 == .body })
        }
        for variant in ["done", "mixed", "error"] {
            let r = renders(variant), size = CanvasSize(409, 900)
            r.draw(c, size: size)
            maps.append(regions("renders/\(variant)", r.hits, in: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)) { $0 == .content })
        }

        let settings = SettingsPanel(), window = CanvasSize(1440, 900)
        settings.devices = [.init(id: "sink.a", name: "Speakers")]
        settings.exportFolderChosen("/media/exports")   // shows the Reset button too
        settings.open()
        settings.draw(c, size: window)
        maps.append(regions("settings", settings.hits, in: CanvasRect(x: 0, y: 0, width: window.width, height: window.height)) { $0 == .card })
        return maps
    }

    /// The groups whose rows carry keyframe controls (transform, opacity, volume).
    static let keyedGroups = ["layout", "style", "media"]

    static func isKeyframeControl(_ action: String) -> Bool {
        ["stopwatch(", "kfPrev(", "kfNext(", "keyframe("].contains { action.hasPrefix($0) }
    }

    /// The failing regions of every state as "<state> <action> <w>x<h>", without the listed exceptions.
    static func findings() throws -> [String] {
        let all = try audit().flatMap { failing($0) }
            .filter { exceptions["\($0.state) \($0.action)"] == nil }
            .map { "\($0.state) \($0.action) \(fmt($0.rect.width))x\(fmt($0.rect.height))" }
        return Array(Set(all)).sorted()
    }

    func testEveryTargetIsAtLeast24PointsOrSpaced() throws {
        var perMode: [ThemeMode: [String]] = [:]
        for m in ThemeMode.allCases {
            Theme.setMode(m)
            perMode[m] = try Self.findings()
        }
        Theme.setMode(.dark)
        let found = perMode[.dark] ?? []
        XCTAssertEqual(perMode[.light] ?? [], found, "hit geometry differs between dark and light")
        XCTAssertFalse(try Self.audit().allSatisfy { $0.isEmpty }, "the audit drew no hit regions")
        let new = found.filter { !Self.knownUndersized.contains($0) }
        XCTAssertEqual(new, [], "targets under 24×24 pt with no spacing (WCAG 2.2 SC 2.5.8); make the hit rect at least 24×24 "
                       + "(it may be larger than the glyph), space it, or list a WCAG exception with its reason:\n"
                       + new.map { "\"\($0)\"," }.joined(separator: "\n"))
        let fixed = Self.knownUndersized.subtracting(found).sorted()
        XCTAssertEqual(fixed, [], "these targets now pass; remove them from knownUndersized:\n" + fixed.joined(separator: "\n"))
    }

    /// Issue #149: with keys on both sides of the playhead every keyframe row draws all four controls (stopwatch,
    /// ‹, ◆, ›), each a 24 × 24 target of its own: at least the minimum and overlapping no other target of the row.
    func testKeyframeControlsAreFullTargetsThatDoNotOverlap() throws {
        var seen: [String: Int] = [:]
        // The 1440 × 900 and 1280 × 800 defaults and the narrowest the right panel goes.
        for (width, group) in [409.0, 364, PanelFit.minRight].flatMap({ w in Self.keyedGroups.map { (w, $0) } }) {
            let c = PanelMeasureCanvas(), size = CanvasSize(width, 2000), bounds = CanvasRect(x: 0, y: 0, width: width, height: 2000)
            let r = try Self.design(open: group, keyed: true)
            r.draw(c, size: size)
            let map = Self.regions("\(group)@\(Self.fmt(width))", r.inspector.hits, in: bounds) { $0 == .body }.filter { !$0.container }
            for k in map where Self.isKeyframeControl(k.action) {
                let kind = String(k.action.prefix { $0 != "(" })
                seen[kind, default: 0] += 1
                XCTAssertGreaterThanOrEqual(k.rect.width, Self.minimum, "\(k.state) \(k.action) width")
                XCTAssertGreaterThanOrEqual(k.rect.height, Self.minimum, "\(k.state) \(k.action) height")
                for o in map where o.action != k.action {
                    let a = k.rect, b = o.rect
                    let overlaps = min(a.maxX, b.maxX) - max(a.x, b.x) > 1e-9 && min(a.maxY, b.maxY) - max(a.y, b.y) > 1e-9
                    XCTAssertFalse(overlaps, "\(k.state) \(k.action) \(k.rect) overlaps \(o.action) \(o.rect)")
                }
            }
        }
        // Position, size (both pairs), rotation, scale, opacity and volume: each kind is drawn and audited.
        for kind in ["stopwatch", "kfPrev", "keyframe", "kfNext"] {
            XCTAssertGreaterThanOrEqual(seen[kind] ?? 0, 18, "\(kind) drawn on the keyed rows at each width")
        }
    }

    /// Codex review of #152: at every right-panel width, down to `PanelFit.minRight`, a keyed slider row (opacity,
    /// volume) keeps its track a pointer target wide. Beside the track the label ends before the track starts;
    /// stacked at narrow widths the label sits on its own line above the full-width track. Either way the value
    /// text starts after the track ends, so the knob never draws over either.
    func testKeyedSliderRowsKeepTheirTrackClearAtEveryWidth() throws {
        for width in [409.0, 364, 320, PanelFit.minRight] {
            for (group, key, label) in [("style", "opacity", "Opacity"), ("media", "volume", "Volume")] {
                let c = PanelMeasureCanvas(), size = CanvasSize(width, 2000)
                let r = try Self.design(open: group, keyed: true)
                r.draw(c, size: size)
                let track = try XCTUnwrap(r.inspector.hits.rect { $0 == .slider(key) }, "\(key) @\(width)")
                let stopwatch = try XCTUnwrap(r.inspector.hits.rect { $0 == .stopwatch(key) }, "\(key) @\(width)")
                XCTAssertGreaterThanOrEqual(track.width, Self.minimum, "\(key) track @\(width)")
                let row = { (t: (String, CanvasPoint, CanvasFont, CanvasColor)) in abs(t.1.y - track.midY) < track.height / 2 }
                let texts = c.texts.filter { row($0) && $0.1.x >= 0 && $0.1.x < width }
                let drawnLabel = try XCTUnwrap(c.texts.first { $0.0 == label && $0.1.x >= 0 && $0.1.x < width }, "\(key) label drawn in full @\(width)")
                if row(drawnLabel) {
                    XCTAssertLessThanOrEqual(drawnLabel.1.x + c.measureText(label, font: drawnLabel.2).width, track.x, "\(key) label clear of the track @\(width)")
                } else {
                    XCTAssertLessThan(drawnLabel.1.y, track.y, "\(key) label above the stacked track @\(width)")
                }
                // Stacked at narrow widths the keyframe gutter stays on the label line, so the value sits right of
                // the stopwatch column instead of left of it.
                let value = try XCTUnwrap(texts.first { $0.1.x > track.x && (row(drawnLabel) ? $0.1.x < stopwatch.x : true) }, "\(key) value drawn @\(width)")
                XCTAssertGreaterThanOrEqual(value.1.x, track.maxX, "\(key) value \(value.0) clear of the track @\(width)")
            }
        }
    }

    /// Issue #149: Tab reaches each keyframe control of a keyed row in reading order (stopwatch, ‹, ◆, ›), and Enter
    /// on a stepper seeks to the neighbouring key, as a click does.
    func testKeyboardFocusReachesEachKeyframeControl() throws {
        let r = try Self.design(open: "layout", keyed: true), c = PanelMeasureCanvas(), size = CanvasSize(409, 2000)
        var seeks: [Double] = []
        r.inspector.onSeek = { seeks.append($0) }
        r.draw(c, size: size)
        var steps = 0
        while r.inspector.focus.current != .stopwatch("rotation"), steps < 400 {
            XCTAssertTrue(r.inspector.keyDown(EditorKey(.tab))); r.draw(c, size: size); steps += 1
        }
        XCTAssertEqual(r.inspector.focus.current, .stopwatch("rotation"), "Tab reaches the stopwatch")
        for want in [InspectorPanel.Hit.kfPrev("rotation"), .keyframe("rotation"), .kfNext("rotation")] {
            XCTAssertTrue(r.inspector.keyDown(EditorKey(.tab))); r.draw(c, size: size)
            XCTAssertEqual(r.inspector.focus.current, want)
            XCTAssertTrue(r.inspector.focus.visible)
        }
        XCTAssertTrue(r.inspector.keyDown(EditorKey(.enter)))
        XCTAssertEqual(seeks, [2.5], "Enter on › seeks to the next key")
        r.draw(c, size: size)
        XCTAssertTrue(r.inspector.keyDown(EditorKey(.tab, shift: true))); r.draw(c, size: size)
        XCTAssertTrue(r.inspector.keyDown(EditorKey(.tab, shift: true))); r.draw(c, size: size)
        XCTAssertEqual(r.inspector.focus.current, .kfPrev("rotation"), "⇧Tab walks back")
        XCTAssertTrue(r.inspector.keyDown(EditorKey(.enter)))
        XCTAssertEqual(seeks, [2.5, 0.5], "Enter on ‹ seeks to the previous key")
    }

    /// Issue #185: authored Grade/Effects fixtures expose the controls absent from the default audit.
    func testGradeAndEffectsTargetsAndHover() throws {
        for mode in ThemeMode.allCases {
            Theme.setMode(mode)
            for width in [409.0, 364, PanelFit.minRight] {
                for group in ["grade", "effects"] {
                    let right = try Self.design(open: group), panel = right.inspector
                    try configureGradeAndEffects(panel)
                    let canvas = PanelMeasureCanvas(), size = CanvasSize(width, 4000)
                    // The asserted draw uses a taller canvas: with the Finish tune rows open the grade
                    // column is ~4520pt at 364pt wide, and rows past the canvas are culled, not drawn.
                    let tall = CanvasSize(width, 6000)
                    right.draw(canvas, size: tall)
                    try captureGradeAndEffects(right, group: group, width: width, mode: mode, size: size)
                    right.draw(canvas, size: tall)
                    let targets = panel.hits.regions.filter { isGradeOrEffectsTarget($0.action) }

                    let expected: [InspectorPanel.Hit] = group == "grade"
                        ? [.groupReset("grade"), .reset("grade:adj:exposure"), .keyframe("grade:det:vignette#gear"),
                           .custom("sec:head", 0), .custom("sec:head", 1), .custom("grade:scopes", InspectorPanel.ScopePart.refresh),
                           .custom("grade:curvefoot", 0), .custom("grade:curvefoot", 1)]
                        : [.groupReset("effects"), .custom("fx:head", 0), .custom("fx:head", 1), .custom("fx:tabs", 0)]
                    for action in expected { XCTAssertTrue(targets.contains { $0.action == action }, "\(group) \(width) \(mode): fixture draws \(action)") }
                    for target in targets {
                        let context = "\(group) \(width) \(target.action)"
                        XCTAssertGreaterThanOrEqual(target.rect.width, 24, context)
                        XCTAssertGreaterThanOrEqual(target.rect.height, 24, context)
                        assertNoTargetOverlap(target.rect, action: target.action, panel: panel, context: context)
                        if needsTargetLabel(target.action) {
                            XCTAssertFalse(target.accessibilityLabel?.isEmpty ?? true, context)
                        }
                        panel.hovered = target.action
                        canvas.reset(); right.draw(canvas, size: tall)
                        XCTAssertTrue(canvas.fills.contains { path, color in
                            path == .roundedRect(target.rect, radius: PanelTheme.radius) && color == PanelTheme.panelHover
                        }, "whole target hover: " + context)
                    }
                }
            }
        }
    }

    private func configureGradeAndEffects(_ panel: InspectorPanel) throws {
    var grade = ColorGrading()
    grade.secondaries = [.init()]
    grade.adjust["exposure"] = 0.4
    grade.details["vignette"] = 0.5
    grade.curves["master"] = [[0, 0], [0.5, 0.7], [1, 1]]
    grade.effects["blur"] = 0.45
    XCTAssertTrue(try XCTUnwrap(panel.editor).setColorGrading(clipId: "clip:a", grade))
    panel.grade.scopesOpen = true
    panel.grade.selectedPoint = 1
    panel.grade.finishSettings = "vignette"
    panel.effectsUI.clipId = "clip:a"
    panel.effectsUI.selectedKey = "blur"
    panel.effectsUI.catalogOpen = true
    }

    private func captureGradeAndEffects(_ right: RightPanel, group: String, width: Double,
                                       mode: ThemeMode, size: CanvasSize) throws {
        #if os(macOS)
        let panel = right.inspector
        if width == 409, let directory = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            panel.hovered = group == "grade" ? .custom("sec:head", 0) : .custom("fx:head", 1)
            let bitmap = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: 409, height: group == "grade" ? 4000 : 600))
            right.draw(bitmap, size: size)
            let image = try XCTUnwrap(bitmap.ctx.makeImage())
            let url = URL(fileURLWithPath: directory).appendingPathComponent("issue185-\(group)-\(mode.rawValue).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        #endif
    }

    private func isGradeOrEffectsTarget(_ action: InspectorPanel.Hit) -> Bool {
        switch action {
        case .reset, .groupReset: return true
        case .keyframe(let key): return key.hasSuffix(InspectorPanel.gearSuffix)
        case .custom(let id, let part):
            return ["sec:head", "fx:head", "fx:tabs", "grade:curvetabs", "grade:curvefoot"].contains(id)
                || (id == "grade:scopes" && part != InspectorPanel.ScopePart.toggle)
                || (["grade:balance", "grade:wheels"].contains(id) && part >= 20)
        default: return false
        }
    }

    private func assertNoTargetOverlap(_ rect: CanvasRect, action: InspectorPanel.Hit,
                                       panel: InspectorPanel, context: String) {
        for other in panel.hits.regions where other.action != action {
            switch other.action {
            case .body, .group, .custom("grade:scopes", InspectorPanel.ScopePart.toggle): continue
            default: break
            }
            let otherRect = other.rect
            XCTAssertFalse(min(rect.maxX, otherRect.maxX) > max(rect.x, otherRect.x) + 1e-9
                && min(rect.maxY, otherRect.maxY) > max(rect.y, otherRect.y) + 1e-9,
                context + " overlaps \(other.action)")
        }
    }

    private func needsTargetLabel(_ action: InspectorPanel.Hit) -> Bool {
        switch action {
        case .custom("fx:tabs", _), .custom("grade:curvetabs", _), .custom("grade:curvefoot", _): return false
        case .custom("sec:head", let part) where part >= 10: return false
        case .custom("grade:scopes", let part) where part != InspectorPanel.ScopePart.refresh: return false
        default: return true
        }
    }

    /// The rule itself on hand-made maps: a 16 × 16 button alone passes by spacing, two 16 × 16 buttons 20 apart
    /// fail, a 16 × 16 button inside a row target fails, a container does not count, and 24 × 24 always passes.
    func testTheRuleIsWcagTwoFiveEight() {
        func region(_ a: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, container: Bool = false) -> Region {
            Region(state: "t", action: a, rect: CanvasRect(x: x, y: y, width: w, height: h), container: container)
        }
        let body = region("body", 0, 0, 400, 400, container: true)
        XCTAssertTrue(Self.failing([body, region("a", 100, 100, 16, 16)]).isEmpty, "alone and spaced")
        XCTAssertEqual(Self.failing([region("a", 100, 100, 16, 16), region("b", 120, 100, 16, 16)]).map(\.action), ["a", "b"], "circles intersect")
        XCTAssertTrue(Self.failing([region("a", 100, 100, 16, 16), region("b", 124, 100, 16, 16)]).isEmpty, "centres 24 apart: circles touch, no overlap")
        XCTAssertEqual(Self.failing([region("row", 0, 96, 400, 24), region("a", 300, 100, 16, 16)]).map(\.action), ["a"], "inside a larger target")
        XCTAssertTrue(Self.failing([region("a", 100, 100, 24, 24), region("b", 124, 100, 24, 24)]).isEmpty, "24 × 24 needs no spacing")
        XCTAssertEqual(Self.fmt(24), "24"); XCTAssertEqual(Self.fmt(26.5), "26.5")
    }
}

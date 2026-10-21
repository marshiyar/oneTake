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
            $0 == .libraryArea || $0 == .binArea
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
        let c = PanelMeasureCanvas(), size = CanvasSize(409, 2000), bounds = CanvasRect(x: 0, y: 0, width: 409, height: 2000)
        var seen: [String: Int] = [:]
        for group in Self.keyedGroups {
            let r = try Self.design(open: group, keyed: true)
            r.draw(c, size: size)
            let map = Self.regions(group, r.inspector.hits, in: bounds) { $0 == .body }.filter { !$0.container }
            for k in map where Self.isKeyframeControl(k.action) {
                let kind = String(k.action.prefix { $0 != "(" })
                seen[kind, default: 0] += 1
                XCTAssertGreaterThanOrEqual(k.rect.width, Self.minimum, "\(group) \(k.action) width")
                XCTAssertGreaterThanOrEqual(k.rect.height, Self.minimum, "\(group) \(k.action) height")
                for o in map where o.action != k.action {
                    let a = k.rect, b = o.rect
                    let overlaps = min(a.maxX, b.maxX) - max(a.x, b.x) > 1e-9 && min(a.maxY, b.maxY) - max(a.y, b.y) > 1e-9
                    XCTAssertFalse(overlaps, "\(group) \(k.action) \(k.rect) overlaps \(o.action) \(o.rect)")
                }
            }
        }
        // Position, size (both pairs), rotation, scale, opacity and volume: each kind is drawn and audited.
        for kind in ["stopwatch", "kfPrev", "keyframe", "kfNext"] {
            XCTAssertGreaterThanOrEqual(seen[kind] ?? 0, 6, "\(kind) drawn on the keyed rows")
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

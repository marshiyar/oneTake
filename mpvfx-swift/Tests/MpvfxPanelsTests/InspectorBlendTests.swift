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
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxPanels
@testable import MpvfxTimeline

/// The Style group's Blend dropdown: one undo step per pick, the saved `clip.style.blend`, the tier and the reset.
final class InspectorBlendTests: XCTestCase {
    private func panel() throws -> (RightPanel, TimelineEditor) {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let r = RightPanel(layout: layout)
        let editor = try TimelineEditor(json: InspectorMediaFitTests.json, engine: try KeyframeRuntime())
        r.inspector.editor = editor
        r.inspector.selection = ["clip:a"]
        r.inspector.openGroupId = "style"
        return (r, editor)
    }

    internal func testCompositingComesBeforeAppearanceAndOpacityEasingStaysInStyle() throws {
        let (r, editor) = try panel()
        let opacity = TimelineEditor.opacityId
        XCTAssertTrue(editor.keyableParameters(clipId: "clip:a", time: 0).contains { $0.parameterId == opacity })
        XCTAssertTrue(editor.keyProperties(clipIds: ["clip:a"], time: 0, animatedOnly: false))
        XCTAssertTrue(editor.isAnimated(clipId: "clip:a", opacity))
        let address = try XCTUnwrap(editor.parameterAddress(clipId: "clip:a", opacity))
        XCTAssertTrue(
            editor.applyProperty(
                .atomic(
                    .keyframe(
                        .upsert(
                            address: address,
                            valueType: .number,
                            frame: 0,
                            value: .number(0.5),
                            baselineValue: .number(1)
                        )
                    )
                )
            )
        )
        let style = try XCTUnwrap(r.inspector.groups.first { $0.id == "style" })
        guard case .heading("Compositing", _) = style.rows[0].kind,
            case .slider(let row) = style.rows[1].kind,
            case .custom(let blend) = style.rows[2].kind
        else {
            XCTFail("Compositing must lead Style")
            return
        }
        XCTAssertEqual(row.key, "opacity")
        XCTAssertEqual(blend.id, "blend")
        XCTAssertEqual(TimelineEditor.keyframeEasingGroup(opacity), "style")
        XCTAssertFalse(TimelineEditor.transformEasedParameterIds.contains(opacity))
        let ref = TimelineKeyframeRef(clipId: "clip:a", parameterId: opacity, frame: 0)
        XCTAssertTrue(r.showKeyframeEasing(clipId: "clip:a", refs: [ref]))
        XCTAssertEqual(r.inspector.openGroupId, "style")
        XCTAssertEqual(r.easing.state.chosenProperty, opacity)
        XCTAssertEqual(r.easing.selectedKeyframes, [ref])
        XCTAssertTrue(
            style.rows.contains {
                if case .buttons(let buttons) = $0.kind { return buttons.contains { $0.key == "openEasing" } }
                return false
            }
        )
    }

    internal func testStackedAndUnstackedValuesShareTheReservedEdge() throws {
        let (r, _) = try panel()
        let p = r.inspector
        for width in [360.0, 409.0, 560.0] {
            let rect = CanvasRect(x: 16, y: 0, width: width - 32, height: 60)
            let edge = InspectorPanel.valueEdge(rect)
            for stacked in [false, true] {
                let c = PanelMeasureCanvas()
                p.drawNumber(
                    c,
                    rect,
                    .init(key: "plain", label: "Layer order", text: "0", tier: .default, commit: { _ in }),
                    compact: false,
                    stacked: stacked
                )
                XCTAssertEqual(try XCTUnwrap(p.hits.rect { $0 == .field("plain") }).maxX, edge)
                p.drawSlider(
                    c,
                    rect,
                    .init(
                        key: "opacity",
                        label: "Opacity",
                        position: 100,
                        min: 0,
                        max: 100,
                        display: "100%",
                        format: { _ in "100%" },
                        tier: .default,
                        commit: { _ in }
                    ),
                    stacked: stacked
                )
                let value = try XCTUnwrap(c.texts.last { $0.0 == "100%" })
                XCTAssertEqual(value.1.x + c.measureText(value.0, font: value.2).width, edge, accuracy: 0.001)
            }
            try assertPairValueEdges(p, rect: rect, edge: edge)
            let options = InspectorRow.Segmented(
                key: "alignment",
                label: "Alignment",
                options: [(key: "a", label: "Start", active: true), (key: "b", label: "End", active: false)],
                select: { _ in }
            )
            for stacked in [false, true] {
                p.drawSegmented(PanelMeasureCanvas(), rect, options, stacked: stacked)
                XCTAssertEqual(try XCTUnwrap(p.hits.rect { $0 == .segment("alignment", "b") }).maxX, edge)
            }
            for mode in [NativeBlendMode.normal, .screen] {
                p.drawBlend(PanelMeasureCanvas(), rect, mode: mode)
                XCTAssertEqual(try XCTUnwrap(p.hits.rect { $0 == .custom("blend", 0) }).maxX, edge)
            }
        }
    }

    private func assertPairValueEdges(_ inspector: InspectorPanel, rect: CanvasRect, edge: Double) throws {
        for stacked in [false, true] {
            let a = InspectorRow.Number(
                key: "x",
                label: "X",
                text: "12px",
                tier: .explicitCustom,
                commit: { _ in },
                reset: {}
            )
            let b = InspectorRow.Number(
                key: "y",
                label: "Y",
                text: "24px",
                tier: .explicitCustom,
                commit: { _ in },
                reset: {}
            )
            inspector.drawPair(PanelMeasureCanvas(), rect, label: "Position", a, b, stacked: stacked)
            XCTAssertEqual(try XCTUnwrap(inspector.hits.rect { $0 == .field("y") }).maxX, edge)
            XCTAssertNotNil(inspector.hits.rect { $0 == .reset("x") })
        }
    }

    internal func testTransformStyleAndMediaKeepTheirValueEdgeWithAndWithoutKeys() throws {
        for keyed in [false, true] {
            let (r, editor) = try panel()
            if keyed { XCTAssertTrue(editor.keyProperties(clipIds: ["clip:a"], time: 0, animatedOnly: false)) }
            for width in [360.0, 409.0] {
                var edges: [Double] = []
                for group in ["layout", "style", "media"] {
                    edges += try valueEdges(r.inspector, group: group, width: width)
                }
                XCTAssertGreaterThan(edges.count, 6)
                for edge in edges { XCTAssertEqual(edge, try XCTUnwrap(edges.first), accuracy: 0.001) }
            }
        }
    }

    private func valueEdges(_ inspector: InspectorPanel, group: String, width: Double) throws -> [Double] {
        inspector.openGroupId = group
        let canvas = PanelMeasureCanvas()
        inspector.draw(canvas, in: CanvasRect(x: 0, y: 0, width: width, height: 4_000))
        let keys: [String]
        switch group {
        case "layout": keys = ["y", "h", "rotation", "scale", "layerOrder"]
        case "style": keys = ["fill", "strokeColor"]
        default: keys = ["rate"]
        }
        var edges: [Double] = keys.compactMap { key in
            inspector.hits.rect(where: { $0 == .field(key) })?.maxX
        }
        if group == "media" { edges += try mediaValueEdges(inspector, canvas: canvas) }
        if group == "style", let field = inspector.hits.rect(where: { $0 == .custom("blend", 0) }) {
            edges.append(field.maxX)
        }
        return edges
    }

    private func mediaValueEdges(_ inspector: InspectorPanel, canvas: PanelMeasureCanvas) throws -> [Double] {
        var edges: [Double] = [try XCTUnwrap(inspector.hits.rect { $0 == .custom("mediaFit", 0) }).maxX]
        for row in try XCTUnwrap(inspector.groups.first { $0.id == "media" }).rows {
            if case .slider(let slider) = row.kind, ["rate", "volume"].contains(slider.key) {
                let value = try XCTUnwrap(canvas.texts.last { $0.0 == slider.display })
                edges.append(value.1.x + canvas.measureText(value.0, font: value.2).width)
            }
        }
        return edges
    }

    internal func testTheStyleGroupHasABlendRowWithEveryMode() throws {
        let (r, _) = try panel()
        XCTAssertNotNil(r.inspector.customRow(InspectorPanel.blendRowId))
        XCTAssertEqual(
            InspectorPanel.blendOptions().map(\.label),
            ["Normal", "Multiply", "Screen", "Overlay", "Add", "Soft light", "Darken", "Lighten"]
        )
        XCTAssertEqual(InspectorPanel.blendTier(.normal), .default)
        XCTAssertEqual(InspectorPanel.blendTier(.screen), .explicitCustom)
    }

    internal func testEachPickIsOneUndoStepSavedInTheStyleAndResetRemovesTheKey() throws {
        let (r, editor) = try panel()
        let depth = editor.undoStack.count
        XCTAssertTrue(editor.setClipBlend(clipId: "clip:a", .multiply))
        XCTAssertEqual(editor.clipStyle(clipId: "clip:a").blend, "multiply")
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertFalse(editor.setClipBlend(clipId: "clip:a", .multiply), "the shown value again is no edit")
        XCTAssertTrue(editor.setClipBlend(clipId: "clip:a", .softLight))
        XCTAssertEqual(editor.clipStyle(clipId: "clip:a").blend, "soft-light")
        XCTAssertTrue(editor.setClipBlend(clipId: "clip:a", .normal))
        XCTAssertNil(editor.clip("clip:a")?.1.style, "normal removes the key and the empty style with it")
        XCTAssertEqual(editor.undoStack.count, depth + 3)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.clipStyle(clipId: "clip:a").blend, "soft-light")
        XCTAssertTrue(editor.undo())
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clipStyle(clipId: "clip:a").blend)
        _ = r
    }

    internal func testTheSelectOpensTheDropdownAndThePickAndResetEdit() throws {
        let (r, editor) = try panel()
        r.draw(PanelMeasureCanvas(), size: CanvasSize(409, 1400))
        let field = try XCTUnwrap(r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.blendRowId, 0) }))
        XCTAssertNil(
            r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.blendRowId, 1) }),
            "no reset at Normal"
        )
        XCTAssertTrue(r.pointerDown(CanvasPoint(field.midX, field.midY)))
        XCTAssertTrue(r.dropdown.isOpen)
        XCTAssertEqual(
            r.dropdown.options.map(\.value),
            ["normal", "multiply", "screen", "overlay", "add", "soft-light", "darken", "lighten"]
        )
        XCTAssertEqual(r.dropdown.selected, "normal", "the current mode is highlighted")
        r.dropdown.pick("screen")
        XCTAssertFalse(r.dropdown.isOpen)
        XCTAssertEqual(editor.undoLabel, "Set blend mode")
        XCTAssertEqual(editor.clipStyle(clipId: "clip:a").blend, "screen")
        r.draw(PanelMeasureCanvas(), size: CanvasSize(409, 1400))
        let reset = try XCTUnwrap(
            r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.blendRowId, 1) }),
            "reset shows once a mode is set"
        )
        XCTAssertTrue(r.pointerDown(CanvasPoint(reset.midX, reset.midY)))
        XCTAssertNil(editor.clipStyle(clipId: "clip:a").blend)
    }
}

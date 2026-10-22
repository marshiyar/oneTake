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
import MpvfxAudioGraph
import MpvfxAudio
import OneTakeKeyframes
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Audio FX rack (FxRackChain / FxPresetRun / FxNodeRow / FxEqModule / FxPresetMenu):
/// what each row shows, and that every control writes the clip's chain.
final class AudioFxRackTests: XCTestCase {
    static let width = 409.0, height = 4000.0

    /// The reference rack: a Tone EQ with Bass +3, Clean Voice (folded, as every run present at mount is) and a
    /// bypassed Echo, on the demo's music clip.
    static func referenceChain() -> FxChain {
        var (chain, eqId) = AudioEq.add(FxChain())
        chain = AudioEq.setBandGain(chain, eqId: eqId, band: "Bass", gain: 3)
        chain = AudioFxPresets.apply(chain, AudioFxPresets.preset("voice-clean")!)
        chain.nodes.append(FxNode(type: "delay", id: chain.mintNodeId(), enabled: false, params: AudioFx.defaultParams("delay")))
        return chain
    }

    func fixture(_ chain: FxChain? = referenceChain()) throws -> (TimelineEditor, InspectorPanel) { try Self.makeFixture(chain) }
    static func makeFixture(_ chain: FxChain? = referenceChain()) throws -> (TimelineEditor, InspectorPanel) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        if let chain { XCTAssertTrue(editor.setClipFxChain(clipId: "clip:music", AudioFx.serializeChain(chain))) }
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:music"]; p.openGroupId = "audio-fx"
        return (editor, p)
    }

    @discardableResult
    func draw(_ p: InspectorPanel) -> PanelMeasureCanvas {
        let c = PanelMeasureCanvas(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: Self.width, height: Self.height)); return c
    }
    func press(_ p: InspectorPanel, _ h: InspectorPanel.Hit, file: StaticString = #filePath, line: UInt = #line) throws {
        draw(p)
        let r = try XCTUnwrap(p.hits.rect { $0 == h }, "no \(h)", file: file, line: line)
        XCTAssertTrue(p.pointerDown(CanvasPoint(r.midX, r.midY)), file: file, line: line)
        p.pointerUp(CanvasPoint(r.midX, r.midY))
    }
    func chain(_ e: TimelineEditor) -> FxChain {
        (e.clip("clip:music")?.clip.audioFxChain).flatMap { try? AudioFx.parseChain($0) } ?? FxChain()
    }
    func texts(_ c: PanelMeasureCanvas) -> [String] { c.texts.map(\.0) }

<<<<<<< HEAD
    func liveFixture(_ chain: FxChain) throws -> (TimelineEditor, InspectorPanel) {
        let json = TimelineEditor.demoJSON.replacingOccurrences(of: "\"name\":\"music.wav\"", with: "\"name\":\"music.wav\",\"source\":\"/music.wav\"")
        let editor = try TimelineEditor(json: json, engine: try? KeyframeRuntime())
        XCTAssertTrue(editor.setClipFxChain(clipId: "clip:music", AudioFx.serializeChain(chain)))
        let panel = InspectorPanel(); panel.editor = editor; panel.selection = ["clip:music"]; panel.openGroupId = "audio-fx"
        return (editor, panel)
    }

    func testSliderDragPublishesIntermediateLiveGraphInputsEveryThirtyMillisecondsAndOneUndo() throws {
        for bus in [false, true] {
            let initial = FxChain(nodes: [FxNode(type: "gain", id: "gain", params: AudioFx.defaultParams("gain"))])
            let (editor, panel) = try liveFixture(initial)
            var groupId: String?
            if bus {
                groupId = try XCTUnwrap(editor.createAudioGroup(clipIds: ["clip:music", "clip:a", "clip:b"]))
                XCTAssertTrue(editor.setAudioGroupFxChain(try XCTUnwrap(groupId), AudioFx.serializeChain(initial)))
                panel.selection = []; panel.audioGroupId = groupId
            }
            func current() -> FxChain {
                let text = groupId.flatMap { editor.audioGroup($0)?.fxChain } ?? editor.clip("clip:music")?.clip.audioFxChain
                return text.flatMap { try? AudioFx.parseChain($0) } ?? FxChain()
            }
            draw(panel)
            let track = try XCTUnwrap(panel.hits.rect { $0 == .slider("fx:0:gain") })
            let before = editor.document, count = editor.undoStack.count
            var now = 10.0; panel.fxGestureNow = { now }
            var received: [String?] = []
            let source = GraphAudioSource(project: AudioGraphProject(duration: 0.1, sampleRate: 48000, tracks: []))
            let updater = LiveAudioGraphUpdater(source: source, loadStem: { _ in [[Float](repeating: 0.2, count: 4800)] })
            editor.onChange = {
                let inputs = DocumentAudioGraph.inputs(editor.document, duration: 0.1, projectDir: nil, fileExists: { _ in true })
                received.append(groupId.flatMap { id in inputs.groups.first { $0.id == id }?.fxChain }
                    ?? inputs.tracks.first { $0.id == "clip:music" }?.fxChain)
                updater.submit(inputs)
            }
            XCTAssertTrue(panel.pointerDown(CanvasPoint(track.x, track.midY)))
            XCTAssertEqual(received.count, 1)
            XCTAssertEqual(updater.waits, 0)
            updater.waitUntilIdle() // Test synchronization only, outside the edit hook.
            source.seek(0)
            _ = source.render(frames: 1024)
            let quiet = source.render(frames: 1024).map { abs($0) }.max() ?? 0
            now += 0.010
            _ = panel.pointerMove(CanvasPoint(track.midX, track.midY))
            XCTAssertEqual(received.count, 1, "writes inside 30 ms are coalesced")
            now += 0.021
            _ = panel.pointerMove(CanvasPoint(track.maxX - 1, track.midY))
            XCTAssertEqual(received.count, 2)
            XCTAssertNotNil(received.last.flatMap { $0 })
            XCTAssertNotEqual(received.first.flatMap { $0 }, received.last.flatMap { $0 })
            XCTAssertNotEqual(current(), initial)
            XCTAssertEqual(updater.waits, 1)
            updater.waitUntilIdle()
            source.seek(0)
            _ = source.render(frames: 1024)
            let loud = source.render(frames: 1024).map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(loud, quiet * 2, "intermediate drag values are audible before release")
            XCTAssertEqual(editor.undoStack.count, count)
            draw(panel)
            panel.pointerUp(CanvasPoint(track.maxX - 1, track.midY))
            XCTAssertEqual(editor.undoStack.count, count + 1)
            XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.document, before)
            XCTAssertTrue(editor.redo()); XCTAssertNotEqual(current(), initial)
            XCTAssertEqual(updater.waits, 2, "only the test waits on graph work")
            editor.onChange = nil
            updater.waitUntilIdle()
        }
    }

    func testGraphDragPublishesBeforeReleaseAndCancelsThenRepeatsWithOneUndo() throws {
        let initial = FxChain(nodes: [FxNode(type: "peaking", id: "bell", params: AudioFx.defaultParams("peaking"))])
        let (editor, panel) = try liveFixture(initial)
        draw(panel)
        let handle = try XCTUnwrap(panel.hits.rect { $0 == .custom("afx:node:0", 1) })
        let graph = try XCTUnwrap(panel.audioFxUI.graphBoxes["afx:node:0"])
        let before = editor.document, count = editor.undoStack.count
        var now = 0.0; panel.fxGestureNow = { now }
        let to = CanvasPoint(AfxGraphScale.x(2200, in: graph.box), AfxGraphScale.y(6, range: graph.range, in: graph.box))
        for cancel in [true, false, false] {
            draw(panel) // The host redraws after cancellation/undo before the next gesture.
            XCTAssertTrue(panel.pointerDown(CanvasPoint(handle.midX, handle.midY)))
            now += 1
            _ = panel.pointerMove(to)
            XCTAssertNotEqual(editor.document, before)
            draw(panel)
            if cancel {
                XCTAssertTrue(panel.keyDown(EditorKey(.escape)))
                panel.pointerUp(to)
                XCTAssertEqual(editor.document, before)
                XCTAssertEqual(editor.undoStack.count, count)
            } else {
                panel.pointerUp(to)
                XCTAssertEqual(editor.undoStack.count, count + 1)
                XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.document, before)
                draw(panel)
            }
        }
    }

    func testHeaderDropFirstToThirdAndAltArrowEachRecordOneUndo() throws {
        let initial = FxChain(nodes: ["gain", "delay", "lowpass"].enumerated().map {
            FxNode(type: $0.element, id: "n\($0.offset)", params: AudioFx.defaultParams($0.element))
        })
        let (editor, panel) = try liveFixture(initial)
        draw(panel)
        let first = try XCTUnwrap(panel.hits.rect { $0 == .button("fx:0:open") })
        let third = try XCTUnwrap(panel.fxHeaders[2])
        let count = editor.undoStack.count
        let stored = chain(editor)
        XCTAssertTrue(panel.pointerDown(CanvasPoint(first.midX, first.midY)))
        let drop = CanvasPoint(third.midX, third.maxY + 2)
        _ = panel.pointerMove(drop)
        draw(panel)
        panel.pointerUp(drop)
        XCTAssertEqual(chain(editor).nodes.map(\.id), ["n1", "n2", "n0"])
        XCTAssertEqual(editor.undoStack.count, count + 1)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(chain(editor), stored)
        draw(panel)
        panel.fxHeaderFocused = 0
        XCTAssertTrue(panel.keyDown(EditorKey(.down, alt: true)))
        XCTAssertEqual(chain(editor).nodes.map(\.id), ["n1", "n0", "n2"])
        XCTAssertEqual(editor.undoStack.count, count + 1)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(chain(editor), stored)
    }

    func testToneAndPresetHeadersMoveWholeModulesAndPreserveOneUndo() throws {
        let (editor, panel) = try fixture()
        draw(panel)
        let before = editor.document, original = chain(editor), count = editor.undoStack.count
        let eqId = try XCTUnwrap(AudioEq.ids(original).first)
        let tone = try XCTUnwrap(panel.hits.rect { $0 == .button("eq:\(eqId):open") })
        let last = try XCTUnwrap(panel.fxHeaders.values.max { $0.y < $1.y })
        XCTAssertTrue(panel.pointerDown(CanvasPoint(tone.midX, tone.midY)))
        let drop = CanvasPoint(last.midX, last.maxY + 5)
        _ = panel.pointerMove(drop); panel.pointerUp(drop)
        XCTAssertEqual(Array(chain(editor).nodes.suffix(3)).map(\.id), Array(original.nodes.prefix(3)).map(\.id))
        draw(panel)
        XCTAssertGreaterThan(try XCTUnwrap(panel.hits.rect { $0 == .button("eq:\(eqId):open") }).y,
                             try XCTUnwrap(panel.hits.rect { $0 == .button("fx:5:open") }).y)
        XCTAssertEqual(editor.undoStack.count, count + 1)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.document, before)
        draw(panel)
        let preset = try XCTUnwrap(panel.hits.rect { $0 == .button("run:voice-clean-3:collapse") })
        let first = try XCTUnwrap(panel.fxHeaders[0])
        XCTAssertTrue(panel.pointerDown(CanvasPoint(preset.midX, preset.midY)))
        _ = panel.pointerMove(CanvasPoint(first.midX, first.y - 3))
        panel.pointerUp(CanvasPoint(first.midX, first.y - 3))
        XCTAssertEqual(Array(chain(editor).nodes.prefix(5)).map(\.id), Array(original.nodes[3..<8]).map(\.id))
        XCTAssertEqual(editor.undoStack.count, count + 1)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.document, before)
    }

    func testChangingRackOwnerCancelsSliderWithoutHistory() throws {
        let (editor, panel) = try liveFixture(FxChain(nodes: [FxNode(type: "gain", id: "gain")]))
        draw(panel)
        let before = editor.document, count = editor.undoStack.count
        let track = try XCTUnwrap(panel.hits.rect { $0 == .slider("fx:0:gain") })
        XCTAssertTrue(panel.pointerDown(CanvasPoint(track.x, track.midY)))
        XCTAssertNotEqual(editor.document, before)
        panel.selection = []
        XCTAssertEqual(editor.document, before)
        panel.pointerUp(CanvasPoint(track.maxX, track.midY))
        XCTAssertEqual(editor.undoStack.count, count)
    }

    func testContinuousRackDragsSubmitWithoutMainLoopStalls() throws {
        for bus in [false, true] {
            let initial = FxChain(nodes: [FxNode(type: "gain", id: "gain", params: AudioFx.defaultParams("gain"))])
            let (editor, panel) = try liveFixture(initial)
            if bus {
                let id = try XCTUnwrap(editor.createAudioGroup(clipIds: ["clip:music", "clip:a", "clip:b"]))
                XCTAssertTrue(editor.setAudioGroupFxChain(id, AudioFx.serializeChain(initial)))
                panel.selection = []; panel.audioGroupId = id
            }
            draw(panel)
            let track = try XCTUnwrap(panel.hits.rect { $0 == .slider("fx:0:gain") })
            let source = GraphAudioSource(project: AudioGraphProject(duration: 0.1, sampleRate: 48000, tracks: []))
            let updater = LiveAudioGraphUpdater(source: source, loadStem: { _ in [[Float](repeating: 0.2, count: 4800)] })
            editor.onChange = {
                updater.submit(DocumentAudioGraph.inputs(editor.document, duration: 0.1, projectDir: nil, fileExists: { _ in true }))
            }
            var now = 0.0; panel.fxGestureNow = { now }
            XCTAssertTrue(panel.pointerDown(CanvasPoint(track.x, track.midY)))
            var worst = 0.0
            for i in 0..<1000 {
                now += 0.031
                let start = Date().timeIntervalSinceReferenceDate
                _ = panel.pointerMove(CanvasPoint(track.x + Double(i % 100) / 100 * track.width, track.midY))
                worst = max(worst, Date().timeIntervalSinceReferenceDate - start)
            }
            panel.pointerUp(CanvasPoint(track.midX, track.midY))
            XCTAssertLessThan(worst, 0.250, "same minimum stall bound as audio FX live stress")
            XCTAssertEqual(updater.waits, 0)
            editor.onChange = nil; updater.waitUntilIdle()
        }
    }

=======
>>>>>>> origin/main
    func testUpdateCurrentSoundIsOneUndoStep() throws {
        let old = try AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"highpass","id":"n1"},{"type":"compressor","id":"n2"}]}"#)
        let (editor, panel) = try fixture(old)
        XCTAssertTrue(texts(draw(panel)).contains("Update to current sound"))
        try press(panel, .button("fx:update-sound"))
        XCTAssertEqual(chain(editor), old.updatedSound())
        XCTAssertFalse(texts(draw(panel)).contains("Update to current sound"))
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(chain(editor), old)
    }

    func testRackRowsReadLikeTheStudio() throws {
        let (_, p) = try fixture()
        let t = texts(draw(p))
        for s in ["Tone", "3-band", "Bass +3", "Clean Voice", "5", "On", "Amount", "1.00", "07", "Off", "Echo every 250 ms", "Presets", "+ effect"] {
            XCTAssertTrue(t.contains(s), "missing \(s)")
        }
        XCTAssertFalse(t.contains("Remove Rumble"), "a folded run hides its modules")
        // The Echo module letters by its family (time: tracked caps), one glyph at a time.
        XCTAssertTrue(t.joined().contains("ECHO"))
        XCTAssertNotNil(p.hits.rect { $0 == .fxToggle("fx:8") })
        XCTAssertNil(p.hits.rect { $0 == .button("preset:voice-clean") }, "the shelf is closed")
        // Empty rack: the studio's sentence, with both buttons.
        let (_, q) = try fixture(nil)
        let e = texts(draw(q))
        XCTAssertTrue(e.contains("No effects on this track."))
        XCTAssertTrue(e.contains("Presets") && e.contains("+ effect"))
    }

    func testBypassMoveAndRemoveWriteTheChain() throws {
        let (editor, p) = try fixture()
        try press(p, .fxToggle("fx:8"))
        XCTAssertNotEqual(chain(editor).nodes[8].enabled, false, "On again")
        XCTAssertTrue(texts(draw(p)).filter { $0 == "On" }.count >= 2)
        try press(p, .fxToggle("fx:8"))
        XCTAssertEqual(chain(editor).nodes[8].enabled, false, "bypassed")
        try press(p, .button("fx:8:up"))
        XCTAssertEqual(chain(editor).nodes[7].type, "delay", "moved up one place")
        XCTAssertEqual(p.audioFxUI.openNode, 7, "the moved module opens")
        XCTAssertTrue(texts(draw(p)).contains(AudioFxCopy.effects["delay"]!.does))
        try press(p, .fxRemove("fx:7"))
        XCTAssertFalse(chain(editor).nodes.contains { $0.type == "delay" })
        XCTAssertTrue(editor.undo())
        XCTAssertTrue(chain(editor).nodes.contains { $0.type == "delay" }, "undoable")
    }

    func testPresetRunCollapseExpandSwitchAndRemove() throws {
        let (editor, p) = try fixture()
        let key = "voice-clean-3"
        XCTAssertTrue(p.audioFxUI.collapsedRuns.isEmpty || p.audioFxUI.collapsedRuns.contains(key))
        draw(p)
        XCTAssertTrue(p.audioFxUI.collapsedRuns.contains(key), "folded at mount")
        try press(p, .button("run:\(key):collapse"))
        let open = texts(draw(p))
        XCTAssertTrue(open.contains("▾"))
        for i in 3...7 { XCTAssertNotNil(p.hits.rect { $0 == .fxToggle("fx:\(i)") }, "module \(i) shows") }
        XCTAssertFalse(open.contains("5"), "the count shows only while folded")
        try press(p, .button("run:\(key):collapse"))
        draw(p)
        XCTAssertNil(p.hits.rect { $0 == .fxToggle("fx:3") })
        // On / Off is the preset amount (0 or 1) on every node of the run, not `enabled`.
        try press(p, .button("run:\(key):toggle"))
        XCTAssertEqual(chain(editor).nodes[3...7].map(\.presetAmount), Array(repeating: 0, count: 5))
        XCTAssertTrue(chain(editor).nodes[3...7].allSatisfy { $0.enabled != false })
        XCTAssertTrue(texts(draw(p)).contains("0.00"))
        try press(p, .button("run:\(key):toggle"))
        XCTAssertEqual(chain(editor).nodes[3...7].map { $0.presetAmount ?? 1 }, Array(repeating: 1, count: 5), "1 is the default amount")
        // The amount lane's slider sets a part-way amount.
        draw(p)
        let track = try XCTUnwrap(p.hits.rect { $0 == .slider("run:\(key):amount") })
        XCTAssertTrue(p.pointerDown(CanvasPoint(track.x + track.width / 2, track.midY)))
        p.pointerUp(CanvasPoint(track.x + track.width / 2, track.midY))
        let amount = try XCTUnwrap(chain(editor).nodes[3].presetAmount)
        XCTAssertEqual(amount, 0.5, accuracy: 0.06)
        try press(p, .reset("run:\(key):amount"))
        XCTAssertEqual(chain(editor).nodes[3].presetAmount ?? 1, 1)
        try press(p, .button("run:\(key):remove"))
        XCTAssertFalse(chain(editor).nodes.contains { $0.fromPreset == "voice-clean" })
        XCTAssertEqual(chain(editor).nodes.count, 4, "the EQ and the Echo stay")
    }

    func testPresetMenuShelvesAndPick() throws {
        let (editor, p) = try fixture()
        try press(p, .button("fx:presets"))
        let t = texts(draw(p))
        XCTAssertTrue(t.contains("Close"))
        XCTAssertTrue(t.contains("My voice sounds amateur"))
        XCTAssertTrue(t.contains("Clean Voice · \(AudioFxPresets.preset("voice-clean")!.nodes.count) effects"))
        XCTAssertTrue(t.joined().contains("CHARACTER"))
        for preset in AudioFxPresets.all { XCTAssertNotNil(p.hits.rect { $0 == .button("preset:\(preset.id)") }, preset.id) }
        try press(p, .button("preset:hall"))
        let c = chain(editor)
        XCTAssertTrue(c.nodes.contains { $0.fromPreset == "hall" })
        XCTAssertEqual(p.audioFxUI.menu, .none, "picking closes the shelf")
        let first = try XCTUnwrap(c.nodes.firstIndex { $0.fromPreset == "hall" })
        XCTAssertEqual(p.audioFxUI.openNode, first, "lands on the first node it wrote")
        XCTAssertFalse(p.audioFxUI.collapsedRuns.contains("hall-\(first)"), "a preset applied now arrives open")
        draw(p)
        XCTAssertNotNil(p.hits.rect { $0 == .fxToggle("fx:\(first)") })
        // "Close" closes it without picking.
        try press(p, .button("fx:presets")); try press(p, .button("fx:presets"))
        XCTAssertEqual(p.audioFxUI.menu, .none)
    }

    func testAddMenuAddsToneJobsAndEffects() throws {
        let (editor, p) = try fixture(nil)
        try press(p, .button("fx:add"))
        let t = texts(draw(p))
        for s in ["Tone", "Tame Boominess", "Remove Rumble", "Even Out Loudness", "Warmth", "Echo"] { XCTAssertTrue(t.contains(s), s) }
        XCTAssertNil(p.hits.rect { $0 == .button("add:peaking") }, "peaking is offered as its jobs")
        try press(p, .button("add:compressor"))
        let node = try XCTUnwrap(chain(editor).nodes.last)
        XCTAssertEqual(node.type, "compressor")
        XCTAssertEqual(AudioFxProfiles.strength("compressor", params: node.params!), 0.5, "seeded through its profile")
        XCTAssertEqual(p.audioFxUI.openNode, 0)
        XCTAssertTrue(texts(draw(p)).contains("Evenness"), "opens on its derived knob")
        try press(p, .button("fx:add")); try press(p, .button("job:add-clarity"))
        XCTAssertEqual(chain(editor).nodes.last?.label, "Add Clarity")
        try press(p, .button("fx:add")); try press(p, .button("eq:add"))
        XCTAssertEqual(AudioEq.ids(chain(editor)).count, 1)
        XCTAssertEqual(p.audioFxUI.openEq, AudioEq.ids(chain(editor)).first, "the new Tone opens on its faders")
    }

    func testEqModuleFadersAndReset() throws {
        let (editor, p) = try fixture()
        let eqId = try XCTUnwrap(AudioEq.ids(chain(editor)).first)
        try press(p, .button("eq:\(eqId):open"))
        let t = texts(draw(p))
        XCTAssertTrue(t.contains("+3"), "a moved band reads in the accent")
        XCTAssertTrue(t.joined().contains("CUT") && t.joined().contains("BOOST"))
        XCTAssertFalse(t.contains("Bass +3"), "open, the faders replace the summary")
        // Vertical travel: the top is +12 dB, the bottom -12.
        let mid = try XCTUnwrap(p.hits.rect { $0 == .slider("eq:Middle") })
        XCTAssertTrue(p.pointerDown(CanvasPoint(mid.midX, mid.y + 1)))
        _ = p.pointerMove(CanvasPoint(mid.midX, mid.y - 20))
        p.pointerUp(CanvasPoint(mid.midX, mid.y - 20))
        XCTAssertEqual(AudioEq.readBands(chain(editor), eqId: eqId).first { $0.name == "Middle" }?.gain, 12)
        draw(p)
        let treble = try XCTUnwrap(p.hits.rect { $0 == .slider("eq:Treble") })
        XCTAssertTrue(p.pointerDown(CanvasPoint(treble.midX, treble.y + treble.height * 0.75)))
        p.pointerUp(CanvasPoint(treble.midX, treble.y + treble.height * 0.75))
        XCTAssertEqual(AudioEq.readBands(chain(editor), eqId: eqId).first { $0.name == "Treble" }?.gain, -6)
        try press(p, .reset("eq:Bass"))
        XCTAssertEqual(AudioEq.readBands(chain(editor), eqId: eqId).first { $0.name == "Bass" }?.gain, 0)
        draw(p)
        XCTAssertNil(p.hits.rect { $0 == .reset("eq:Bass") }, "no reset at 0 dB")
        try press(p, .button("eq:\(eqId):remove"))
        XCTAssertTrue(AudioEq.ids(chain(editor)).isEmpty)
    }

    func testOpenModuleKnobsDetailsAndTyping() throws {
        let (editor, p) = try fixture()
        try press(p, .fxToggle("fx:8"))       // on, so its knobs are live
        try press(p, .button("fx:8:open"))
        let t = texts(draw(p))
        // Echo opens on its one knob (How loud = mix) and its two ends; the full set waits behind Details.
        XCTAssertNotNil(p.hits.rect { $0 == .slider("fx:8:mix") })
        XCTAssertNil(p.hits.rect { $0 == .slider("fx:8:time") })
        XCTAssertTrue(t.contains("How loud") && t.contains("A hint") && t.contains("Washed out"))
        try press(p, .button("fx:8:details"))
        draw(p)
        let time = try XCTUnwrap(p.hits.rect { $0 == .slider("fx:8:time") })
        XCTAssertTrue(p.pointerDown(CanvasPoint(time.maxX - 1, time.midY))); p.pointerUp(CanvasPoint(time.maxX - 1, time.midY))
        XCTAssertGreaterThan(chain(editor).nodes[8].params!.num("time"), 3000, "log travel reaches the top of the range")
        // The number field types a value.
        try press(p, .field("fx:8:feedback"))
        XCTAssertTrue(p.isEditingText)
        for _ in 0..<6 { _ = p.keyDown(EditorKey(.backspace)) }
        for ch in "0.6" { _ = p.keyDown(EditorKey(.char(ch))) }
        _ = p.keyDown(EditorKey(.enter))
        XCTAssertEqual(chain(editor).nodes[8].params!.num("feedback"), 0.6, accuracy: 1e-9)
        try press(p, .reset("fx:8:feedback"))
        XCTAssertEqual(chain(editor).nodes[8].params!.num("feedback"), 0.35, accuracy: 1e-9)
        // Bypassed, its knobs are locked.
        try press(p, .fxToggle("fx:8"))
        draw(p)
        XCTAssertNil(p.hits.rect { $0 == .slider("fx:8:time") })
    }

    func testBusRackAndScriptedControls() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        let gid = try XCTUnwrap(editor.createAudioGroup(clipIds: ["clip:a", "clip:b"], label: "Bus"))
        let p = InspectorPanel(); p.editor = editor; p.selection = []; p.audioGroupId = gid; p.openGroupId = "audio-fx"
        XCTAssertTrue(texts(draw(p)).contains("No effects on this group."))
        // Every shelf pick and module control stays reachable by key (the smoke stress drives the rack this way).
        let rows = p.groups.flatMap(\.addressableRows)
        func button(_ k: String) -> InspectorRow.Button? {
            for r in rows { if case .buttons(let bs) = r.kind, let b = bs.first(where: { $0.key == k }) { return b } }
            return nil
        }
        try XCTUnwrap(button("preset:voice-clean")).action()
        XCTAssertTrue(try XCTUnwrap(editor.audioGroup(gid)?.fxChain).contains("voice-clean"))
        let after = p.groups.flatMap(\.addressableRows)
        XCTAssertTrue(after.contains { if case .fxNode(let n) = $0.kind { return n.key == "fx:0" }; return false }, "folded modules keep their controls")
    }
}

#if os(Linux)   // Cairo pixels
final class AudioFxRackSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func render(_ p: InspectorPanel, _ name: String, scale: Double) -> CairoImageTarget {
        let w = AudioFxRackTests.width, h = 900.0
        let t = CairoImageTarget(width: Int(w * scale), height: Int(h * scale))
        t.canvas.scale(scale, scale)
        p.draw(t.canvas, in: CanvasRect(x: 0, y: 0, width: w, height: h))
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name)-\(Int(scale))x.png"), 0)
        }
        return t
    }
    func px(_ t: CairoImageTarget, _ x: Double, _ y: Double, _ scale: Double) -> String {
        let p = t.pixel(Int(x * scale), Int(y * scale)); return String(format: "#%02x%02x%02x", Int(p.r), Int(p.g), Int(p.b))
    }
    func near(_ a: String, _ b: String, tol: Int = 6) -> Bool {
        let x = CanvasColor(hex: a)!, y = CanvasColor(hex: b)!
        return abs(x.r - y.r) * 255 <= Double(tol) && abs(x.g - y.g) * 255 <= Double(tol) && abs(x.b - y.b) * 255 <= Double(tol)
    }

    /// The reference render (audiofx-rack-1x.png): colours at geometry located through the rack's own hits.
    func testRackPixelsDarkAndLight() throws {
        for scale in [1.0, 2.0] {
            let (editor, p) = try AudioFxRackTests.makeFixture()
            let t = render(p, "audiofx-rack", scale: scale)
            let eqId = AudioEq.ids((try? AudioFx.parseChain(editor.clip("clip:music")!.clip.audioFxChain!)) ?? FxChain()).first!
            let tone = try XCTUnwrap(p.hits.rect { $0 == .button("eq:\(eqId):open") })
            let x0 = tone.x - 8   // the rack's left edge
            let run = try XCTUnwrap(p.hits.rect { $0 == .button("run:voice-clean-3:collapse") })
            let echo = try XCTUnwrap(p.hits.rect { $0 == .fxToggle("fx:8") })
            let presets = try XCTUnwrap(p.hits.rect { $0 == .button("fx:presets") })
            let checks: [(String, Double, Double, String)] = [
                ("Tone edge (smart tint)", x0 + 0.5, tone.midY, "#99bd7f"),
                ("Tone body", x0 + 60, tone.maxY + 8, "#191919"),
                ("Clean Voice edge", x0 + 0.5, run.midY, "#61bbef"),
                ("Clean Voice wash", x0 + 4, run.midY, "#161e22"),
                ("Echo edge, bypassed", x0 + 0.5, echo.midY, "#57736c"),
                ("Presets border", presets.midX, presets.y + 0.5, "#fafafa"),
                ("Presets inside", presets.midX - 60, presets.midY, "#191919"),
            ]
            for (what, x, y, want) in checks { XCTAssertTrue(near(px(t, x, y, scale), want), "\(what) @\(scale)x: \(px(t, x, y, scale)) want \(want)") }
            let amount = try XCTUnwrap(p.hits.rect { $0 == .slider("run:voice-clean-3:amount") })
            XCTAssertTrue(near(px(t, amount.x + 20, amount.midY, scale), "#4c8df0", tol: 10), "amount fill")
            // EQ open: the fader fill runs up from 0 dB in the accent.
            p.audioFxUI.openEq = eqId
            let t2 = render(p, "audiofx-eq-open", scale: scale)
            let bass = try XCTUnwrap(p.hits.rect { $0 == .slider("eq:Bass") })
            XCTAssertTrue(near(px(t2, bass.midX, bass.midY - 4, scale), "#4c8df0", tol: 12), "Bass +3 fill above the detent")
            XCTAssertFalse(near(px(t2, bass.midX, bass.midY + 6, scale), "#4c8df0", tol: 40), "nothing below it")
        }
        // Light: the same rack in the light palette, every hue darkened to hold 3:1 and the washes near-white.
        Theme.setMode(.light)
        let (_, p) = try AudioFxRackTests.makeFixture()
        let t = render(p, "audiofx-rack-light", scale: 1)
        let run = try XCTUnwrap(p.hits.rect { $0 == .button("run:voice-clean-3:collapse") })
        let wash = CanvasColor(ThemeTokens.fxPresetWashPair("voice-clean")!.light)
        let x0 = try XCTUnwrap(p.hits.rect { if case .button(let k) = $0 { return k.hasSuffix(":open") && k.hasPrefix("eq:") }; return false }).x - 8
        XCTAssertTrue(near(px(t, x0 + 4, run.midY, 1), String(format: "#%02x%02x%02x", Int(wash.r * 255 + 0.5), Int(wash.g * 255 + 0.5), Int(wash.b * 255 + 0.5))))
        XCTAssertFalse(near(px(t, x0 + 4, run.midY, 1), "#161e22", tol: 40))
    }
}
#endif

/// The rack's hues are theme pairs: dark exactly the recorded hsl() values, light readable on the light panels.
final class AudioFxRackTokenTests: XCTestCase {
    func hex(_ c: ThemeColor) -> String { String(format: "#%02x%02x%02x", Int(c.r * 255 + 0.5), Int(c.g * 255 + 0.5), Int(c.b * 255 + 0.5)) }

    func testDarkValuesAreTheStudiosAndLightValuesHoldContrast() {
        XCTAssertEqual(hex(ThemeTokens.fxPresetEdgePair("voice-clean").dark), "#61bbef")
        XCTAssertEqual(hex(ThemeTokens.fxPresetWashPair("voice-clean")!.dark), "#161e22")
        XCTAssertEqual(hex(ThemeTokens.fxFamilyTintPair("smart", step: 0).dark), "#99bd7f")
        XCTAssertNil(ThemeTokens.fxPresetWashPair("no-such-preset"))
        let inset = ThemeTokens.panelBgInsetPair.light
        for id in AudioFxPresets.all.map(\.id) {
            XCTAssertNotNil(ThemeTokens.fxPresetHues[id], "\(id) has a hue")
            let edge = ThemeTokens.fxPresetEdgePair(id)
            XCTAssertGreaterThanOrEqual(edge.light.contrast(inset), 3, "\(id) edge on the light panel")
            let wash = ThemeTokens.fxPresetWashPair(id)!
            XCTAssertGreaterThanOrEqual(ThemeTokens.textPairs[1].light.contrast(wash.light), 4.5, "\(id) label on its light wash")
            XCTAssertGreaterThanOrEqual(ThemeTokens.textPairs[1].dark.contrast(wash.dark), 4.5, "\(id) label on its dark wash")
        }
        for fam in ["filter", "dynamics", "nonlinear", "time", "smart"] {
            for step in [0.0, 0.5, 1.0] {
                XCTAssertGreaterThanOrEqual(ThemeTokens.fxFamilyTintPair(fam, step: step).light.contrast(inset), 3, "\(fam) \(step)")
            }
        }
    }
}

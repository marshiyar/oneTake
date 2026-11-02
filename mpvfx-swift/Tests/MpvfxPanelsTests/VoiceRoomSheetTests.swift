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
import XCTest
import MpvfxCanvas
import MpvfxAudioGraph
import MpvfxShared
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Make room for voice sheet (issue #310): which clips it names, and that it works from the keyboard without touching the
/// document until Make room runs.
final class VoiceRoomSheetTests: XCTestCase {
    func fixture(selection: [String] = ["clip:a"]) throws -> (TimelineEditor, InspectorPanel) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let p = InspectorPanel(); p.editor = editor; p.selection = selection; p.openGroupId = "audio-fx"
        return (editor, p)
    }
    func draw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 4000)) }

    func testA2BedsPreCheckMusicAndAmbienceAndNeverListAVoice() throws {
        let (editor, _) = try fixture()
        var doc = editor.document
        let picked = VoiceRoomSheet.open(doc, selection: ["clip:a"])
        XCTAssertEqual(picked.voices.map(\.clipId), ["clip:a"])
        XCTAssertEqual(picked.beds.map(\.clip.clipId).sorted(), ["clip:b", "clip:music"])
        XCTAssertEqual(picked.beds.filter(\.checked).map(\.clip.clipId), ["clip:music"], "music is ticked, an unnamed clip is not")
        XCTAssertNil(VoiceRoomSheet.open(doc, selection: []).run, "nothing reads as voice, so nothing runs")
        // With nothing selected the clips that read as voice are the voice, and a voice is never a bed.
        doc.assets[3].name = "Voice-over 1.wav"
        let found = VoiceRoomSheet.open(doc, selection: [])
        XCTAssertEqual(found.voices.map(\.clipId), ["clip:music"])
        XCTAssertFalse(found.beds.contains { $0.clip.clipId == "clip:music" })
        XCTAssertFalse(VoiceRoomSheet.open(doc, selection: ["clip:a"]).beds.contains { $0.clip.kind == .voice })
        // A track the editor cannot write to is not offered.
        doc.sequence.tracks[2].locked = true
        XCTAssertTrue(VoiceRoomSheet.open(doc, selection: ["clip:a"]).beds.isEmpty)
    }

    func testA1EveryFieldIsReachableByTabAndEnterRunsEscCancelsWithoutTouchingTheDocument() throws {
        let (editor, p) = try fixture()
        let before = editor.document
        var runs: [VoiceRoomSheet.Run] = []
        p.onMakeRoomForVoice = { runs.append($0) }
        p.openVoiceRoomSheet()
        draw(p)
        var reached = Set<String>()
        for _ in 0..<40 {
            _ = p.keyDown(EditorKey(.tab)); draw(p)
            if let current = p.focus.current { reached.insert("\(current)") }
        }
        for key in ["vr:amount", "vr:attack", "vr:release", "vr:hold", "vr:mode", "vr:bed:0", "vr:bed:1", "vr:run", "vr:cancel"] {
            XCTAssertTrue(reached.contains { $0.contains(key) }, "Tab reaches \(key); reached \(reached.sorted())")
        }
        // Esc: closed, no run, no change, nothing to undo.
        XCTAssertTrue(p.keyDown(EditorKey(.escape)))
        XCTAssertNil(p.voiceRoom)
        XCTAssertTrue(runs.isEmpty)
        XCTAssertEqual(editor.document, before)
        XCTAssertNil(editor.undoLabel)
        // Enter: one run with the default settings over the ticked bed; still no document change (the host writes).
        p.focus.visible = false
        p.openVoiceRoomSheet()
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(runs, [.init(mode: .volume, settings: VoiceRoomSettings(), voiceClipIds: ["clip:a"], bedClipIds: ["clip:music"])])
        XCTAssertNil(p.voiceRoom)
        XCTAssertEqual(editor.document, before)
        p.rerunVoiceRoom()
        XCTAssertEqual(runs.count, 2); XCTAssertEqual(runs[1], runs[0], "Re-run repeats the last run")
    }

    func testFieldsKeepTheirRangeAndSaySoWhenAValueIsRejected() throws {
        let (_, p) = try fixture()
        p.openVoiceRoomSheet()
        func commit(_ key: String, _ text: String) throws {
            let rows = try XCTUnwrap(p.groups.first { $0.id == "voice-room" }).addressableRows
            for row in rows { if case .number(let n) = row.kind, n.key == key { n.commit(text); return } }
            XCTFail("no field \(key)")
        }
        try commit("vr:amount", "-20")
        XCTAssertEqual(p.voiceRoom?.settings.amountDb, -20)
        try commit("vr:amount", "-80")
        XCTAssertEqual(p.voiceRoom?.settings.amountDb, -20, "a value out of range is not clamped into place")
        XCTAssertEqual(p.voiceRoom?.error, "Amount must be between -60 and 0 dB.")
        try commit("vr:hold", "250")
        XCTAssertEqual(p.voiceRoom?.settings.holdMs, 250)
        XCTAssertNil(p.voiceRoom?.error)
        p.voiceRoom?.beds[0].checked = false; p.voiceRoom?.beds[1].checked = false
        p.runVoiceRoom()
        XCTAssertNotNil(p.voiceRoom, "with nothing ticked the sheet stays open")
        XCTAssertEqual(p.voiceRoom?.error, "Tick at least one clip to lower.")
    }

    func testTheEditorWritesBothKindsOfEditAsOneUndoStep() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let chain = #"{"version":2,"nodes":[]}"#
        let automation = #"{"version":1,"lanes":[{"target":"volume","points":[{"t":0,"v":1,"origin":"voice-room"},{"t":1,"v":0.25,"origin":"voice-room"}]}]}"#
        XCTAssertTrue(editor.setClipsAudio(automation: ["clip:music": automation], fxChains: ["clip:music": chain], label: "Make room for voice"))
        let clip = try XCTUnwrap(editor.clip("clip:music")?.clip)
        XCTAssertEqual(clip.audioAutomation, automation); XCTAssertEqual(clip.audioFxChain, chain)
        XCTAssertEqual(editor.undoLabel, "Make room for voice")
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clip("clip:music")?.clip.audioAutomation)
        XCTAssertNil(editor.clip("clip:music")?.clip.audioFxChain)
        XCTAssertFalse(editor.setClipsAudio(automation: ["clip:logo": automation], fxChains: [:], label: "x"), "an image clip has no sound")
        XCTAssertTrue(editor.setClipsAudio(automation: ["clip:music": automation], fxChains: [:], label: "Make room for voice"))
        XCTAssertTrue(editor.setClipsAudio(automation: ["clip:music": nil], fxChains: [:], label: "Make room for voice"))
        XCTAssertNil(editor.clip("clip:music")?.clip.audioAutomation, "nil removes it")
    }
}

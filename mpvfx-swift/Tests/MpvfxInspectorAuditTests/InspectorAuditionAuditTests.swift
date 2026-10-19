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
import XCTest
import Foundation
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import MpvfxTimeline
import MpvfxAudio
import MpvfxAudioGraph
import MpvfxPanels
@testable import MpvfxPlayer
@testable import MpvfxRuntime

/// Audio FX › audition: hovering a preset or an effect on the open shelf
/// plays the chain it would make through the live graph, without writing it; leaving, pressing or the shelf going
/// away puts the stored chain back. The document, its undo history and export never see the audition.
extension InspectorRenderAuditTests {
    func drawRack() { inspector.draw(AuditCanvas(), in: CanvasRect(x: 0, y: 0, width: 320, height: 6000)) }

    /// Selects the audio clip, opens Audio FX and the given shelf ("fx:presets" / "fx:add"), and records auditions.
    func openShelf(_ shelf: String) -> AuditionLog {
        select("M")
        inspector.openGroupId = "audio-fx"
        let log = AuditionLog()
        inspector.onAudition = { log.requests.append($0) }
        press(shelf)
        drawRack()
        return log
    }

    func hover(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        drawRack()
        guard let r = inspector.hits.rect(where: { $0 == .button(key) }) else { return XCTFail("\(key) is not drawn", file: file, line: line) }
        _ = inspector.pointerMove(CanvasPoint(r.x + r.width / 2, r.y + r.height / 2))
    }

    func chainOfM(_ doc: NativeProjectDocument) -> String? {
        doc.sequence.tracks.flatMap(\.clips).first { $0.id == "M" }?.audioFxChain
    }

    func liveTrackM(_ doc: NativeProjectDocument) -> DocumentAudioGraph.Inputs.Track? {
        DocumentAudioGraph.inputs(doc, duration: editor.duration, projectDir: URL(fileURLWithPath: projectDir), fileExists: { _ in true })
            .tracks.first { $0.id == "M" }
    }

    var firstPreset: FxPreset { AudioFxPresets.families.lazy.flatMap { AudioFxPresets.byFamily($0) }.first! }

    func testHoveringAPresetAuditionsItsChainWithoutWritingIt() throws {
        let log = openShelf("fx:presets")
        let before = editor.document, undo = editor.undoStack.count, export = exportRender()
        let p = firstPreset
        hover("preset:\(p.id)")
        XCTAssertEqual(inspector.auditionKey, "preset:\(p.id)")
        let req = try XCTUnwrap(log.requests.last ?? nil, "hover starts an audition")
        XCTAssertEqual(chainOfM(req.document), AudioFx.serializeChain(AudioFxPresets.apply(FxChain(), p)), "the hovered preset's chain on the clip")
        XCTAssertNotNil(liveTrackM(req.document)?.fxChain, "the live graph built from the audition plays the chain")
        XCTAssertEqual(req.spans.count, 1)
        XCTAssertEqual(req.spans[0].lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(editor.document, before, "the open document is untouched")
        XCTAssertEqual(editor.undoStack.count, undo, "no undo entry")
        XCTAssertNil(chainOfM(editor.document))
        XCTAssertEqual(exportRender(), export, "export renders the stored chain")
        XCTAssertFalse(exportNeedsAudioGraph(editor.document), "export still mixes without the FX graph")
    }

    func testAddShelfJobsAndEffectsAuditionTheirEffect() throws {
        let log = openShelf("fx:add")
        let job = try XCTUnwrap(AudioFxJobs.all.first)
        hover("job:\(job.id)")
        let jobReq = try XCTUnwrap(log.requests.last ?? nil)
        XCTAssertEqual(chainOfM(jobReq.document), AudioFx.serializeChain(FxChain(nodes: [AudioFxJobs.node(job, joining: FxChain())])))
        let effect = try XCTUnwrap(AudioFx.definitions.first { !AudioFxJobs.types.contains($0.id) })
        hover("add:\(effect.id)")
        XCTAssertEqual(inspector.auditionKey, "add:\(effect.id)", "moving to another item switches the audition")
        let fxReq = try XCTUnwrap(log.requests.last ?? nil)
        XCTAssertEqual(chainOfM(fxReq.document), AudioFx.serializeChain(FxChain(nodes: [AudioFxJobs.effectNode(effect.id, joining: FxChain())])))
        hover("eq:add")
        XCTAssertNil(inspector.auditionKey, "Tone arrives flat: nothing to audition")
        XCTAssertNil(log.requests.last ?? nil)
        XCTAssertNil(chainOfM(editor.document))
    }

    func testLeavingTheItemEndsTheAudition() throws {
        let log = openShelf("fx:presets")
        hover("preset:\(firstPreset.id)")
        _ = inspector.pointerMove(CanvasPoint(-50, -50))   // off the panel
        XCTAssertNil(inspector.auditionKey)
        XCTAssertEqual(log.requests.count, 2)
        XCTAssertNil(log.requests.last ?? nil, "the live graph goes back to the open document")
        XCTAssertNil(chainOfM(editor.document))
    }

    func testPressingAPresetEndsTheAuditionThenCommitsTheStoredChainOnce() throws {
        let log = openShelf("fx:presets")
        let p = firstPreset
        hover("preset:\(p.id)")
        let undo = editor.undoStack.count
        drawRack()
        let r = try XCTUnwrap(inspector.hits.rect(where: { $0 == .button("preset:\(p.id)") }))
        let pt = CanvasPoint(r.x + r.width / 2, r.y + r.height / 2)
        _ = inspector.pointerDown(pt); inspector.pointerUp(pt)
        XCTAssertNil(inspector.auditionKey)
        XCTAssertNil(log.requests.last ?? nil, "the press ends the audition")
        XCTAssertEqual(chainOfM(editor.document), AudioFx.serializeChain(AudioFxPresets.apply(FxChain(), p)),
                       "the pick lands on the stored chain, not on top of the audition")
        XCTAssertEqual(editor.undoStack.count, undo + 1, "the pick is the one undo step")
        editor.undo()
        XCTAssertNil(chainOfM(editor.document))
    }

    func testTheShelfGoingAwayEndsTheAudition() throws {
        let log = openShelf("fx:presets")
        hover("preset:\(firstPreset.id)")
        inspector.audioFxUI.menu = .none
        drawRack()
        XCTAssertNil(inspector.auditionKey, "closing the shelf ends it")
        XCTAssertNil(log.requests.last ?? nil)

        press("fx:presets"); hover("preset:\(firstPreset.id)")
        XCTAssertNotNil(inspector.auditionKey)
        select("V")   // the rack's owner goes away
        drawRack()
        XCTAssertNil(inspector.auditionKey, "deselecting ends it")
        XCTAssertNil(log.requests.last ?? nil)
    }

    func testAuditionStartsAPausedTransportAndPutsItBack() throws {
        let log = openShelf("fx:presets")
        let playback = PlaybackState(duration: 10)   // a longer composition than the clip, so the playhead can sit past it
        let audition = AuditionPlayback()
        var live: [NativeProjectDocument] = []
        inspector.onAudition = { req in
            log.requests.append(req)
            audition.apply(req, playback: playback) { live.append(audition.document ?? self.editor.document) }
        }
        playback.seek(4)   // past the clip (0..3 s at 10 fps): the audition jumps to where the chain is heard
        XCTAssertEqual(playback.currentTime, 4, accuracy: 1e-9)
        hover("preset:\(firstPreset.id)")
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 1e-9)
        XCTAssertNotNil(chainOfM(try XCTUnwrap(live.last)), "the graph had the audition before the transport ran")
        _ = inspector.pointerMove(CanvasPoint(-50, -50))
        XCTAssertFalse(playback.isPlaying, "leaving stops the transport it started")
        XCTAssertEqual(playback.currentTime, 4, accuracy: 1e-9, "and seeks back to where the author was")
        XCTAssertNil(chainOfM(try XCTUnwrap(live.last)), "the graph plays the open document again")
        XCTAssertFalse(audition.isActive)
        XCTAssertNil(chainOfM(editor.document))
    }

    func testAnAuditionLeavesARunningTransportAlone() throws {
        let playback = PlaybackState(duration: 10)
        playback.seek(0.5); playback.play()
        let audition = AuditionPlayback()
        var rebuilt = 0
        let doc = editor.document
        XCTAssertFalse(audition.apply(AuditionRequest(document: doc, spans: [3...4]), playback: playback) { rebuilt += 1 })
        XCTAssertTrue(playback.isPlaying); XCTAssertEqual(playback.currentTime, 0.5, accuracy: 1e-9)
        audition.apply(nil, playback: playback) { rebuilt += 1 }
        XCTAssertTrue(playback.isPlaying, "the author's playback keeps running")
        XCTAssertEqual(rebuilt, 2)
        XCTAssertEqual(AuditionTransport.start([1...2, 5...6], at: 1.5), 1.5, "inside a span: stay")
        XCTAssertEqual(AuditionTransport.start([1...2, 5...6], at: 3), 5, "between: the next span")
        XCTAssertEqual(AuditionTransport.start([1...2, 5...6], at: 7), 1, "past them all: the first")
        XCTAssertNil(AuditionTransport.start([], at: 0))
    }
}

final class AuditionLog { var requests: [AuditionRequest?] = [] }

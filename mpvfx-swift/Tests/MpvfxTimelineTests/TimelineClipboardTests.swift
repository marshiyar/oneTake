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
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
@testable import MpvfxTimeline

/// Copy/paste of clips (TimelineEditor+Clipboard): effects and keyframes travel with the clip, onto other tracks and
/// into other projects; the clip menu's clipboard and pitch rows.
final class TimelineClipboardTests: XCTestCase {
    static let engine = try? KeyframeRuntime()
    // @30fps, display order v2, v1, a1. clip:a carries an effect, a rotation track, an audio group and a binding.
    static func json(id: String = "project:clip", fps: Int = 30, groups: String = #"[{"id":"dialogue","label":"Dialogue","volume":1,"muted":false}]"#) -> String {
        #"""
        {"schemaVersion":1,"id":"\#(id)","revision":1,"frameRate":{"numerator":\#(fps),"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#111111"},
         "assets":[{"id":"asset:a","kind":"video","name":"a.mp4","source":"media/a.mp4","durationFrames":600},
                   {"id":"asset:m","kind":"audio","name":"vo.wav","source":"media/vo.wav","durationFrames":900}],
         "sequence":{"id":"sequence:main","name":"Main","audioGroups":\#(groups),"tracks":[
          {"id":"track:v2","kind":"video","lane":{"authoredTrack":2,"displayTrack":0},"clips":[]},
          {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":1},"clips":[
           {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,"audioGroupId":"dialogue",
            "binding":{"sourceFile":"index.html","domId":"a","hfId":"hf-a"},
            "effects":[{"id":"fx:grade","effectId":"color-grade","enabled":true,"parameters":{}}],
            "parameterTracks":[{"schemaVersion":1,"id":"parameter:a:rotation","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":\#(fps),"denominator":1},
              "keyframes":[{"id":"r0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"r1","frame":60,"value":180,"outgoing":{"type":"hold"}}]}]}]},
          {"id":"track:a1","kind":"audio","lane":{"authoredTrack":3,"displayTrack":2},"clips":[
           {"id":"clip:m","assetId":"asset:m","startFrame":30,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#
    }

    func make(_ json: String = json(), dir: String = "/projects/one") throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: json, engine: Self.engine)
        e.projectDirectory = URL(fileURLWithPath: dir)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1200, 600)
        return (c, e)
    }
    func clip(_ e: TimelineEditor, _ id: String) -> NativeProjectClip? { e.document.sequence.tracks.flatMap(\.clips).first { $0.id == id } }
    func trackId(_ e: TimelineEditor, _ id: String) -> String? { e.address(clipId: id)?.trackId }
    func labels(_ m: TimelineClipMenu?) -> [String] {
        (m?.entries ?? []).map { e -> String in if case .item(let i) = e { return i.label }; return "—" }
    }

    func testPasteOntoAnotherTrackKeepsEffectsAndKeyframes() throws {
        let (_, e) = try make()
        let source = try XCTUnwrap(clip(e, "clip:a"))
        let board = try XCTUnwrap(e.copyClips(["clip:a"]))
        let before = e.document
        let ids = e.paste(board, at: 4, onto: "track:v2")
        let id = try XCTUnwrap(ids.first)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(id, "clip:a-copy")
        XCTAssertEqual(trackId(e, id), "track:v2")
        let pasted = try XCTUnwrap(clip(e, id))
        XCTAssertEqual(pasted.startFrame, 120)
        XCTAssertEqual(pasted.effects, source.effects)
        XCTAssertEqual(pasted.parameterTracks, source.parameterTracks, "clip-local keyframes are kept as they are")
        XCTAssertEqual(pasted.audioGroupId, "dialogue")
        XCTAssertNil(pasted.binding, "bindings are unique, the copy has none")
        XCTAssertEqual(pasted.assetId, "asset:a", "same project: same asset")
        XCTAssertEqual(e.document.assets.count, 2)
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Paste")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
    }

    func testRowsKeepTheirDistanceAndKindsFindTheirTrack() throws {
        let (_, e) = try make()
        let board = try XCTUnwrap(e.copyClips(["clip:a", "clip:m"]))
        XCTAssertEqual(board.items.map(\.trackRow), [1, 2])
        // Nothing chosen: back onto the tracks they came from, offsets kept.
        let back = e.paste(board, at: 10)
        XCTAssertEqual(back.map { trackId(e, $0) }, ["track:v1", "track:a1"])
        XCTAssertEqual(back.compactMap { clip(e, $0)?.startFrame }, [300, 330])
        // Onto v2: a lands there; the audio clip's row (v1) is a video track, so it takes the next audio track below.
        let moved = e.paste(board, at: 20, onto: "track:v2")
        XCTAssertEqual(moved.map { trackId(e, $0) }, ["track:v2", "track:a1"])
        XCTAssertEqual(moved, ["clip:a-copy2", "clip:m-copy2"])
    }

    func testPasteMakesATrackWhenNoneOfTheKindIsLeft() throws {
        let (_, e) = try make()
        let board = try XCTUnwrap(e.copyClips(["clip:a", "clip:m"]))
        let before = e.document.sequence.tracks.count
        let ids = e.paste(board, at: 0, onto: "track:a1")   // a onto a1's row: no video track at or below it
        XCTAssertEqual(ids.count, 2)
        let videoTrack = try XCTUnwrap(trackId(e, ids[0]))
        XCTAssertEqual(e.document.sequence.tracks.first { $0.id == videoTrack }?.kind, .video)
        XCTAssertEqual(e.document.sequence.tracks.count, before + 2, "the audio clip below it needs its own new track as well")
        XCTAssertEqual(e.displayTrackIds.suffix(2), [videoTrack, trackId(e, ids[1])!], "new tracks go to the bottom")
        XCTAssertEqual(e.undoStack.count, 1, "tracks and clips in one undo step")
    }

    func testLockedDestinationRefusesThePaste() throws {
        let (_, e) = try make()
        let board = try XCTUnwrap(e.copyClips(["clip:a"]))
        XCTAssertTrue(e.setTrackLocked("track:v2", true))
        let before = e.document
        XCTAssertEqual(e.paste(board, at: 0, onto: "track:v2"), [])
        XCTAssertEqual(e.lastFailure?.message, "Track is locked")
        XCTAssertEqual(e.document, before)
        XCTAssertEqual(e.paste(board, at: 0, onto: "track:none"), [])
        XCTAssertEqual(e.lastFailure?.message, "Track track:none was not found")
    }

    func testPasteIntoAnotherProjectBringsItsMedia() throws {
        let (_, one) = try make()
        let board = try XCTUnwrap(one.copyClips(["clip:a", "clip:m"]))
        XCTAssertEqual(board.assets.compactMap(\.source), ["/projects/one/media/a.mp4", "/projects/one/media/vo.wav"])
        // Project two already plays a.mp4 (by absolute path), has its own asset:m (another file) and no audio groups.
        var other = try TimelineEditor(json: Self.json(id: "project:two", groups: "[]").replacingOccurrences(of: #""audioGroupId":"dialogue","#, with: ""),
                                   engine: Self.engine).document
        other.assets[0].source = "/projects/one/media/a.mp4"
        other.assets[0].id = "asset:mine"
        for t in other.sequence.tracks.indices { for i in other.sequence.tracks[t].clips.indices where other.sequence.tracks[t].clips[i].assetId == "asset:a" {
            other.sequence.tracks[t].clips[i].assetId = "asset:mine" } }
        let two = TimelineEditor(document: try parseNativeProjectDocument(other, engine: Self.engine), engine: Self.engine)
        two.projectDirectory = URL(fileURLWithPath: "/projects/two")
        let ids = two.paste(board, at: 2)
        XCTAssertEqual(ids.count, 2, two.lastFailure?.message ?? "")
        XCTAssertEqual(ids.map { trackId(two, $0) }, ["track:v2", "track:a1"], "the first video track, then the next audio track below")
        let a = try XCTUnwrap(clip(two, ids[0])), m = try XCTUnwrap(clip(two, ids[1]))
        XCTAssertEqual(a.assetId, "asset:mine", "the asset playing the same file is reused")
        XCTAssertNil(a.audioGroupId, "project two has no Dialogue bus")
        XCTAssertEqual(a.effects.map(\.effectId), ["color-grade"])
        XCTAssertEqual(a.parameterTracks.first?.keyframes.map(\.value), [.number(0), .number(180)])
        XCTAssertEqual(m.assetId, "asset:m-copy", "its asset:m plays media/vo.wav of project two, so vo.wav comes as a new asset")
        let added = try XCTUnwrap(two.document.assets.first { $0.id == m.assetId })
        XCTAssertEqual(added.source, "/projects/one/media/vo.wav")
        XCTAssertEqual(added.kind, .audio)
    }

    func testAnotherFrameRateIsRefused() throws {
        let (_, one) = try make()
        let board = try XCTUnwrap(one.copyClips(["clip:a"]))
        let (_, other) = try make(Self.json(id: "project:25", fps: 25))
        XCTAssertEqual(other.paste(board, at: 0), [])
        XCTAssertEqual(other.lastFailure?.message, "These clips were copied from a project at another frame rate and cannot be pasted here")
    }

    func testDetachedAudioLinkFollowsItsVideoOnly() throws {
        let (_, e) = try make()
        XCTAssertTrue(e.detachAudio(clipId: "clip:a"))
        let audio = try XCTUnwrap(e.document.sequence.tracks.flatMap(\.clips).first { $0.audioDetachedFrom == "clip:a" })
        let both = e.paste(try XCTUnwrap(e.copyClips(["clip:a", audio.id])), at: 20)
        XCTAssertEqual(both.count, 2)
        let pastedAudio = try XCTUnwrap(both.compactMap { clip(e, $0) }.first { $0.audioDetachedFrom != nil })
        XCTAssertEqual(pastedAudio.audioDetachedFrom, both.first { $0.hasPrefix("clip:a") }, "links to the pasted video")
        let alone = try XCTUnwrap(e.paste(try XCTUnwrap(e.copyClips([audio.id])), at: 40).first)
        XCTAssertNil(clip(e, alone)?.audioDetachedFrom, "a copy pasted alone is a plain audio clip")
        XCTAssertTrue(e.reattachAudio(clipId: audio.id), e.lastFailure?.message ?? "the original link is still unambiguous")
    }

    func testCommandVPastesOntoTheSelectedClipsTrackAndSurvivesAProjectSwitch() throws {
        let (c, e) = try make()
        c.view.selection = ["clip:m"]
        XCTAssertTrue(c.keyDown(EditorKey(.char("c"), meta: true)))
        c.view.selection = ["clip:a"]
        c.playback.seek(3)
        XCTAssertTrue(c.keyDown(EditorKey(.char("v"), meta: true)))
        let pasted = try XCTUnwrap(c.view.selection.first)
        XCTAssertEqual(trackId(e, pasted), "track:a1", "the selected clip's track is a video track, so the next audio one")
        XCTAssertEqual(clip(e, pasted)?.startFrame, 90)
        // The clipboard is the controller's, so it outlives the document.
        e.loadDocument(try TimelineEditor(json: Self.json(id: "project:other"), engine: Self.engine).document)
        c.view.selection = []
        XCTAssertTrue(c.pasteClipboard())
        XCTAssertEqual(c.view.selection.compactMap { trackId(e, $0) }, ["track:a1"])
    }

    func testClipMenuClipboardEntries() throws {
        let (c, e) = try make()
        c.openClipMenu("clip:a", x: 10, y: 10)
        XCTAssertEqual(labels(c.view.clipMenu), ["Split", "—", "Cut", "Copy", "Paste", "Duplicate", "—", "Show thumbnails", "—",
                                                 "Mute", "Keep audio pitch", "—", "Detach audio", "—", "Delete"])
        func item(_ a: TimelineClipMenu.Action) -> TimelineClipMenu.Item? {
            c.view.clipMenu?.itemRects().map(\.0).first { $0.action == a }
        }
        XCTAssertEqual(item(.paste)?.enabled, false, "nothing copied yet")
        XCTAssertEqual(item(.keepPitch)?.checked, true)
        XCTAssertEqual(item(.copy)?.hint, "⌘C")
        XCTAssertTrue(c.runClipMenu(.copy, clipId: "clip:a"))
        XCTAssertEqual(c.clipboard?.items.map(\.clip.id), ["clip:a"])
        c.openClipMenu("clip:a", x: 10, y: 10)
        XCTAssertEqual(item(.paste)?.enabled, true)
        c.playback.seek(5)   // seeking stops at the sequence end (6 s)
        c.view.selection = []
        XCTAssertTrue(c.runClipMenu(.paste, clipId: "clip:a"))
        let pasted = try XCTUnwrap(c.view.selection.first)
        XCTAssertEqual(trackId(e, pasted), "track:v1", "the menu pastes onto its clip's track")
        XCTAssertEqual(clip(e, pasted)?.startFrame, 150)
        // Cut takes the clip off the timeline and keeps it.
        XCTAssertTrue(c.runClipMenu(.cut, clipId: "clip:m"))
        XCTAssertNil(clip(e, "clip:m")); XCTAssertEqual(c.clipboard?.items.map(\.clip.id), ["clip:m"])
        // Duplicate lands right after the clip.
        XCTAssertTrue(c.runClipMenu(.duplicate, clipId: "clip:a"))
        XCTAssertEqual(c.view.selection.first.flatMap { clip(e, $0)?.startFrame }, 180)
        XCTAssertEqual(c.clipboard?.items.map(\.clip.id), ["clip:m"], "duplicate leaves the clipboard alone")
    }

    func testClipMenuCopyActsOnTheSelection() throws {
        let (c, _) = try make()
        c.view.selection = ["clip:a", "clip:m"]
        c.openClipMenu("clip:m", x: 10, y: 10)
        XCTAssertTrue(c.runClipMenu(.copy, clipId: "clip:m"))
        XCTAssertEqual(c.clipboard?.items.map(\.clip.id), ["clip:a", "clip:m"])
    }

    func testKeepPitchFromTheMenuIsOneUndoStepAndSaved() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setPlaybackRate(clipId: "clip:m", 2))
        XCTAssertTrue(c.runClipMenu(.keepPitch, clipId: "clip:m"))
        XCTAssertEqual(clip(e, "clip:m")?.preservesPitch, false)
        XCTAssertEqual(e.undoLabel, "Pitch follows speed")
        c.openClipMenu("clip:m", x: 10, y: 10)
        XCTAssertEqual(c.view.clipMenu?.itemRects().map(\.0).first { $0.action == .keepPitch }?.checked, false)
        let json = try serializeNativeProjectDocument(e.document, engine: Self.engine)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(json), engine: Self.engine).sequence.tracks[2].clips[0].preservesPitch, false)
        var raw = try NativeJSONValue.parse(json)
        var seq = raw["sequence"]!; var tracks = seq["tracks"]!.arrayValue!; var clips = tracks[2]["clips"]!.arrayValue!
        clips[0]["preservesPitch"] = .string("no"); tracks[2]["clips"] = .array(clips); seq["tracks"] = .array(tracks); raw["sequence"] = seq
        XCTAssertThrowsError(try parseNativeProjectDocument(raw, engine: Self.engine), "a non-boolean is refused")
        XCTAssertTrue(e.undo()); XCTAssertNil(clip(e, "clip:m")?.preservesPitch, "the default is stored as an absent key")
        XCTAssertFalse(e.setPreservesPitch(clipId: "clip:m", true), "already on")
        XCTAssertTrue(e.setTrackLocked("track:a1", true))
        XCTAssertFalse(e.setPreservesPitch(clipId: "clip:m", false), "locked")
    }

    func testMenuFlipsByItsOwnHeight() throws {
        let (c, _) = try make()
        c.openClipMenu("clip:a", x: 1100, y: 590)
        let m = try XCTUnwrap(c.view.clipMenu)
        XCTAssertEqual(m.x, 900)
        XCTAssertEqual(m.y, 590 - m.height)
        XCTAssertLessThanOrEqual(m.rect.maxY, 600)
    }
    // MARK: Review findings (PR #63)

    static let graded = json().replacingOccurrences(of: #""effectId":"color-grade","enabled":true,"parameters":{}"#,
        with: #""effectId":"color-grading","enabled":true,"parameters":{"lut":{"src":"luts/warm.cube","intensity":0.5}}"#)
    func lut(_ c: NativeProjectClip?) -> String? {
        guard case .object(let l)? = c?.effects.first(where: { $0.effectId == "color-grading" })?.parameters?["lut"],
              case .string(let s)? = l["src"] else { return nil }
        return s
    }

    func testACopiedProjectFolderDoesNotReuseAssetsByIdAlone() throws {
        let (_, one) = try make()
        let board = try XCTUnwrap(one.copyClips(["clip:a"]))
        // The same project.json in another folder: same document id, same asset ids, other files.
        let (_, copy) = try make(dir: "/projects/one-copy")
        XCTAssertEqual(copy.filesToImport(board), ["/projects/one/media/a.mp4"])
        let id = try XCTUnwrap(copy.paste(board, at: 0).first)
        let pasted = try XCTUnwrap(clip(copy, id))
        XCTAssertNotEqual(pasted.assetId, "asset:a", "asset:a of the copy plays /projects/one-copy/media/a.mp4")
        XCTAssertEqual(copy.document.assets.first { $0.id == pasted.assetId }?.source, "/projects/one/media/a.mp4")
        // Back in the folder it came from, the asset is reused and the clip goes back to its own track.
        XCTAssertEqual(one.filesToImport(board), [])
        let back = try XCTUnwrap(one.paste(board, at: 10).first)
        XCTAssertEqual(clip(one, back)?.assetId, "asset:a")
        XCTAssertEqual(trackId(one, back), "track:v1")
    }

    func testLutsTravelWithTheGrade() throws {
        let (_, one) = try make(Self.graded)
        let board = try XCTUnwrap(one.copyClips(["clip:a"]))
        XCTAssertEqual(lut(board.items.first?.clip), "/projects/one/luts/warm.cube")
        let same = try XCTUnwrap(one.paste(board, at: 10).first)
        XCTAssertEqual(lut(clip(one, same)), "luts/warm.cube", "inside its project the LUT stays project-relative")
        let (_, two) = try make(dir: "/projects/two")
        XCTAssertEqual(two.filesToImport(board), ["/projects/one/media/a.mp4", "/projects/one/luts/warm.cube"])
        let other = try XCTUnwrap(two.paste(board, at: 0).first)
        XCTAssertEqual(lut(clip(two, other)), "/projects/one/luts/warm.cube", "never resolved against the other project")
    }

    func testCrossProjectPasteImportsItsFilesFirst() throws {
        let (_, one) = try make(Self.graded)
        let (c, two) = try make(dir: "/projects/two")
        c.clipboard = try XCTUnwrap(one.copyClips(["clip:a"]))
        var asked: [String] = []
        var finish: (([String: String]?) -> Void)?
        c.importForPaste = { paths, done in asked = paths; finish = done }
        c.view.selection = []
        XCTAssertTrue(c.pasteClipboard())
        XCTAssertEqual(asked, ["/projects/one/media/a.mp4", "/projects/one/luts/warm.cube"])
        let before = two.document.sequence.tracks.flatMap(\.clips).count
        XCTAssertEqual(two.document.sequence.tracks.flatMap(\.clips).count, before, "nothing lands until the files are in")
        finish?(["/projects/one/media/a.mp4": "media/a 2.mp4", "/projects/one/luts/warm.cube": "luts/warm.cube"])
        let id = try XCTUnwrap(c.view.selection.first)
        let pasted = try XCTUnwrap(clip(two, id))
        XCTAssertEqual(two.document.assets.first { $0.id == pasted.assetId }?.source, "media/a 2.mp4", "project-relative, so export reads it")
        XCTAssertEqual(lut(pasted), "luts/warm.cube")
        // A failed import pastes nothing.
        let count = two.document.sequence.tracks.flatMap(\.clips).count
        XCTAssertTrue(c.pasteClipboard())
        finish?(nil)
        XCTAssertEqual(two.document.sequence.tracks.flatMap(\.clips).count, count)
    }

    func testMixedTracksTakeAnyKindAndALockedAnchorRefuses() throws {
        let mixed = Self.json().replacingOccurrences(of: #""id":"track:v2","kind":"video""#, with: #""id":"track:v2","kind":"mixed""#)
        let (_, e) = try make(mixed)
        let music = try XCTUnwrap(e.copyClips(["clip:m"]))
        let id = try XCTUnwrap(e.paste(music, at: 0, onto: "track:v2").first)
        XCTAssertEqual(trackId(e, id), "track:v2", "an audio clip onto a mixed track stays there")
        XCTAssertTrue(e.setTrackLocked("track:v2", true))
        XCTAssertEqual(e.paste(music, at: 0, onto: "track:v2"), [])
        XCTAssertEqual(e.lastFailure?.message, "Track is locked")
        // Locked, a track of the other kind refuses too instead of the clip landing somewhere else.
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        XCTAssertEqual(e.paste(music, at: 0, onto: "track:v1"), [])
    }

    func testFrameRatesCompareByValue() throws {
        let (_, one) = try make()
        let board = try XCTUnwrap(one.copyClips(["clip:a"]))
        var json = Self.json(id: "project:extra")
        let plain = #""revision":1,"frameRate":{"numerator":30,"denominator":1}"#
        XCTAssertTrue(json.contains(plain))
        json = json.replacingOccurrences(of: plain, with: #""revision":1,"frameRate":{"numerator":30,"denominator":1,"note":"kept"}"#)
        let (_, other) = try make(json, dir: "/projects/extra")
        XCTAssertNotEqual(other.document.frameRate, one.document.frameRate, "the unknown key is preserved")
        XCTAssertEqual(other.paste(board, at: 0).count, 1, other.lastFailure?.message ?? "")
    }
}

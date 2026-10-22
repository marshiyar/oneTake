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

public extension TimelineEditor {
    /// Capture the visible grade at this time, not stale underlying values of animated controls.
    func effectsForUserLook(clipId: String, time: Double, resolveLut: (String) -> String) -> [NativeClipEffect]? {
        guard let clip = clip(clipId)?.clip,
              let kind = document.assets.first(where: { $0.id == clip.assetId })?.kind,
              kind == .video || kind == .image else { return nil }
        var effects = clip.effects
        let grade = gradeShown(clipId: clipId, time: time)
        if let i = effects.firstIndex(where: { $0.effectId == ColorGrading.effectId }) {
            effects[i].parameters = grade.json; effects[i].enabled = grade.enabled
        } else if grade.isAuthored {
            effects.append(.init(id: "look-grade", effectId: ColorGrading.effectId, enabled: grade.enabled, parameters: grade.json))
        }
        for i in effects.indices where effects[i].effectId == ColorGrading.effectId {
            var grading = ColorGrading(json: effects[i].parameters ?? NativeJSONObject())
            if let lut = grading.lut { grading.lut = .init(src: resolveLut(lut.src), intensity: lut.intensity) }
            effects[i].parameters = grading.json
        }
        return effects
    }

    /// Validate everything before touching any selected clip. The ordinary effect painter serves preview and export.
    @discardableResult func applyUserLook(_ look: UserLook, to selection: Set<String>, lutExists: (String) -> Bool) throws -> Int {
        guard UserLookStore.valid(look) else { throw UserLookError.invalidEffects }
        for effect in look.effects where effect.effectId == ColorGrading.effectId {
            if let path = ColorGrading(json: effect.parameters ?? NativeJSONObject()).lut?.src, !lutExists(path) {
                throw UserLookError.missingLut(look: look.name, path: path)
            }
        }
        let kinds = Dictionary(document.assets.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let targets = document.sequence.tracks.flatMap { track in
            track.clips.filter { selection.contains($0.id) && (kinds[$0.assetId] == .video || kinds[$0.assetId] == .image) }
        }
        guard !targets.isEmpty else { throw UserLookError.noVisualSelection }
        if let locked = targets.first(where: { isClipLocked($0.id) }) { throw UserLookError.lockedClip(locked.id) }
        let ids = Set(targets.map(\.id))
        var next = document
        for ti in next.sequence.tracks.indices {
            for ci in next.sequence.tracks[ti].clips.indices where ids.contains(next.sequence.tracks[ti].clips[ci].id) {
                var effects = look.effects
                for ei in effects.indices { effects[ei].id = "user-look-effect-\(ei + 1)" }
                next.sequence.tracks[ti].clips[ci].effects = effects
                next.sequence.tracks[ti].clips[ci].parameterTracks.removeAll { NativeGradeParameter.isGradeParameter($0.parameterId) }
            }
        }
        guard next != document else { return 0 }
        let validated: NativeProjectDocument
        do { validated = try parseNativeProjectDocument(next, engine: engine) }
        catch { throw UserLookError.invalidEffects }
        withHistory("Apply look") { replaceDocument(validated, inverse: .restoreDocument(document)) }
        return targets.count
    }
}

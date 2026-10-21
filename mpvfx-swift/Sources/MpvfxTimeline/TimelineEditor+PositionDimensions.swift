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

public extension TimelineEditor {
    /// Converts only representations that can retain the authored motion exactly. Spatial paths and
    /// independently timed scalar curves cannot be represented by the other track type without loss.
    func canTogglePositionDimensions(clipId: String) -> Bool {
        positionDimensionTracks(clipId: clipId) != nil
    }

    @discardableResult
    func togglePositionDimensions(clipId: String) -> Bool {
        guard let tracks = positionDimensionTracks(clipId: clipId),
              let (track, _) = clip(clipId),
              let ti = document.sequence.tracks.firstIndex(where: { $0.id == track.id }),
              let ci = document.sequence.tracks[ti].clips.firstIndex(where: { $0.id == clipId }) else { return false }
        let before = document
        var next = document
        next.sequence.tracks[ti].clips[ci].parameterTracks = tracks
        guard let validated = try? parseNativeProjectDocument(next, engine: engine) else { return false }
        withHistory("Separate position dimensions") { replaceDocument(validated, inverse: .restoreDocument(before)) }
        return true
    }

    private func positionDimensionTracks(clipId: String) -> [NativeParameterTrack]? {
        guard let (owner, clip) = clip(clipId), owner.locked != true else { return nil }
        guard clip.staticParameters?[POSITION_X_PARAMETER_ID] == nil,
              clip.staticParameters?[POSITION_Y_PARAMETER_ID] == nil else { return nil }
        let tracks = clip.parameterTracks
        let ids = [Self.positionId, POSITION_X_PARAMETER_ID, POSITION_Y_PARAMETER_ID]
        let rest = tracks.filter { !ids.contains($0.parameterId) }
        let x = tracks.first { $0.parameterId == POSITION_X_PARAMETER_ID }
        let y = tracks.first { $0.parameterId == POSITION_Y_PARAMETER_ID }
        if let position = findVec2PositionTrack(tracks) {
            guard x == nil, y == nil, position.autoRotate != true,
                  !position.keyframes.isEmpty, position.keyframes.allSatisfy({ $0.outgoingPath == nil }) else { return nil }
            var components: [NativeParameterTrack] = []
            for component in [PositionComponent.x, .y] {
                var scalar = position
                scalar.parameterId = positionComponentParameterId(component)
                scalar.id = nativeParameterTrackId(clipId: clipId, parameterId: scalar.parameterId)
                scalar.valueType = .number
                for i in scalar.keyframes.indices {
                    guard case .vec2(let value) = scalar.keyframes[i].value else { return nil }
                    scalar.keyframes[i].id = nativeParameterKeyframeId(parameterTrackId: scalar.id, frame: scalar.keyframes[i].frame)
                    scalar.keyframes[i].value = .number(component == .x ? value.x : value.y)
                }
                components.append(scalar)
            }
            return rest + components
        }
        guard var combined = x, let y, combined.frameRate == y.frameRate,
              !combined.keyframes.isEmpty, combined.keyframes.count == y.keyframes.count else { return nil }
        combined.id = nativeParameterTrackId(clipId: clipId, parameterId: Self.positionId)
        combined.parameterId = Self.positionId
        combined.valueType = .vec2
        for i in combined.keyframes.indices {
            let a = combined.keyframes[i], b = y.keyframes[i]
            guard a.frame == b.frame, a.outgoing == b.outgoing,
                  a.outgoingPath == nil, b.outgoingPath == nil,
                  case .number(let xv) = a.value, case .number(let yv) = b.value else { return nil }
            combined.keyframes[i].id = nativeParameterKeyframeId(parameterTrackId: combined.id, frame: a.frame)
            combined.keyframes[i].value = .vec2(.init(x: xv, y: yv))
        }
        return rest + [combined]
    }
}

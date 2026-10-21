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

extension TimelineEditor {
    /// Converts only representations that can retain the authored motion exactly. Spatial paths and
    /// independently timed scalar curves cannot be represented by the other track type without loss.
    public func canTogglePositionDimensions(clipId: String) -> Bool {
        positionDimensionTracks(clipId: clipId) != nil
    }

    /// Switches between a vector position track and matching scalar tracks as one undoable edit.
    /// Returns false when conversion would lose authored motion or the clip cannot be edited.
    @discardableResult
    public func togglePositionDimensions(clipId: String) -> Bool {
        guard let tracks = positionDimensionTracks(clipId: clipId),
              let (track, _) = clip(clipId),
              let trackIndex = document.sequence.tracks.firstIndex(where: { $0.id == track.id }),
              let clipIndex = document.sequence.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipId })
        else {
            return false
        }
        let before = document
        var next = document
        next.sequence.tracks[trackIndex].clips[clipIndex].parameterTracks = tracks
        guard let validated = try? parseNativeProjectDocument(next, engine: engine) else {
            return false
        }
        withHistory("Separate position dimensions") {
            replaceDocument(validated, inverse: .restoreDocument(before))
        }
        return true
    }

    // Nil means conversion is unavailable; an empty array is a different, valid track collection.
    private func positionDimensionTracks(clipId: String) -> [NativeParameterTrack]? {
        guard let (owner, clip) = clip(clipId), owner.locked != true else {
            return nil
        }
        guard clip.staticParameters?[POSITION_X_PARAMETER_ID] == nil,
              clip.staticParameters?[POSITION_Y_PARAMETER_ID] == nil
        else {
            return nil
        }
        let tracks = clip.parameterTracks
        let ids = [Self.positionId, POSITION_X_PARAMETER_ID, POSITION_Y_PARAMETER_ID]
        let rest = tracks.filter { !ids.contains($0.parameterId) }
        let xTrack = tracks.first { $0.parameterId == POSITION_X_PARAMETER_ID }
        let yTrack = tracks.first { $0.parameterId == POSITION_Y_PARAMETER_ID }
        if let position = findVec2PositionTrack(tracks) {
            guard xTrack == nil, yTrack == nil, position.autoRotate != true,
                  !position.keyframes.isEmpty,
                  position.keyframes.allSatisfy({ $0.outgoingPath == nil })
            else {
                return nil
            }
            var components: [NativeParameterTrack] = []
            for component in [PositionComponent.x, .y] {
                var scalar = position
                scalar.parameterId = positionComponentParameterId(component)
                scalar.id = nativeParameterTrackId(clipId: clipId, parameterId: scalar.parameterId)
                scalar.valueType = .number
                for index in scalar.keyframes.indices {
                    guard case .vec2(let value) = scalar.keyframes[index].value else {
                        return nil
                    }
                    scalar.keyframes[index].id = nativeParameterKeyframeId(
                        parameterTrackId: scalar.id, frame: scalar.keyframes[index].frame
                    )
                    scalar.keyframes[index].value = .number(component == .x ? value.x : value.y)
                }
                components.append(scalar)
            }
            return rest + components
        }
        guard var combined = xTrack, let yTrack, combined.frameRate == yTrack.frameRate,
              !combined.keyframes.isEmpty, combined.keyframes.count == yTrack.keyframes.count
        else {
            return nil
        }
        combined.id = nativeParameterTrackId(clipId: clipId, parameterId: Self.positionId)
        combined.parameterId = Self.positionId
        combined.valueType = .vec2
        for index in combined.keyframes.indices {
            let xFrame = combined.keyframes[index]
            let yFrame = yTrack.keyframes[index]
            guard xFrame.frame == yFrame.frame, xFrame.outgoing == yFrame.outgoing,
                  xFrame.outgoingPath == nil, yFrame.outgoingPath == nil,
                  case .number(let xValue) = xFrame.value, case .number(let yValue) = yFrame.value
            else {
                return nil
            }
            combined.keyframes[index].id = nativeParameterKeyframeId(
                parameterTrackId: combined.id, frame: xFrame.frame
            )
            combined.keyframes[index].value = .vec2(.init(x: xValue, y: yValue))
        }
        return rest + [combined]
    }
}

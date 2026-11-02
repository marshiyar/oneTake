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

/// Edits of a clip's corner pin (`NativeClipCorners`), shared by the stage tool, the keyboard and the inspector.
public extension NativeProjectClip {
    /// The clip has keyframes on any corner component.
    var hasCornerKeyframes: Bool {
        parameterTracks.contains { NativeClipCorners.isCornerParameter($0.parameterId) && !$0.keyframes.isEmpty }
    }

    /// The corner offsets at clip-local `frame`: `corners` with each keyframed component replaced by the value the
    /// keyframes give there. The same evaluation preview and export make, through the keyframe engine.
    func cornersAt(frame: Double, engine: KeyframeEngine? = nil) throws -> NativeClipCorners {
        var values: [String: Double] = [:]
        for track in parameterTracks where NativeClipCorners.isCornerParameter(track.parameterId) && !track.keyframes.isEmpty {
            if case .number(let v) = try evaluateNativeParameterTrack(track, projectFrame: frame, engine: engine) { values[track.parameterId] = v }
        }
        return (corners ?? .identity).resolved { values[$0] }
    }

    /// Sets the corners. A clip with corner keyframes gets a key on every component at `frame` (clip-local, whole
    /// frame); `keyframed` starts keyframing on a clip without any. Otherwise the offsets are saved on the clip and
    /// an all-zero set removes the field.
    mutating func setCorners(_ new: NativeClipCorners, atFrame frame: Double, frameRate: RationalFrameRate, keyframed: Bool = false) {
        guard keyframed || hasCornerKeyframes else {
            corners = new.isIdentity ? nil : new
            return
        }
        let f = frame.rounded()
        for corner in NativeClipCorners.Corner.allCases { for axis in ["x", "y"] {
            let id = NativeClipCorners.parameterId(corner, axis)
            let value = axis == "x" ? new[corner].x : new[corner].y
            var index = parameterTracks.firstIndex { $0.parameterId == id }
            if index == nil {
                parameterTracks.append(NativeParameterTrack(id: UUID().uuidString.lowercased(), parameterId: id, valueType: .number,
                                                            frameRate: frameRate, keyframes: []))
                index = parameterTracks.count - 1
            }
            let i = index!
            if let k = parameterTracks[i].keyframes.firstIndex(where: { $0.frame == f }) {
                parameterTracks[i].keyframes[k].value = .number(value)
            } else {
                parameterTracks[i].keyframes.append(NativeKeyframe(id: UUID().uuidString.lowercased(), frame: f, value: .number(value), outgoing: .linear))
                parameterTracks[i].keyframes.sort { $0.frame < $1.frame }
            }
        } }
    }

    /// Reset: back to the plain box. Removes the saved corners and every corner keyframe track.
    mutating func resetCorners() {
        corners = nil
        parameterTracks.removeAll { NativeClipCorners.isCornerParameter($0.parameterId) }
    }

    var hasCornerState: Bool { corners != nil || parameterTracks.contains { NativeClipCorners.isCornerParameter($0.parameterId) } }
}

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
// The position parameter track: vec2 values and their x/y components.
import Foundation

public let POSITION_PARAMETER_ID = "transform.position"
public let POSITION_X_PARAMETER_ID = "transform.position.x"
public let POSITION_Y_PARAMETER_ID = "transform.position.y"

public enum PositionComponent: String, Equatable { case x, y }

public func positionComponentOf(_ parameterId: String) -> PositionComponent? {
    if parameterId == POSITION_X_PARAMETER_ID { return .x }
    if parameterId == POSITION_Y_PARAMETER_ID { return .y }
    return nil
}

public func positionComponentParameterId(_ c: PositionComponent) -> String {
    c == .x ? POSITION_X_PARAMETER_ID : POSITION_Y_PARAMETER_ID
}

public func isVec2PositionTrack(_ track: NativeParameterTrack) -> Bool {
    track.parameterId == POSITION_PARAMETER_ID && track.valueType == .vec2
}

public func findVec2PositionTrack(_ tracks: [NativeParameterTrack]) -> NativeParameterTrack? {
    tracks.first(where: isVec2PositionTrack)
}

/// One component of a vec2 position, for listing keyframes (never for evaluation).
public struct PositionComponentView: Equatable {
    public struct Key: Equatable { public let id: String; public let frame: Double; public let value: Double; public let outgoing: NativeInterpolation }
    public let component: PositionComponent
    public let parameterId: String
    public let keyframes: [Key]
}

/// Components of a vec2 position not shadowed by a scalar x/y sibling track.
/// A non-vec2 keyframe value yields NaN (JS `value[component]` would be undefined).
public func positionComponentViews(_ track: NativeParameterTrack, siblings: [NativeParameterTrack] = []) -> [PositionComponentView] {
    let shadowed = Set(siblings.map(\.parameterId))
    return [PositionComponent.x, .y].filter { !shadowed.contains(positionComponentParameterId($0)) }.map { c in
        PositionComponentView(component: c, parameterId: positionComponentParameterId(c), keyframes: track.keyframes.map { k in
            let v: Double
            if case .vec2(let p) = k.value { v = c == .x ? p.x : p.y } else { v = .nan }
            return .init(id: k.id, frame: k.frame, value: v, outgoing: k.outgoing)
        })
    }
}

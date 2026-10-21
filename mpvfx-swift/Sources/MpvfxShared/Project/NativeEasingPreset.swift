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
// The project's custom easing presets (`easingPresets` at the document root), saved by the Easing panel so a curve a
// user made is offered again in that project. The record is rebuilt field by field: unknown keys on a preset are not
// kept. Absent stays absent; the validator rejects a malformed list instead of repairing it.
import Foundation

public let NATIVE_EASING_PRESET_LIMIT = 64
public let NATIVE_EASING_PRESET_NAME_LIMIT = 64

public struct NativeEasingPreset: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var outgoing: NativeInterpolation
    public init(id: String, name: String, outgoing: NativeInterpolation) {
        self.id = id; self.name = name; self.outgoing = outgoing
    }
}

/// Every issue in `easingPresets`; nothing when the key is absent.
func validateNativeEasingPresets(_ raw: NativeJSONValue?, _ issues: inout Issues) {
    guard let raw else { return }
    guard let list = raw.arrayValue else {
        return pushIssue(&issues, .invalidRoot, "easingPresets", "Easing presets must be an array")
    }
    if list.count > NATIVE_EASING_PRESET_LIMIT {
        pushIssue(&issues, .invalidRoot, "easingPresets", "At most \(NATIVE_EASING_PRESET_LIMIT) easing presets")
    }
    var seen = Set<String>()
    for (i, preset) in list.enumerated() {
        let path = "easingPresets[\(i)]"
        guard preset.isRecord else { pushIssue(&issues, .invalidRoot, path, "Easing preset must be an object"); continue }
        if isNonEmptyString(preset["id"]), let id = preset["id"]?.stringValue {
            if !seen.insert(id).inserted { pushIssue(&issues, .duplicateId, "\(path).id", "Duplicate easing preset ID \(id)") }
        } else {
            pushIssue(&issues, .invalidId, "\(path).id", "Easing preset ID must be a non-empty string")
        }
        validateEasingPresetName(preset["name"], "\(path).name", &issues)
        validateEasingPresetOutgoing(preset["outgoing"], "\(path).outgoing", &issues)
    }
}

private func validateEasingPresetName(_ raw: NativeJSONValue?, _ path: String, _ issues: inout Issues) {
    let count = raw?.stringValue.map { jsTrimmedIsEmpty($0) ? 0 : $0.count } ?? 0
    if !(1...NATIVE_EASING_PRESET_NAME_LIMIT).contains(count) {
        pushIssue(&issues, .invalidRoot, path, "Easing preset name must be 1 to \(NATIVE_EASING_PRESET_NAME_LIMIT) characters")
    }
}

private func validateEasingPresetOutgoing(_ raw: NativeJSONValue?, _ path: String, _ issues: inout Issues) {
    switch raw?["type"]?.stringValue {
    case "hold"?, "linear"?: return
    case "cubic-bezier"?:
        let p = raw?["controlPoints"]
        let n = ["x1", "y1", "x2", "y2"].map { p?[$0]?.numberValue }
        let ok = n.allSatisfy { $0?.isFinite == true } && [n[0], n[2]].allSatisfy { (0...1).contains($0 ?? -1) }
        if !ok { pushIssue(&issues, .invalidRoot, "\(path).controlPoints", "Easing preset control points must be finite, with x1 and x2 in 0 to 1") }
    default:
        pushIssue(&issues, .invalidRoot, "\(path).type", "Easing preset outgoing must be hold, linear or cubic-bezier")
    }
}

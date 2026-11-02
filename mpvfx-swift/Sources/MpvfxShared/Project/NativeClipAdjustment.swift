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

// An adjustment clip (`clip.adjustment: true`): an element clip with no picture of its own whose grade and effects
// apply to the composite of every track below it for its duration (issue #326).

/// Every bad value of `clip.adjustment` as a typed issue; nothing is clamped. `assetKind` is the clip's asset kind
/// (nil when the asset is missing, reported elsewhere).
func validateNativeClipAdjustment(_ clip: NativeJSONValue, assetKind: String?, _ path: String,
                                  _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let raw = clip["adjustment"] else { return }
    let p = "\(path).adjustment"
    guard let on = raw.boolValue else { return pushIssue(&issues, .invalidClip, p, "Adjustment must be a boolean") }
    guard on else { return }
    if let assetKind, assetKind != "element" {
        pushIssue(&issues, .invalidClip, p, "Only a clip of an element asset can be an adjustment")
    }
    for name in ["text", "shape", "generator", "holdSourceFrame", "fill", "textStyle"] where clip[name] != nil {
        pushIssue(&issues, .invalidClip, p, "An adjustment has no picture of its own, so it cannot also carry \(name)")
    }
}

public extension NativeProjectClip {
    /// Draws nothing of its own: grades the composite below.
    var isAdjustment: Bool { adjustment == true }
}

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
    /// One history entry includes the element asset, a compatible lane if needed, and its procedural clip.
    @discardableResult func addGenerator(_ kind: NativeGeneratorKind, at time: Double, seconds: Double = 5) -> String? {
        guard time.isFinite, time >= 0, seconds.isFinite, seconds > 0, (time * fps).isFinite, (seconds * fps).isFinite else { return nil }
        let frames = max(1, (seconds * fps).rounded())
        return withHistory("Add background", coalesceKey: "generator-\(UUID().uuidString)") {
            guard let asset = addAsset(kind: .element, name: kind.label, source: nil, durationFrames: frames) else { return nil }
            return insertClip(assetId: asset, at: time, durationFrames: frames) { $0.generator = kind.fill }
        }
    }
    @discardableResult func editGenerator(clipId: String, _ body: (inout NativeJSONValue) -> Void) -> Bool {
        withHistory("Edit background") {
            editClip(clipId) { clip in
                guard let fill = clip.generator, fill.isGenerator else { return false }
                var raw = fill.raw; body(&raw)
                guard raw != fill.raw else { return false }
                clip.generator = NativeFill(raw: raw); return true
            }
        }
    }
}

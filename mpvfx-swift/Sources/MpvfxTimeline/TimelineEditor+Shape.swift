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
    /// Validated document edit, recorded as one undo step and persisted through the normal project serializer.
    @discardableResult
    public func setClipShape(clipId: String, _ shape: NativeClipShape?) -> Bool {
        do {
            guard let updated = try nativeClipShapeEditPlan(document, clipId: clipId, shape: shape, engine: engine)
            else {
                return false
            }
            return commitPresets(updated, label: "Set shape")
        } catch { return false }
    }

    /// Puts a new shape layer on the timeline at `time` (on the first free video row, else a new one) with its box
    /// at (`left`, `top`) and `width` x `height` composition pixels, `seconds` long (5 by default). One undo step.
    /// Returns its id, or nil when the document refuses the shape.
    @discardableResult
    public func addShapeClip(_ shape: NativeClipShape, left: Double, top: Double, width: Double, height: Double,
                             at time: Double, seconds: Double = 5) -> String? {
        let frames = max(1, (seconds * fps).rounded())
        return withHistory("Add shape", coalesceKey: "add-shape-\(UUID().uuidString)") { () -> String? in
            guard let assetId = addAsset(kind: .element, name: "Shape", source: nil, durationFrames: frames) else { return nil }
            return insertClip(assetId: assetId, at: time, durationFrames: frames) { c in
                c.shape = shape
                var p = c.staticParameters ?? [:]
                p["layout.left"] = .number(left); p["layout.top"] = .number(top)
                p["layout.width"] = .number(width); p["layout.height"] = .number(height)
                c.staticParameters = p
            }
        }
    }
}

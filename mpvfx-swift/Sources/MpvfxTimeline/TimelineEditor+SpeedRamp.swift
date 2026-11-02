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
// Speed ramps on the timeline editor: each ramp edit is one undo step, refused on a locked track, and an edit that
// changes the clip's length reconciles the transitions around it.
import Foundation
import MpvfxShared

public extension TimelineEditor {
    /// The clip's speed ramp when it has one this build understands, else nil.
    func speedRamp(of clipId: String) -> NativeSpeedRamp? {
        guard let ramp = clip(clipId)?.clip.speedRamp, ramp.isSupported else { return nil }
        return ramp
    }

    /// Whether the clip has a speed ramp this build understands.
    func isRamped(_ clipId: String) -> Bool { speedRamp(of: clipId) != nil }

    /// Applies a speed ramp edit as one undo step ("Set speed shape", "Move speed point", …). With `keepLength`
    /// the clip keeps its length; without it the clip is resized to the ramp and the next clips ripple. A refusal
    /// (locked track, a value the document rejects) sets `lastFailure` and changes nothing.
    @discardableResult
    func applySpeedRamp(clipId: String, _ command: NativeSpeedRampCommand, keepLength: Bool = true) -> Bool {
        if isClipLocked(clipId) {
            lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "Track is locked"); return false
        }
        let before = document
        do {
            let r = try applyNativeSpeedRampCommand(document, clipId: clipId, command, keepLength: keepLength, engine: engine)
            guard case .success(let doc, let inverse) = r else { lastFailure = r.failure; return false }
            lastFailure = nil
            withHistory(Self.speedRampLabel(command)) { replaceDocument(doc, inverse: inverse) }
            if !keepLength { reportTransitionChanges(from: before) }
            return true
        } catch {
            lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "The speed ramp could not be applied"); return false
        }
    }

    /// The ramp key (Shift+R): a clip with a ramp loses it, a clip without one gets the "Slow middle" shape. One
    /// undo step either way.
    @discardableResult
    func toggleSpeedRamp(clipId: String) -> Bool {
        applySpeedRamp(clipId: clipId, isRamped(clipId) ? .clear : .setShape(.slowMiddle))
    }

    internal static func speedRampLabel(_ command: NativeSpeedRampCommand) -> String {
        switch command {
        case .setShape: "Set speed shape"
        case .addPoint: "Add speed point"
        case .movePoint: "Move speed point"
        case .removePoint: "Remove speed point"
        case .setEase: "Change speed ease"
        case .clear: "Remove speed ramp"
        }
    }
}

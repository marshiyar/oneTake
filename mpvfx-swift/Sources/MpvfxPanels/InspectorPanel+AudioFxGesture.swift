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
import MpvfxAudioGraph
import MpvfxCanvas

internal struct FxControlGesture {
    internal var owner: String
    internal var before: FxChain
    internal var beforeSerialized: String?
    internal var latest: FxChain
    internal var lastWrite: Double = -.infinity
}

extension InspectorPanel {
    /// Control previews are capped at the issue's 30 ms cadence; pointer-up always writes the final value.
    private static let fxGestureWriteInterval: TimeInterval = 0.030
    private static let fxInsertionLineThickness = 2.0

    internal static func fxSerialized(_ chain: FxChain) -> String? {
        chain.nodes.isEmpty ? nil : AudioFx.serializeChain(chain)
    }

    internal func afxReorderHeader(_ canvas: CanvasContext, key: String, rect: CanvasRect) {
        guard let index = fxHeaderButtons[key] else {
            return
        }
        fxHeaders[index] = rect
        guard fxHeaderMoved, let target = fxHeaderTarget else {
            return
        }
        let isEnd = target > (fxHeaderButtons.values.max() ?? index)
        if target == index || (isEnd && index == fxHeaderButtons.values.max()) {
            let line = CanvasRect(
                x: rect.x,
                y: (isEnd ? rect.maxY : rect.y) - Self.fxInsertionLineThickness / 2,
                width: rect.width,
                height: Self.fxInsertionLineThickness
            )
            canvas.fillRect(line, PanelTheme.accent)
        }
    }

    internal func beginFxGesture() {
        guard fxGesture == nil, let editor, let owner = audioFxUI.owner,
            let current = auditionOwner(editor)?.chain
        else {
            return
        }
        let stored =
            owner.hasPrefix("bus:")
            ? editor.audioGroup(String(owner.dropFirst("bus:".count)))?.fxChain
            : editor.clip(String(owner.dropFirst("clip:".count)))?.clip.audioFxChain
        fxGesture = FxControlGesture(owner: owner, before: current, beforeSerialized: stored, latest: current)
    }

    internal func previewFxGesture(_ next: FxChain) -> Bool {
        guard var gesture = fxGesture else {
            return false
        }
        gesture.latest = next
        let now = fxGestureNow()
        if now - gesture.lastWrite >= Self.fxGestureWriteInterval {
            gesture.lastWrite = now
            fxGesture = gesture
            _ = editor?.previewAudioFxChain(
                owner: gesture.owner, chain: next == gesture.before ? gesture.beforeSerialized : Self.fxSerialized(next)
            )
        } else {
            fxGesture = gesture
        }
        return true
    }

    internal func finishFxGesture() {
        guard let gesture = fxGesture else {
            return
        }
        fxGesture = nil
        let after = gesture.latest == gesture.before ? gesture.beforeSerialized : Self.fxSerialized(gesture.latest)
        _ = editor?.previewAudioFxChain(owner: gesture.owner, chain: after)
        editor?.finishAudioFxGesture(owner: gesture.owner, before: gesture.beforeSerialized, after: after)
    }

    internal func cancelFxGesture() {
        guard let gesture = fxGesture else {
            return
        }
        fxGesture = nil
        fxGestureCommit = nil
        sliderDrag = nil
        customDrag = nil
        customGesturePointer = nil
        audioFxUI.graphDrag = nil
        _ = editor?.previewAudioFxChain(owner: gesture.owner, chain: gesture.beforeSerialized)
    }
}

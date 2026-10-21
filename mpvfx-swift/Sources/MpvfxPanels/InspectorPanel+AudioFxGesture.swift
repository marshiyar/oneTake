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

struct FxControlGesture {
    var owner: String
    var before: FxChain
    var beforeSerialized: String?
    var latest: FxChain
    var lastWrite: Double = -.infinity
}

extension InspectorPanel {
    func afxReorderHeader(_ canvas: CanvasContext, key: String, rect: CanvasRect) {
        guard let index = fxHeaderButtons[key] else { return }
        fxHeaders[index] = rect
        guard fxHeaderMoved, let target = fxHeaderTarget else { return }
        let isEnd = target > (fxHeaderButtons.values.max() ?? index)
        if target == index || (isEnd && index == fxHeaderButtons.values.max()) {
            canvas.fillRect(CanvasRect(x: rect.x, y: (isEnd ? rect.maxY : rect.y) - 1, width: rect.width, height: 2), PanelTheme.accent)
        }
    }

    func beginFxGesture() {
        guard fxGesture == nil, let editor, let owner = audioFxUI.owner,
              let current = auditionOwner(editor)?.chain else { return }
        let stored = owner.hasPrefix("bus:") ? editor.audioGroup(String(owner.dropFirst(4)))?.fxChain
            : editor.clip(String(owner.dropFirst(5)))?.clip.audioFxChain
        fxGesture = FxControlGesture(owner: owner, before: current, beforeSerialized: stored, latest: current)
    }

    func previewFxGesture(_ next: FxChain) -> Bool {
        guard var gesture = fxGesture else { return false }
        gesture.latest = next
        let now = fxGestureNow()
        if now - gesture.lastWrite >= 0.030 {
            gesture.lastWrite = now
            fxGesture = gesture
            _ = editor?.previewAudioFxChain(owner: gesture.owner, chain: next == gesture.before ? gesture.beforeSerialized : Self.fxSerialized(next))
        } else { fxGesture = gesture }
        return true
    }

    static func fxSerialized(_ chain: FxChain) -> String? {
        chain.nodes.isEmpty ? nil : AudioFx.serializeChain(chain)
    }

    func finishFxGesture() {
        guard let gesture = fxGesture else { return }
        fxGesture = nil
        let after = gesture.latest == gesture.before ? gesture.beforeSerialized : Self.fxSerialized(gesture.latest)
        _ = editor?.previewAudioFxChain(owner: gesture.owner, chain: after)
        editor?.finishAudioFxGesture(owner: gesture.owner, before: gesture.beforeSerialized, after: after)
    }

    func cancelFxGesture() {
        guard let gesture = fxGesture else { return }
        fxGesture = nil; fxGestureCommit = nil; sliderDrag = nil
        customDrag = nil; customGesturePointer = nil; audioFxUI.graphDrag = nil
        _ = editor?.previewAudioFxChain(owner: gesture.owner, chain: gesture.beforeSerialized)
    }
}

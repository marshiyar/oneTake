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
import MpvfxDesktopCore

/// Natural pixel sizes for media clips (resolveDroppedAssetDimensions): an untouched clip is sized by
/// fitTimelineAssetGeometry of its media's natural size. New assets carry the size (cached on the asset when
/// added); for assets saved without one the backend probe is asked once and the answer kept for the session,
/// so older projects show the right box without rewriting the document.
extension EditorSession {
    func requestNaturalSizes() {
        guard let backend, let projectId = project?.id else { return }
        for asset in editor.document.assets where (asset.kind == .video || asset.kind == .image) && asset.naturalSize == nil {
            guard let source = asset.source, !source.isEmpty, naturalSizes[source] == nil, !naturalSizeProbes.contains(source) else { continue }
            naturalSizeProbes.insert(source)
            naturalSizePending.insert(source)
            Task { [weak self] in
                let streams = try? await backend.mediaStreams(projectId: projectId, source: source)
                self?.postToUI {
                    guard let self, self.project?.id == projectId else { return }
                    self.naturalSizePending.remove(source)
                    guard let size = streams?.naturalSize else {   // stays in naturalSizeProbes: asked once; drawn full frame
                        self.composedDocument = nil; self.syncStage(); self.redraw(); return
                    }
                    self.naturalSizes[source] = size
                    self.composedDocument = nil   // re-evaluate the preview boxes
                    self.syncStage(); self.panels?.syncItems(); self.redraw()
                }
            }
        }
    }
}

extension EditorSession {
    /// A media asset whose natural size is still being probed (not drawn yet).
    func isSizePending(_ asset: NativeProjectAsset) -> Bool {
        guard asset.kind == .video || asset.kind == .image, asset.naturalSize == nil, let s = asset.source else { return false }
        return naturalSizes[s] == nil && naturalSizePending.contains(s)
    }
    func isSizePending(clipId: String) -> Bool {
        guard let c = editor.clip(clipId)?.clip, let a = editor.document.assets.first(where: { $0.id == c.assetId }) else { return false }
        return isSizePending(a)
    }
}

extension DesktopMediaStreams {
    var naturalSize: NativeMediaNaturalSize? {
        guard let width, let height else { return nil }
        let s = NativeMediaNaturalSize(width: width, height: height)
        return s.isValid ? s : nil
    }
}

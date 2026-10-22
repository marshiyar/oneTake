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

extension SessionPanels {
    /// Resolve a bin file before committing; asynchronous probes cannot edit a different project or changed clip.
    func replaceMedia(path: String, clipId: String) {
        guard let kind = assetKind(path: path), let entry = media.first(where: { $0.path == path }),
              let (_, original) = session.editor.clip(clipId) else { return }
        let editor = session.editor, project = session.project?.id
        let existing = editor.document.assets.first { $0.source == path && $0.kind == kind }
        let finish: (Double, NativeMediaNaturalSize?) -> Void = { [weak self] seconds, natural in
            guard let self, self.session.project?.id == project, self.session.editor === editor,
                  editor.clip(clipId)?.clip == original else { return }
            var asset = existing ?? NativeProjectAsset(id: "asset:\(UUID().uuidString)", kind: kind, name: entry.name,
                source: path, durationFrames: max(1, (seconds * editor.fps).rounded(.down)))
            if existing == nil { asset.naturalSize = natural }
            if editor.replaceMedia(clipId: clipId, asset: asset) {
                self.session.composedDocument = nil
                self.session.syncStage(); self.syncItems()
            } else if let failure = editor.lastFailure {
                self.session.player.view.showToast(failure.message, isError: true)
            }
            self.redraw()
        }
        if let existing { finish(existing.durationFrames / editor.fps, existing.naturalSize); return }
        let natural = entry.width.flatMap { w in entry.height.map { NativeMediaNaturalSize(width: w, height: $0) } }
        let duration = kind == .image ? 5 : knownDuration(path)
        if let duration, kind == .audio || natural != nil { finish(duration, natural); return }
        guard let backend, let projectId else { return }
        let post = uiPost
        Task { [weak self] in
            do {
                let streams = try await backend.mediaStreams(projectId: projectId, source: path)
                post { finish(duration ?? streams.duration, natural ?? streams.naturalSize) }
            } catch {
                post {
                    guard let self, self.session.project?.id == project else { return }
                    self.session.player.view.showToast("Could not read replacement media: \(error)", isError: true); self.redraw()
                }
            }
        }
    }
}

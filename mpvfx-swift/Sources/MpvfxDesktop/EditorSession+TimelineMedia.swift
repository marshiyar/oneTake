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
import MpvfxCanvas
import MpvfxTimeline
import MpvfxDesktopCore

/// Feeds the timeline's filmstrips and waveforms (TimelineMediaFeeder) from the session's one media cache,
/// `mediaThumbnails` (MediaThumbnails.swift): video strips from the backend's thumbnails,
/// images from the file, peaks from the backend's waveform. When the cache forgets a file the feeder drops the
/// clips' pictures for it so they load again.
extension EditorSession {
    func makeTimelineMediaFeeder() -> TimelineMediaFeeder {
        let feeder = TimelineMediaFeeder(view: timeline.view, loadFrames: { [weak self] req, done in
            guard let self, let asset = self.editor.document.assets.first(where: { $0.id == req.assetId }),
                  let source = asset.source, !source.isEmpty else { return done(nil) }
            let backend = self.backend.flatMap { b in self.project.map { (backend: b, projectId: $0.id, source: source) } }
            self.mediaThumbnails.filmstrip(path: self.absoluteMediaPath(source), still: req.kind == .image, count: req.frameCount,
                                           duration: asset.durationFrames / max(self.editor.fps, 1), backend: backend) { strip in
                done(strip.map { TimelineThumbnailStrip(frames: $0.frames, aspect: $0.aspect) })
            }
        }, loadPeaks: { [weak self] assetId, done in
            guard let self, let source = self.editor.document.assets.first(where: { $0.id == assetId })?.source,
                  let backend = self.backend, let projectId = self.project?.id else { return done(nil) }
            self.mediaThumbnails.waveform(backend: backend, projectId: projectId, source: source, bars: TimelineMediaFeeder.waveformBars) {
                done($0.isEmpty ? nil : $0)
            }
        })
        // The cache answers on the UI thread already.
        feeder.needsDisplay = { [weak self] in self?.redraw() }
        mediaThumbnails.onForget = { [weak self, weak feeder] path, source in
            guard let self, let feeder else { return }
            if path == nil && source == nil { feeder.invalidate(); return }
            let ids = self.editor.document.assets.filter { a in
                guard let s = a.source else { return false }
                return s == source || self.absoluteMediaPath(s) == path
            }.map(\.id)
            if !ids.isEmpty { feeder.invalidate(assets: Set(ids)) }
        }
        return feeder
    }

    func absoluteMediaPath(_ source: String) -> String {
        guard !source.hasPrefix("/"), let dir = projectDir else { return source }
        return dir.appendingPathComponent(source).path
    }
}

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

/// Feeds the clip content the timeline draws (useRenderClipContent): waveform peaks for audio clips and
/// filmstrip frames for video/image clips. It works out what the visible clips need, asks the host's loaders
/// (backend video frames / waveform peaks) and fills `view.waveforms` / `view.thumbnails`, asking for a redraw
/// when an answer lands. It keeps no pictures of its own: the host's loaders answer from the app's one media
/// cache (MediaThumbnails), and this only remembers which (asset, strip size) it already asked for.
///
/// Strip size follows the thumbnail scheduler: one frame first, then up to six across the source once
/// the clip is wide enough at the current zoom (computeThumbnailStrip tiles: THUMBNAIL_CLIP_HEIGHT × aspect).
public final class TimelineMediaFeeder {
    public struct FramesRequest: Hashable, Sendable {
        public var assetId: String
        public var kind: TimelineClipKind
        public var frameCount: Int
    }
    public typealias FramesLoader = (FramesRequest, @escaping (TimelineThumbnailStrip?) -> Void) -> Void
    public typealias PeaksLoader = (_ assetId: String, @escaping ([Double]?) -> Void) -> Void

    public let view: TimelineView
    let loadFrames: FramesLoader
    let loadPeaks: PeaksLoader
    /// Redraw after an answer lands (the host's needsDisplay).
    public var needsDisplay: (() -> Void)?
    /// Hop to the UI thread; loaders may answer on any queue.
    public var post: (@escaping () -> Void) -> Void = { $0() }

    public static let maxFrames = 6, waveformBars = 48
    /// "assetId#frameCount" strips and asset peaks already delivered to the view.
    public private(set) var loadedFrames: Set<String> = [], loadedPeaks: Set<String> = []
    var pendingFrames: Set<String> = [], pendingPeaks: Set<String> = []
    var failedFrames: Set<String> = [], failedPeaks: Set<String> = []
    /// Aspect learned from the first strip per asset (sizes the tiles before the rich strip arrives).
    var aspects: [String: Double] = [:]

    public init(view: TimelineView, loadFrames: @escaping FramesLoader, loadPeaks: @escaping PeaksLoader) {
        self.view = view; self.loadFrames = loadFrames; self.loadPeaks = loadPeaks
    }

    static func key(_ asset: String, _ count: Int) -> String { "\(asset)#\(count)" }

    /// Frames worth requesting for a clip `width` px wide: 1 until the aspect is known, then the tile count, capped at 6.
    func wantedFrames(asset: String, kind: TimelineClipKind, width: Double) -> Int {
        if kind == .image { return 1 }   // a still repeats
        guard let aspect = aspects[asset] else { return 1 }
        let tileW = max(1, (TimelineView.thumbnailClipHeight * aspect).rounded())
        return max(1, min(Self.maxFrames, Int((width / tileW).rounded(.up))))
    }

    /// Call before each paint (cheap when nothing is missing).
    public func update() {
        var widest: [String: (kind: TimelineClipKind, width: Double)] = [:]
        var audio: Set<String> = []
        for track in view.tracks {
            for clip in track.clips {
                guard let id = clip.assetId else { continue }
                switch clip.kind {
                case .audio: audio.insert(id)
                case .video, .image:
                    let w = (clip.end - clip.start) * view.pixelsPerSecond
                    if w > (widest[id]?.width ?? -1) { widest[id] = (clip.kind, w) }
                default: break
                }
            }
        }
        for id in audio { feedPeaks(id) }
        guard view.thumbnailsEnabled else { return }
        for (id, w) in widest { feedFrames(id, kind: w.kind, want: wantedFrames(asset: id, kind: w.kind, width: w.width)) }
    }

    func feedPeaks(_ id: String) {
        guard !loadedPeaks.contains(id), !pendingPeaks.contains(id), !failedPeaks.contains(id) else { return }
        pendingPeaks.insert(id)
        loadPeaks(id) { [weak self] peaks in
            self?.post {
                guard let self else { return }
                self.pendingPeaks.remove(id)
                guard let peaks, !peaks.isEmpty else { self.failedPeaks.insert(id); return }
                self.loadedPeaks.insert(id); self.view.waveforms[id] = peaks
                self.needsDisplay?()
            }
        }
    }

    func feedFrames(_ id: String, kind: TimelineClipKind, want: Int) {
        // The strip on screen stays up while another size loads; a size already delivered is not asked for again.
        let k = Self.key(id, want)
        guard !loadedFrames.contains(k), !pendingFrames.contains(k), !failedFrames.contains(k) else { return }
        pendingFrames.insert(k)
        loadFrames(FramesRequest(assetId: id, kind: kind, frameCount: want)) { [weak self] strip in
            self?.post {
                guard let self else { return }
                self.pendingFrames.remove(k)
                guard let strip, !strip.frames.isEmpty else { self.failedFrames.insert(k); return }
                self.loadedFrames.insert(k)
                if strip.aspect.isFinite, strip.aspect > 0 { self.aspects[id] = strip.aspect }
                if self.view.thumbnailsEnabled { self.view.thumbnails[id] = strip }
                // The aspect may now call for a bigger strip; the redraw's update() asks for it.
                self.needsDisplay?()
            }
        }
    }

    /// The media changed on disk (rename / replace / the shared cache was cleared): forget these assets (nil: all).
    public func invalidate(assets: Set<String>? = nil) {
        func drop(_ k: String) -> Bool { assets.map { a in a.contains { k == $0 || k.hasPrefix($0 + "#") } } ?? true }
        loadedFrames = loadedFrames.filter { !drop($0) }; failedFrames = failedFrames.filter { !drop($0) }
        loadedPeaks = loadedPeaks.filter { !drop($0) }; failedPeaks = failedPeaks.filter { !drop($0) }
        aspects = aspects.filter { !drop($0.key) }
        if let assets { for a in assets { view.thumbnails[a] = nil; view.waveforms[a] = nil } } else { view.thumbnails = [:]; view.waveforms = [:] }
    }
}

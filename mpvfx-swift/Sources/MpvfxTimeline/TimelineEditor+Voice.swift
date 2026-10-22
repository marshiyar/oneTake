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

public extension TimelineEditor {
    /// An ordinary audio asset and clip; earlier overlapping takes remain muted on the voice lane.
    /// The WAV carries leading silence for the sub-frame portion of measured capture latency.
    @discardableResult
    func addVoiceTake(source: String, seconds: Double, at start: Double) -> Bool {
        guard seconds.isFinite, seconds > 0, start.isFinite, start >= 0 else { return false }
        let length = floor(seconds * fps)
        guard length >= 1 else { return false }
        var doc = document
        let number = doc.assets.filter { $0.name.hasPrefix("Voice-over ") }.count + 1
        let asset = NativeProjectAsset(id: "asset:\(UUID().uuidString.lowercased())", kind: .audio,
                                      name: "Voice-over \(number)", source: source, durationFrames: length)
        doc.assets.append(asset)
        let i: Int
        let assets = Dictionary(doc.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let existing = doc.sequence.tracks.firstIndex(where: {
            let voice = $0.id.hasPrefix("track:voice:") || Self.trackName($0, displayNumber: 0, assets: assets).lowercased() == "voice"
            return $0.kind == .audio && $0.locked != true && voice
        }) { i = existing } else {
            i = doc.sequence.tracks.count
            let display = (doc.sequence.tracks.compactMap { $0.lane?.displayTrack }.max() ?? Double(i - 1)) + 1
            let authored = (doc.sequence.tracks.filter { $0.kind == .audio }.compactMap { $0.lane?.authoredTrack }.max() ?? 0) + 1
            doc.sequence.tracks.append(NativeProjectTrack(id: "track:voice:\(UUID().uuidString.lowercased())", kind: .audio,
                lane: .init(authoredTrack: authored, displayTrack: display), clips: []))
        }
        let begin = (start * fps).rounded()
        for c in doc.sequence.tracks[i].clips.indices {
            let clip = doc.sequence.tracks[i].clips[c]
            if clip.startFrame < begin + length && clip.startFrame + clip.durationFrames > begin {
                doc.sequence.tracks[i].clips[c].muted = true
            }
        }
        doc.sequence.tracks[i].clips.append(.fresh(id: "clip:\(UUID().uuidString.lowercased())", assetId: asset.id,
                                                  startFrame: begin, durationFrames: length))
        doc.sequence.tracks[i].clips.sort { $0.startFrame < $1.startFrame }
        return commit(doc, "Record voice")
    }
}

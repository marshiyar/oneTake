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

/// Track targeting (docs/DESIGN.md step 4). Every track header carries a tag: `V1`, `V2`… for picture tracks counted
/// from the bottom (V1 is the base layer the others are drawn over) and `A1`, `A2`… for audio tracks counted from the
/// top. One track of each family is targeted, V1 and A1 until the user picks another; its tag is drawn in the accent,
/// and a clip added at the playhead goes onto it when it is free (`TimelineController.targetedInsertTrack`).
/// Targeting is editor state: it is not saved in the document and has no undo step.
public struct TimelineTrackTargets: Equatable, Sendable {
    public enum Family: String, Sendable, CaseIterable { case video = "V", audio = "A" }

    /// The user's choice per family; an empty id means the user turned that family's target off.
    var chosen: [Family: String] = [:]
    public init() {}

    /// Mixed tracks hold pictures, so they count with the video tracks.
    public static func family(_ kind: String) -> Family { kind == "audio" ? .audio : .video }

    /// The tag of every track, in display order.
    public static func tags(_ tracks: [TimelineTrackModel]) -> [String] {
        var out = [String](repeating: "", count: tracks.count)
        var video = 0, audio = 0
        for i in tracks.indices.reversed() where family(tracks[i].kind) == .video { video += 1; out[i] = "V\(video)" }
        for i in tracks.indices where family(tracks[i].kind) == .audio { audio += 1; out[i] = "A\(audio)" }
        return out
    }

    /// The tags of the `shown` tracks, counted over `all` of them (the shown ones plus folded group members).
    public static func tags(of shown: [TimelineTrackModel], among all: [TimelineTrackModel]) -> [String] {
        let byId = Dictionary(zip(all.map(\.id), tags(all)), uniquingKeysWith: { first, _ in first })
        return shown.map { byId[$0.id, default: ""] }
    }

    /// The targeted track of `family`: the user's pick while that track exists, else V1 / A1; nil when turned off.
    public func target(_ family: Family, in tracks: [TimelineTrackModel]) -> String? {
        if let id = chosen[family] {
            if id.isEmpty { return nil }
            if tracks.contains(where: { $0.id == id && Self.family($0.kind) == family }) { return id }
        }
        switch family {
        case .video: return tracks.last { Self.family($0.kind) == .video }?.id
        case .audio: return tracks.first { Self.family($0.kind) == .audio }?.id
        }
    }

    /// Every targeted track id (at most one per family).
    public func targeted(in tracks: [TimelineTrackModel]) -> Set<String> {
        Set(Family.allCases.compactMap { target($0, in: tracks) })
    }

    /// A click on a tag: targets that track (the family's previous target is released), or turns the family's
    /// target off when the track already was the target. Returns whether the track is targeted now.
    @discardableResult
    public mutating func toggle(_ trackId: String, in tracks: [TimelineTrackModel]) -> Bool {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return false }
        let family = Self.family(track.kind)
        let wasTarget = target(family, in: tracks) == trackId
        chosen[family] = wasTarget ? "" : trackId
        return !wasTarget
    }
}

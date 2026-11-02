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

/// One transition the browser offers: a kind with the direction or colour that picks the variant. Applying it to a
/// cut writes exactly this kind, direction and colour.
public struct TransitionEntry: Equatable, Hashable, Sendable {
    public var kind: NativeCutTransitionKind
    /// The way the new picture travels in, for wipe and push.
    public var direction: NativeTransitionDirection?
    /// The dip colour; nil for the other kinds.
    public var color: String?
    public var label: String
    public var group: String
    /// A stable id, saved in the favourites: `dissolve`, `dip:black`, `dip:white`, `wipe:left`, `push:up`, …
    public var id: String
}

/// The built-in transitions in browser order, grouped, with the search every browser shares.
public enum TransitionCatalog {
    public static let all: [TransitionEntry] = {
        var out = [TransitionEntry(kind: .dissolve, direction: nil, color: nil, label: "Dissolve", group: "Dissolve", id: "dissolve"),
                   TransitionEntry(kind: .dip, direction: nil, color: NativeCutTransition.defaultDipColor, label: "Dip to black", group: "Dissolve", id: "dip:black"),
                   TransitionEntry(kind: .dip, direction: nil, color: NativeCutTransition.whiteDipColor, label: "Dip to white", group: "Dissolve", id: "dip:white")]
        for (kind, name, group) in [(NativeCutTransitionKind.wipe, "Wipe", "Wipe"), (.push, "Push", "Push")] {
            for d in NativeTransitionDirection.allCases {
                out.append(TransitionEntry(kind: kind, direction: d, color: nil, label: "\(name) \(d.rawValue)", group: group, id: "\(kind.rawValue):\(d.rawValue)"))
            }
        }
        return out
    }()

    public static func entry(id: String) -> TransitionEntry? { all.first { $0.id == id } }

    /// The entries whose name or group contains every word of `query` (case and diacritics ignored); all of them for
    /// an empty query.
    public static func entries(matching query: String) -> [TransitionEntry] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !words.isEmpty else { return all }
        return all.filter { e in
            let hay = fold("\(e.label) \(e.group)")
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// `ids` (saved favourites) as entries in the order saved; an id this version does not know is skipped, and
    /// repeats count once.
    public static func favourites(_ ids: [String]) -> [TransitionEntry] {
        var seen = Set<String>()
        return ids.compactMap { id in seen.insert(id).inserted ? entry(id: id) : nil }
    }
}

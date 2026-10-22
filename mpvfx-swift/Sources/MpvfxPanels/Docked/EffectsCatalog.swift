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

/// One effect the Effects panel offers: a video effect from `EffectSpecs` or an audio effect from the audio graph.
public struct EffectEntry: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case video, audio }
    /// The effect's own key: `EffectSpecs` key, `job:<id>` (an audio job) or `add:<id>` (an audio effect).
    public var key: String
    public var kind: Kind
    public var label: String
    public var group: String
    public var id: String { "\(kind.rawValue):\(key)" }
}

public enum EffectsCatalog {
    static let audioGroups: [(id: String, label: String)] = [
        ("filter", "Audio · Filters"), ("dynamics", "Audio · Dynamics"), ("nonlinear", "Audio · Non-linear"), ("time", "Audio · Time"),
    ]

    /// Every video effect, then every audio effect, in the order the inspector offers them.
    public static let all: [EffectEntry] = {
        var out: [EffectEntry] = []
        for family in EffectSpecs.families {
            for spec in family.effects { out.append(EffectEntry(key: spec.key, kind: .video, label: spec.label, group: family.label)) }
        }
        for g in audioGroups {
            for job in AudioFxJobs.all where AudioFx.definition(job.type)?.group == g.id {
                out.append(EffectEntry(key: "job:\(job.id)", kind: .audio, label: job.label, group: g.label))
            }
            for d in AudioFx.definitions where d.group == g.id && !AudioFxJobs.types.contains(d.id) {
                out.append(EffectEntry(key: "add:\(d.id)", kind: .audio, label: AudioFxCopy.title(d.id), group: g.label))
            }
        }
        return out
    }()

    /// The entries whose name, group or kind contains every word of `query` (case and diacritics ignored); all of
    /// them for an empty query.
    public static func entries(matching query: String) -> [EffectEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        guard !words.isEmpty else { return all }
        return all.filter { e in
            let hay = "\(e.label) \(e.group) \(e.kind.rawValue)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { hay.contains($0) }
        }
    }

    public static func entry(id: String) -> EffectEntry? { all.first { $0.id == id } }
}

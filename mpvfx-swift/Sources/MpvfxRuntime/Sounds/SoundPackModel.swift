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
// The sound pack format (`<name>.mpvfxsounds/`: pack.json, audio/, LICENCE.txt) as the app reads it. A pack is a
// folder the user chose or the app ships; the reader turns it into a report: the items that passed every check, and one
// typed issue per problem found, each naming the pack and (when it concerns one) the item.
import Foundation

/// What a sound is for.
public enum SoundKind: String, CaseIterable, Sendable { case music, effect, ambience }

/// The fixed mood list of the format. A pack may carry other mood words; the reader keeps them as tags.
public enum SoundMood: String, CaseIterable, Sendable { case calm, bright, driving, dark, playful, tense, warm }

/// Length bands of the library filter: under 10 s, 10 to 60 s, 1 to 3 min (both ends included), over 3 min.
public enum SoundLengthBand: CaseIterable, Sendable {
    case under10s, from10sTo1min, from1minTo3min, over3min

    public init(durationMs: Int) {
        switch durationMs {
        case ..<10_000: self = .under10s
        case ..<60_000: self = .from10sTo1min
        case ...180_000: self = .from1minTo3min
        default: self = .over3min
        }
    }
}

/// The licence a pack ships with; `file` is the text inside the pack.
public struct SoundLicence: Equatable, Sendable {
    public var id: String, title: String, file: String, summary: String
}

/// One sound that passed every check.
public struct SoundItem: Equatable, Sendable {
    public var id: String, title: String
    public var kind: SoundKind
    public var moods: [SoundMood]
    /// Declared tags, then mood words outside the fixed list.
    public var tags: [String]
    /// The `file` entry as written, relative to the pack folder.
    public var file: String
    /// Absolute path of the file (resolved inside the pack folder).
    public var path: String
    public var sha256: String
    public var durationMs: Int, sampleRate: Int, channels: Int
    public var bpm: Double?
    public var loopable: Bool
}

public struct SoundPackIssue: Equatable, Sendable, Error, CustomStringConvertible {
    public enum Code: Equatable, Sendable {
        case unreadablePackFile, malformedPackFile, newerVersion, missingField, invalidValue, duplicateId
        case fileOutsidePack, fileMissing, hashMismatch, durationMismatch, formatRefused, licenceMissing
        case duplicatePack
    }
    public var packId: String
    public var itemId: String?
    public var code: Code
    public var message: String
    public var description: String { itemId.map { "\(packId)/\($0): \(message)" } ?? "\(packId): \(message)" }
}

public enum SoundPackState: Equatable, Sendable {
    /// Read; items that failed a check are missing from `items`, the pack itself is usable.
    case ready
    /// `pack.json` has `v` above what this app reads: listed, items hidden, files untouched.
    case newerVersion(Int)
    /// `pack.json` is missing, malformed or lacks what a pack needs: listed with its issues, items hidden.
    case invalid
}

public struct SoundPackReport: Equatable, Sendable {
    public var folder: String
    public var id: String
    public var name: String
    public var version: String
    public var licence: SoundLicence?
    public var state: SoundPackState
    public var items: [SoundItem]
    public var issues: [SoundPackIssue]
}

/// How much of each item the reader checks. The catalogue indexes with `.deferred` (existence and size only) and
/// verifies an item's bytes the first time it is used; installing always checks `.full`.
public enum SoundContentChecks: Sendable { case full, deferred }

public let soundPackFormatVersion = 1
public let soundPackFolderExtension = "mpvfxsounds"

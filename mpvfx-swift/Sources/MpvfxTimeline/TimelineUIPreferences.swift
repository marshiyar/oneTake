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

/// The timeline slice of the UI preferences (stored under
/// `hf-studio-ui-preferences`): track height, zoom mode + manual percent, and the timeline magnet.
/// The JSON keys are fixed, so preferences saved by earlier versions read the same.
public struct TimelineUIPreferences: Codable, Equatable, Sendable {
    public var timelineTrackHeight: Double?
    public var timelineZoomMode: TimelineZoomMode?
    public var timelineManualZoomPercent: Double?
    public var timelineSnapEnabled: Bool?
    /// "adaptive" draws filmstrips, "hidden" does not (the clip menu's "Show thumbnails").
    public var thumbnailMode: String?
    public init(timelineTrackHeight: Double? = nil, timelineZoomMode: TimelineZoomMode? = nil,
                timelineManualZoomPercent: Double? = nil, timelineSnapEnabled: Bool? = nil, thumbnailMode: String? = nil) {
        self.thumbnailMode = thumbnailMode
        self.timelineTrackHeight = timelineTrackHeight; self.timelineZoomMode = timelineZoomMode
        self.timelineManualZoomPercent = timelineManualZoomPercent; self.timelineSnapEnabled = timelineSnapEnabled
    }

    /// readStorage's validation: unknown or non-finite values are dropped; track height is clamped and rounded.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let h = try? c.decode(Double.self, forKey: .timelineTrackHeight), h.isFinite {
            timelineTrackHeight = max(32, min(96, h.rounded()))
        }
        timelineZoomMode = try? c.decode(TimelineZoomMode.self, forKey: .timelineZoomMode)
        if let p = try? c.decode(Double.self, forKey: .timelineManualZoomPercent), p.isFinite { timelineManualZoomPercent = p }
        timelineSnapEnabled = try? c.decode(Bool.self, forKey: .timelineSnapEnabled)
        if let m = try? c.decode(String.self, forKey: .thumbnailMode), m == "adaptive" || m == "hidden" { thumbnailMode = m }
        else if let legacy = try? c.decode(Bool.self, forKey: .thumbnailsEnabled) { thumbnailMode = legacy ? "adaptive" : "hidden" }
    }
    enum CodingKeys: String, CodingKey {
        case timelineTrackHeight, timelineZoomMode, timelineManualZoomPercent, timelineSnapEnabled, thumbnailMode, thumbnailsEnabled
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(timelineTrackHeight, forKey: .timelineTrackHeight)
        try c.encodeIfPresent(timelineZoomMode, forKey: .timelineZoomMode)
        try c.encodeIfPresent(timelineManualZoomPercent, forKey: .timelineManualZoomPercent)
        try c.encodeIfPresent(timelineSnapEnabled, forKey: .timelineSnapEnabled)
        try c.encodeIfPresent(thumbnailMode, forKey: .thumbnailMode)
    }
}

/// Where the preferences live. The file store keeps other keys in the same JSON object untouched
/// (writeStudioUiPreferences merges a patch over what is stored).
public protocol TimelineUIPreferencesStore: AnyObject {
    func load() -> TimelineUIPreferences
    func save(_ prefs: TimelineUIPreferences)
}

public final class FileTimelineUIPreferencesStore: TimelineUIPreferencesStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> TimelineUIPreferences {
        guard let data = try? Data(contentsOf: url) else { return TimelineUIPreferences() }
        return (try? JSONDecoder().decode(TimelineUIPreferences.self, from: data)) ?? TimelineUIPreferences()
    }

    public func save(_ prefs: TimelineUIPreferences) {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { object = o }
        if let v = prefs.timelineTrackHeight { object["timelineTrackHeight"] = v }
        if let v = prefs.timelineZoomMode { object["timelineZoomMode"] = v.rawValue }
        if let v = prefs.timelineManualZoomPercent { object["timelineManualZoomPercent"] = v }
        if let v = prefs.timelineSnapEnabled { object["timelineSnapEnabled"] = v }
        if let v = prefs.thumbnailMode { object["thumbnailMode"] = v }
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? out.write(to: url, options: .atomic)
    }
}

public final class MemoryTimelineUIPreferencesStore: TimelineUIPreferencesStore {
    public var prefs: TimelineUIPreferences
    public init(_ prefs: TimelineUIPreferences = TimelineUIPreferences()) { self.prefs = prefs }
    public func load() -> TimelineUIPreferences { prefs }
    public func save(_ prefs: TimelineUIPreferences) { self.prefs = prefs }
}

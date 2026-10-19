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

/// The preview's persisted UI preferences, the subset of the UI preferences that the preview pane
/// owns: snap, grid visibility and spacing, snap to grid, the preview zoom and pan, and the
/// transport's playback rate, mute and volume.
public struct PreviewPreferences: Equatable, Sendable {
    public var snapEnabled: Bool?
    public var gridVisible: Bool?
    public var gridSpacing: Int?
    public var snapToGrid: Bool?
    public var previewZoom: PreviewZoom?
    public var playbackRate: Double?
    public var audioMuted: Bool?
    public var audioVolume: Double?
    public init(snapEnabled: Bool? = nil, gridVisible: Bool? = nil, gridSpacing: Int? = nil, snapToGrid: Bool? = nil, previewZoom: PreviewZoom? = nil,
                playbackRate: Double? = nil, audioMuted: Bool? = nil, audioVolume: Double? = nil) {
        self.snapEnabled = snapEnabled; self.gridVisible = gridVisible; self.gridSpacing = gridSpacing
        self.snapToGrid = snapToGrid; self.previewZoom = previewZoom
        self.playbackRate = playbackRate; self.audioMuted = audioMuted; self.audioVolume = audioVolume
    }

    /// readStorage: only well-typed, finite values are taken; anything else is left unset.
    public init(json: [String: Any]) {
        if let v = json["snapEnabled"] as? Bool { snapEnabled = v }
        if let v = json["gridVisible"] as? Bool { gridVisible = v }
        if let v = Self.number(json["gridSpacing"]) { gridSpacing = Int(exactly: v) }
        if let v = json["snapToGrid"] as? Bool { snapToGrid = v }
        if let z = json["previewZoom"] as? [String: Any], let p = Self.number(z["zoomPercent"]), let x = Self.number(z["panX"]), let y = Self.number(z["panY"]) {
            previewZoom = PreviewZoom(percent: p, panX: x, panY: y)
        }
        if let v = Self.number(json["playbackRate"]) { playbackRate = v }
        if let v = json["audioMuted"] as? Bool { audioMuted = v }
        if let v = Self.number(json["audioVolume"]), v >= 0, v <= 1 { audioVolume = v }
    }

    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// The keys this struct sets, as JSON values (unset keys are not written, so other writers' keys survive).
    public var json: [String: Any] {
        var o: [String: Any] = [:]
        if let v = snapEnabled { o["snapEnabled"] = v }
        if let v = gridVisible { o["gridVisible"] = v }
        if let v = gridSpacing { o["gridSpacing"] = v }
        if let v = snapToGrid { o["snapToGrid"] = v }
        if let z = previewZoom { o["previewZoom"] = ["zoomPercent": z.percent, "panX": z.panX, "panY": z.panY] }
        if let v = playbackRate { o["playbackRate"] = v }
        if let v = audioMuted { o["audioMuted"] = v }
        if let v = audioVolume { o["audioVolume"] = v }
        return o
    }

    /// The grid spacing the toolbar accepts (2, 3 or 4), else thirds.
    public var resolvedGridSpacing: Int { [2, 3, 4].contains(gridSpacing ?? 0) ? gridSpacing! : 3 }

    /// loadInitialZoom: a stored zoom at Fit (or older below-Fit zooms clamped up to Fit) restores as Fit.
    public var initialZoom: PreviewZoom {
        guard let z = previewZoom else { return .fit }
        let p = PreviewZoom.clamp(z.percent)
        if p == 100 { return .fit }
        return PreviewZoom(percent: p, panX: z.panX, panY: z.panY)
    }
}

public protocol PreviewPreferencesStore: AnyObject {
    func load() -> PreviewPreferences
    /// Merges the set keys of `patch` into what is stored (writeStudioUiPreferences).
    func save(_ patch: PreviewPreferences)
}

public final class MemoryPreviewPreferencesStore: PreviewPreferencesStore {
    public var value: PreviewPreferences
    public init(_ value: PreviewPreferences = PreviewPreferences()) { self.value = value }
    public func load() -> PreviewPreferences { value }
    public func save(_ patch: PreviewPreferences) {
        if let v = patch.snapEnabled { value.snapEnabled = v }
        if let v = patch.gridVisible { value.gridVisible = v }
        if let v = patch.gridSpacing { value.gridSpacing = v }
        if let v = patch.snapToGrid { value.snapToGrid = v }
        if let v = patch.previewZoom { value.previewZoom = v }
        if let v = patch.playbackRate { value.playbackRate = v }
        if let v = patch.audioMuted { value.audioMuted = v }
        if let v = patch.audioVolume { value.audioVolume = v }
    }
}

/// `<userData>/ui-preferences.json`, one JSON object shared with any other UI preference writer: saving reads the
/// file, overwrites only this patch's keys and writes it back atomically. Unreadable or malformed files read as
/// empty (like safeLocalStorage).
public final class FilePreviewPreferencesStore: PreviewPreferencesStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static func at(userData: String) -> FilePreviewPreferencesStore {
        FilePreviewPreferencesStore(url: URL(fileURLWithPath: userData).appendingPathComponent("ui-preferences.json"))
    }

    func readObject() -> [String: Any] {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    public func load() -> PreviewPreferences { PreviewPreferences(json: readObject()) }
    public func save(_ patch: PreviewPreferences) {
        var o = readObject()
        for (k, v) in patch.json { o[k] = v }
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

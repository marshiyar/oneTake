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
// What the app keeps in
// `<userData>/preferences.json`: the export dialog's last render settings ("hf-studio-render-settings") and,
// per project, the renders the user removed from the Renders list ("hf-studio-hidden-renders:<projectId>",
// at most the 200 newest ids), the appearance ("mpvfx-appearance") and the Settings window's audio output device,
// preview cache size and default export folder. Unreadable or malformed files fall back to nothing stored;
// values are opaque JSON that the reading feature validates. Every change rewrites the whole file through
// `NativeDurableWrite` (temp file, fsync, rename, folder fsync), the same path a project save takes, so a crash
// mid-write leaves the previous file, never a torn one.
import Foundation

public final class DesktopPreferences: @unchecked Sendable {
    public static let renderSettingsKey = "hf-studio-render-settings"
    public static func hiddenRendersKey(_ projectId: String) -> String { "hf-studio-hidden-renders:\(projectId)" }
    public static let hiddenRendersLimit = 200

    public let path: String
    private let lock = NSLock()
    /// Held for a whole `set` (change and write), so two writers cannot land their snapshots out of order.
    private let writeLock = NSLock()
    private var values: JSONObject
    private var writeError: DurableWriteError?

    public init(userData: String) {
        path = (userData as NSString).appendingPathComponent("preferences.json")
        if let data = FileManager.default.contents(atPath: path),
           let parsed = try? JSONValue.parse(String(decoding: data, as: UTF8.self)), case .object(let o) = parsed {
            values = o
        } else {
            values = [:]
        }
    }

    public func value(_ key: String) -> JSONValue? { lock.withLock { values[key] } }

    /// Why the last write failed (nil after a write that succeeded). The value stays in memory for this run either way;
    /// the Settings window shows this so a setting that will not survive a relaunch is never silent.
    public var lastWriteError: DurableWriteError? { lock.withLock { writeError } }

    /// Stores (or with nil removes) a value and writes the file durably.
    public func set(_ key: String, _ value: JSONValue?) {
        writeLock.withLock {
            let snapshot: JSONObject = lock.withLock {
                values[key] = value
                return values
            }
            let failure = write(Data(JSONValue.object(snapshot).serialized().utf8))
            lock.withLock { writeError = failure }
        }
    }

    private func write(_ data: Data) -> DurableWriteError? {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try NativeDurableWrite().write(data, to: path, tempName: ".preferences.json.\(UUID().uuidString.lowercased()).tmp",
                                           preserveMode: true, beforeRename: {})
            return nil
        } catch let e as DurableWriteError {
            return e
        } catch {
            return DurableWriteError(step: "create folder", path: dir, code: Int32((error as NSError).code))
        }
    }

    // MARK: Settings window (appearance is `ThemeAppearance.preferenceKey`, read by AppearanceSettings)

    public static let audioOutputDeviceKey = "mpvfx-audio-output-device"
    public static let previewCacheKey = "mpvfx-preview-cache-mb"
    public static let exportFolderKey = "mpvfx-default-export-folder"
    /// The preview frame cache sizes the Settings window accepts, in MB (a stored value outside it reads as automatic).
    public static let previewCacheRangeMB = 128...65_536

    /// The audio output device's id (a PulseAudio sink name, a Core Audio device UID, a Windows endpoint id); nil plays
    /// through the system default.
    public var audioOutputDevice: String? {
        get { value(Self.audioOutputDeviceKey)?.string.flatMap { $0.isEmpty ? nil : $0 } }
        set { set(Self.audioOutputDeviceKey, newValue.flatMap { $0.isEmpty ? nil : .string($0) }) }
    }

    /// The preview's decoded frame cache size in MB; nil is automatic (`MemoryBudget.previewFrames`).
    public var previewCacheMB: Int? {
        get {
            guard let n = value(Self.previewCacheKey)?.number, n.isFinite, n == n.rounded(),
                  Self.previewCacheRangeMB.contains(Int(n)) else { return nil }
            return Int(n)
        }
        set { set(Self.previewCacheKey, newValue.flatMap { Self.previewCacheRangeMB.contains($0) ? .number(Double($0)) : nil }) }
    }

    /// Where exports of projects outside a library go (and are listed from); nil is `<userData>/renders`. Only an
    /// absolute path is kept.
    public var defaultExportFolder: String? {
        get { value(Self.exportFolderKey)?.string.flatMap(Self.absoluteFolder) }
        set { set(Self.exportFolderKey, newValue.flatMap(Self.absoluteFolder).map { .string($0) }) }
    }

    static func absoluteFolder(_ s: String) -> String? {
        #if os(Windows)
        // `C:\x` or `C:/x`, or a UNC path; `C:x` is relative to drive C's current folder, so it is not absolute.
        let u = Array(s.utf16)
        let drive = u.count >= 3 && u[1] == 0x3A && (u[2] == 0x5C || u[2] == 0x2F)
            && ((0x41...0x5A).contains(u[0]) || (0x61...0x7A).contains(u[0]))
        let absolute = drive || s.hasPrefix("\\\\")
        #else
        let absolute = s.hasPrefix("/")
        #endif
        return absolute ? s : nil
    }

    public var renderSettings: JSONValue? {
        get { value(Self.renderSettingsKey) }
        set { set(Self.renderSettingsKey, newValue) }
    }

    public func hiddenRenders(projectId: String) -> [String] {
        value(Self.hiddenRendersKey(projectId))?.array?.compactMap(\.string) ?? []
    }

    /// Keeps the newest `hiddenRendersLimit` ids (the end of the list).
    public func setHiddenRenders(projectId: String, _ ids: [String]) {
        var seen = Set<String>(), unique: [String] = []
        for id in ids where seen.insert(id).inserted { unique.append(id) }
        set(Self.hiddenRendersKey(projectId), .array(unique.suffix(Self.hiddenRendersLimit).map { .string($0) }))
    }
}

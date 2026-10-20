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
// at most the 200 newest ids). Unreadable or malformed files fall back to nothing stored;
// values are opaque JSON that the reading feature validates.
import Foundation

public final class DesktopPreferences: @unchecked Sendable {
    public static let renderSettingsKey = "hf-studio-render-settings"
    public static func hiddenRendersKey(_ projectId: String) -> String { "hf-studio-hidden-renders:\(projectId)" }
    public static let hiddenRendersLimit = 200

    public let path: String
    private let lock = NSLock()
    private var values: JSONObject

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

    /// Stores (or with nil removes) a value and writes the file. Write failures are ignored, as a full
    /// localStorage was.
    public func set(_ key: String, _ value: JSONValue?) {
        let snapshot: JSONObject = lock.withLock {
            values[key] = value
            return values
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data(JSONValue.object(snapshot).serialized().utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
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

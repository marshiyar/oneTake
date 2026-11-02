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
import MpvfxAudio
import MpvfxAudioGraph
import MpvfxPanels
import MpvfxRuntime
import MpvfxShared

/// The Loudness row's source measurements: the BS.1770 integrated loudness of each media file, measured once in the
/// background. Readings live in memory and in `<project>/.loudness-cache/v1.json`, keyed by source, size and
/// modification time, so a replaced file is measured again. Never part of the document.
final class ClipLoudnessFeed {
    /// BS.1770's K-weighting is defined at 48 kHz.
    static let sampleRate = 48_000
    static let cacheFolder = ".loudness-cache"
    static let cacheVersion = 1

    private let projectDir: () -> String
    private let postToUI: (@escaping () -> Void) -> Void
    private let redraw: () -> Void
    /// Bumped by `reset`, so a measurement that ends after a project change is dropped.
    private var generation = 0
    /// Per source path: the stamp it was read with and its reading.
    private var readings: [String: (stamp: String, reading: ClipLoudnessReading)] = [:]
    private var inflight: Set<String> = []
    /// The project's saved readings by stamp, read once when first needed.
    private var saved: [String: ClipLoudnessReading]?

    init(projectDir: @escaping () -> String, postToUI: @escaping (@escaping () -> Void) -> Void, redraw: @escaping () -> Void) {
        self.projectDir = projectDir; self.postToUI = postToUI; self.redraw = redraw
    }

    /// The project changed: its folder, its cache and its relative paths all change, so readings start over.
    func reset() {
        generation += 1
        readings = [:]; inflight = []; saved = nil
    }

    /// The reading for a clip's source (project-relative or absolute). A source not seen yet starts its measurement
    /// in the background and reads `.measuring` until the feed calls `redraw`.
    func reading(for source: String) -> ClipLoudnessReading {
        let dir = projectDir()
        guard !source.isEmpty, !dir.isEmpty || PosixPath.isAbsolute(source) else { return .unavailable }
        let path = PosixPath.isAbsolute(source) ? PosixPath.normalize(source) : PosixPath.resolve(dir, source)
        // A missing file has no stamp: nothing to show or to cache until it is back.
        guard let stamp = Self.stamp(source: source, path: path) else { return .unavailable }
        if let known = readings[source], known.stamp == stamp { return known.reading }
        if let found = savedReadings(dir)[stamp] {
            readings[source] = (stamp, found)
            return found
        }
        guard inflight.insert(source).inserted else { return .measuring }
        readings[source] = (stamp, .measuring)
        let gen = generation
        let post = postToUI
        DispatchQueue.global(qos: .userInitiated).async {
            let reading = Self.measure(dir, source)
            post { [weak self] in
                guard let self, gen == self.generation else { return }
                self.finish(source, stamp: stamp, reading: reading, dir: dir)
                self.redraw()
            }
        }
        return .measuring
    }

    private func finish(_ source: String, stamp: String, reading: ClipLoudnessReading, dir: String) {
        inflight.remove(source)
        readings[source] = (stamp, reading)
        guard reading.isSaved else { return }
        var all = savedReadings(dir)
        all[stamp] = reading
        saved = all
        Self.write(all, dir)
    }

    private func savedReadings(_ dir: String) -> [String: ClipLoudnessReading] {
        if let saved { return saved }
        let loaded = Self.load(dir)
        saved = loaded
        return loaded
    }

    // MARK: Measurement and cache file (off the UI thread)

    /// `<source>|<size>|<mtime seconds>` for a regular file at `path`; nil when there is none.
    static func stamp(source: String, path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = attrs[.size] as? NSNumber, let date = attrs[.modificationDate] as? Date else { return nil }
        return "\(source)|\(size.int64Value)|\(Int(date.timeIntervalSince1970))"
    }

    /// Decodes the source at 48 kHz stereo and runs the BS.1770 gate.
    static func measure(_ dir: String, _ source: String) -> ClipLoudnessReading {
        do {
            let info = try readProjectClipInfo(dir, source)
            guard !info.offline, info.audioCodec != nil, let duration = info.duration, duration > 0 else { return .unavailable }
            let key = DocumentAudioGraph.StemKey(path: info.path, sourceIn: 0, duration: duration, rate: 1)
            let stem = try DocumentAudioGraph.decodeStem(key, sampleRate: sampleRate)
            guard stem.count == 2, !stem[0].isEmpty else { return .unavailable }
            let lufs = try LoudnessMeter.integrated(stem, sampleRate: Double(sampleRate))
            return lufs.isFinite ? .lufs(lufs) : .unavailable
        } catch let error as LoudnessError {
            switch error {
            case .silence: return .silent
            case .insufficientAudio: return .tooShort
            default: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    static func cacheFile(_ dir: String) -> URL {
        URL(fileURLWithPath: dir).appendingPathComponent(cacheFolder).appendingPathComponent("v\(cacheVersion).json")
    }

    /// The saved readings of a project. Any problem (no folder, bad JSON, another version) means none.
    static func load(_ dir: String) -> [String: ClipLoudnessReading] {
        guard !dir.isEmpty, let data = try? Data(contentsOf: cacheFile(dir)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["v"] as? Int) == cacheVersion, let entries = root["entries"] as? [String: Any] else { return [:] }
        var out: [String: ClipLoudnessReading] = [:]
        for (stamp, value) in entries {
            if let text = value as? String {
                if text == "silent" { out[stamp] = .silent } else if text == "short" { out[stamp] = .tooShort }
            } else if let number = value as? Double, number.isFinite {
                out[stamp] = .lufs(number)
            }
        }
        return out
    }

    /// Writes the saved readings (a few hundred bytes, once per new file). A failed write only means the next
    /// session measures again.
    static func write(_ entries: [String: ClipLoudnessReading], _ dir: String) {
        guard !dir.isEmpty else { return }
        var json: [String: Any] = [:]
        for (stamp, reading) in entries {
            switch reading {
            case .lufs(let value): json[stamp] = value
            case .silent: json[stamp] = "silent"
            case .tooShort: json[stamp] = "short"
            case .measuring, .unavailable: break
            }
        }
        let root: [String: Any] = ["v": cacheVersion, "entries": json]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return }
        let file = cacheFile(dir)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension ClipLoudnessReading {
    /// Whether this reading is worth keeping across sessions (a measured value, silence or a too short file).
    var isSaved: Bool {
        switch self {
        case .lufs, .silent, .tooShort: true
        case .measuring, .unavailable: false
        }
    }
}

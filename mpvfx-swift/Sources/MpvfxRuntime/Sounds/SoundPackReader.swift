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
// Reads and validates one sound pack folder. Every problem is a typed SoundPackIssue naming the pack and the item; one
// bad item hides that item only, never the pack. Nothing here writes: a pack made for a newer version is only listed.
import Foundation
import OneTakeMedia
import MpvfxShared

/// Remembers which files already passed the content checks (SHA-256 and probe), keyed by path, size and
/// modification time, so re-indexing unchanged packs costs a stat per file.
public final class SoundVerificationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var verified: [String: String] = [:]
    public init() {}
    func key(_ path: String, _ info: FileInfo) -> String { "\(path)|\(info.size)|\(info.mtimeNs)" }
    func contains(_ key: String, sha256: String) -> Bool { lock.lock(); defer { lock.unlock() }; return verified[key] == sha256 }
    func insert(_ key: String, sha256: String) { lock.lock(); defer { lock.unlock() }; verified[key] = sha256 }
}

/// Why a `file` entry is refused: the issue code and the words for the user.
struct SoundFileRefusal: Error, Equatable {
    var code: SoundPackIssue.Code, message: String
    init(_ code: SoundPackIssue.Code, _ message: String) { self.code = code; self.message = message }
}

public enum SoundPackReader {
    /// `pack.json` above this size is refused as malformed (a hostile or wrong file).
    static let maxPackFileBytes: Int64 = 8 << 20
    static let durationToleranceMs = 50

    /// Reads and validates the pack at `folder`. Never throws: an unreadable pack is a report with state `.invalid`.
    public static func read(folder: String, checks: SoundContentChecks = .full, cache: SoundVerificationCache? = nil) -> SoundPackReport {
        var reader = PackReading(folder: folder, checks: checks, cache: cache)
        return reader.run()
    }

    /// Whether `id` is usable as a pack id and as the installed folder's name: 1 to 64 of letters, digits, `.`, `_`, `-`,
    /// not starting with a dot.
    public static func isValidPackId(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64, id.first != "." else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// The `file` entry resolved inside the pack folder, or the issue code and message that refuse it. Refuses an empty
    /// or absolute path, `..`, a backslash, a drive letter and a symbolic link that leaves the folder.
    static func resolve(_ relative: String, inside packReal: String) -> Result<String, SoundFileRefusal> {
        let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
        let bad = relative.isEmpty || relative.contains("\0") || relative.contains("\\") || relative.hasPrefix("/")
            || PosixPath.isAbsolute(relative) || segments.contains("..") || relative.dropFirst().hasPrefix(":")
        if bad { return .failure(SoundFileRefusal(.fileOutsidePack, "\"\(relative)\" is not a path inside the pack folder")) }
        let joined = PosixPath.normalize(PosixPath.join(packReal, relative))
        guard joined.hasPrefix(packReal + "/") else { return .failure(SoundFileRefusal(.fileOutsidePack, "\"\(relative)\" is not a path inside the pack folder")) }
        do {
            guard try ProjectFS.entry(joined) != nil else { return .failure(SoundFileRefusal(.fileMissing, "the file \"\(relative)\" is missing")) }
            let real = try ProjectFS.realpath(joined)
            guard real.hasPrefix(packReal + "/") else { return .failure(SoundFileRefusal(.fileOutsidePack, "\"\(relative)\" leads outside the pack folder")) }
            guard try ProjectFS.statInfo(real).isFile else { return .failure(SoundFileRefusal(.fileMissing, "\"\(relative)\" is not a file")) }
            return .success(real)
        } catch {
            return .failure(SoundFileRefusal(.fileMissing, "the file \"\(relative)\" can't be opened"))
        }
    }
}

/// One read of one folder: collects the pack's issues while it goes.
private struct PackReading {
    let folder: String
    let checks: SoundContentChecks
    let cache: SoundVerificationCache?
    var packId: String
    var issues: [SoundPackIssue] = []

    init(folder: String, checks: SoundContentChecks, cache: SoundVerificationCache?) {
        self.folder = folder; self.checks = checks; self.cache = cache
        let stem = PosixPath.basename(folder)
        packId = stem.hasSuffix("." + soundPackFolderExtension) ? String(stem.dropLast(soundPackFolderExtension.count + 1)) : stem
    }

    mutating func add(_ code: SoundPackIssue.Code, _ message: String, item: String? = nil) {
        issues.append(SoundPackIssue(packId: packId, itemId: item, code: code, message: message))
    }

    func report(_ state: SoundPackState, name: String = "", version: String = "", licence: SoundLicence? = nil,
                items: [SoundItem] = []) -> SoundPackReport {
        SoundPackReport(folder: folder, id: packId, name: name.isEmpty ? packId : name, version: version, licence: licence,
                        state: state, items: items, issues: issues)
    }

    mutating func run() -> SoundPackReport {
        guard let root = loadPackObject() else { return report(.invalid) }
        if let id = root["id"], case .string(let text) = id, SoundPackReader.isValidPackId(text) { packId = text }
        switch version(of: root) {
        case .none: return report(.invalid)
        case .some(let v) where v > soundPackFormatVersion:
            add(.newerVersion, "this pack was made for a newer version of MpVFX (format \(v)); its sounds are hidden until the app is updated")
            return report(.newerVersion(v), name: string(root["name"]) ?? "")
        default: break
        }
        return readCurrent(root)
    }

    private mutating func readCurrent(_ root: NativeJSONObject) -> SoundPackReport {
        let packReal: String
        do { packReal = try ProjectFS.realpath(folder) }
        catch { add(.unreadablePackFile, "the pack folder can't be opened"); return report(.invalid) }
        checkPackId(root["id"])
        let name = requiredString(root, "name"), version = requiredString(root, "version")
        let licence = readLicence(root["licence"], packReal: packReal)
        guard case .array(let rawItems)? = root["items"] else {
            add(root["items"] == nil ? .missingField : .invalidValue, "\"items\" must be a list")
            return report(.invalid, name: name ?? "", version: version ?? "", licence: licence)
        }
        if !issues.isEmpty || name == nil || version == nil || licence == nil {
            return report(.invalid, name: name ?? "", version: version ?? "", licence: licence)
        }
        let items = readItems(rawItems, packReal: packReal)
        return report(.ready, name: name ?? "", version: version ?? "", licence: licence, items: items)
    }
}

// MARK: pack.json fields

extension PackReading {
    private mutating func checkPackId(_ value: NativeJSONValue?) {
        guard let value else { add(.missingField, "\"id\" is missing"); return }
        if case .string(let text) = value, SoundPackReader.isValidPackId(text) { return }
        add(.invalidValue, "\"id\" must be 1 to 64 letters, digits, dots, dashes or underscores")
    }

    /// The parsed `pack.json` object, or nil with the issue recorded.
    fileprivate mutating func loadPackObject() -> NativeJSONObject? {
        let path = PosixPath.join(folder, "pack.json")
        let data: Data
        do {
            let info = try ProjectFS.statInfo(path)
            guard info.isFile else { add(.unreadablePackFile, "pack.json is not a file"); return nil }
            guard info.size <= SoundPackReader.maxPackFileBytes else {
                add(.unreadablePackFile, "pack.json is larger than \(SoundPackReader.maxPackFileBytes >> 20) MB"); return nil
            }
            data = try ProjectFS.readData(path)
        } catch {
            add(.unreadablePackFile, isMissing(error) ? "pack.json is missing" : "pack.json can't be read"); return nil
        }
        do {
            guard case .object(let object) = try JSONDecoder().decode(NativeJSONValue.self, from: data) else {
                add(.malformedPackFile, "pack.json is not a JSON object"); return nil
            }
            return object
        } catch {
            add(.malformedPackFile, "pack.json is not valid JSON"); return nil
        }
    }

    /// The format version, or nil with the issue recorded when `v` is missing or not a whole number from 1.
    fileprivate mutating func version(of root: NativeJSONObject) -> Int? {
        guard let raw = root["v"] else { add(.missingField, "\"v\" is missing"); return nil }
        guard case .number(let number) = raw, jsIsInteger(number), number >= 1, number < 1_000_000 else {
            add(.invalidValue, "\"v\" must be a whole number from 1"); return nil
        }
        return Int(number)
    }

    fileprivate func string(_ value: NativeJSONValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }
        return nil
    }

    fileprivate mutating func requiredString(_ object: NativeJSONObject, _ key: String, item: String? = nil, label: String? = nil) -> String? {
        let shown = label ?? key
        guard let raw = object[key] else { add(.missingField, "\"\(shown)\" is missing", item: item); return nil }
        guard let text = string(raw), !text.contains("\0") else { add(.invalidValue, "\"\(shown)\" must be a non-empty text", item: item); return nil }
        return text
    }

    fileprivate mutating func requiredInt(_ object: NativeJSONObject, _ key: String, item: String, in range: ClosedRange<Int>) -> Int? {
        guard let raw = object[key] else { add(.missingField, "\"\(key)\" is missing", item: item); return nil }
        guard case .number(let number) = raw, jsIsInteger(number), number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
            add(.invalidValue, "\"\(key)\" must be a whole number from \(range.lowerBound) to \(range.upperBound)", item: item); return nil
        }
        return Int(number)
    }

    fileprivate mutating func stringList(_ object: NativeJSONObject, _ key: String, item: String) -> [String] {
        guard let raw = object[key] else { return [] }
        guard case .array(let entries) = raw else { add(.invalidValue, "\"\(key)\" must be a list of texts", item: item); return [] }
        var out: [String] = []
        for entry in entries {
            if case .string(let text) = entry { out.append(text) }
            else { add(.invalidValue, "\"\(key)\" must be a list of texts", item: item); return [] }
        }
        return out
    }

    fileprivate mutating func readLicence(_ raw: NativeJSONValue?, packReal: String) -> SoundLicence? {
        guard let raw else { add(.licenceMissing, "the pack has no \"licence\""); return nil }
        guard case .object(let object) = raw else { add(.invalidValue, "\"licence\" must be an object"); return nil }
        let before = issues.count
        let id = requiredString(object, "id", label: "licence.id"), title = requiredString(object, "title", label: "licence.title")
        let file = requiredString(object, "file", label: "licence.file"), summary = requiredString(object, "summary", label: "licence.summary")
        guard issues.count == before, let id, let title, let file, let summary else { return nil }
        if case .failure(let failure) = SoundPackReader.resolve(file, inside: packReal) {
            add(.licenceMissing, "the licence text: \(failure.message)"); return nil
        }
        return SoundLicence(id: id, title: title, file: file, summary: summary)
    }
}

// MARK: items

extension PackReading {
    fileprivate mutating func readItems(_ raw: [NativeJSONValue], packReal: String) -> [SoundItem] {
        var seen = Set<String>()
        var items: [SoundItem] = []
        for (index, entry) in raw.enumerated() {
            if let item = readItem(entry, number: index + 1, packReal: packReal, seen: &seen) { items.append(item) }
        }
        return items
    }

    private mutating func readItem(_ raw: NativeJSONValue, number: Int, packReal: String, seen: inout Set<String>) -> SoundItem? {
        guard case .object(let object) = raw else { add(.invalidValue, "item \(number) is not an object"); return nil }
        guard let id = requiredString(object, "id", label: "items[\(number)].id") else { return nil }
        guard seen.insert(id).inserted else { add(.duplicateId, "the id is used by an earlier item; this one is hidden", item: id); return nil }
        let before = issues.count
        let fields = readItemFields(object, id: id)
        guard issues.count == before, let fields else { return nil }
        guard let path = resolveItemFile(fields.file, id: id, packReal: packReal), checkContent(path, fields) else { return nil }
        return SoundItem(id: id, title: fields.title, kind: fields.kind, moods: fields.moods, tags: fields.tags, file: fields.file,
                         path: path, sha256: fields.sha256, durationMs: fields.durationMs, sampleRate: fields.sampleRate,
                         channels: fields.channels, bpm: fields.bpm, loopable: fields.loopable)
    }

    fileprivate struct ItemFields {
        var id: String, title: String, kind: SoundKind, moods: [SoundMood], tags: [String], file: String, sha256: String
        var durationMs: Int, sampleRate: Int, channels: Int, bpm: Double?, loopable: Bool
    }

    private mutating func readItemFields(_ o: NativeJSONObject, id: String) -> ItemFields? {
        let title = requiredString(o, "title", item: id), file = requiredString(o, "file", item: id)
        let kind = readKind(o, id: id), sha = readSha(o, id: id)
        let duration = requiredInt(o, "durationMs", item: id, in: 1...86_400_000)
        let rate = requiredInt(o, "sampleRate", item: id, in: 1_000...384_000), channels = requiredInt(o, "channels", item: id, in: 1...8)
        let words = stringList(o, "moods", item: id), declaredTags = stringList(o, "tags", item: id)
        let bpm = readBpm(o, id: id), loopable = readLoopable(o, id: id)
        guard let title, let file, let kind, let sha, let duration, let rate, let channels else { return nil }
        let known = words.compactMap { SoundMood(rawValue: $0) }
        let unknown = words.filter { SoundMood(rawValue: $0) == nil }
        return ItemFields(id: id, title: title, kind: kind, moods: known, tags: declaredTags + unknown, file: file, sha256: sha,
                          durationMs: duration, sampleRate: rate, channels: channels, bpm: bpm, loopable: loopable)
    }

    private mutating func readKind(_ o: NativeJSONObject, id: String) -> SoundKind? {
        guard let text = requiredString(o, "kind", item: id) else { return nil }
        guard let kind = SoundKind(rawValue: text) else { add(.invalidValue, "\"kind\" must be music, effect or ambience", item: id); return nil }
        return kind
    }

    private mutating func readSha(_ o: NativeJSONObject, id: String) -> String? {
        guard let text = requiredString(o, "sha256", item: id) else { return nil }
        let lower = text.lowercased()
        guard lower.utf8.count == 64, lower.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            add(.invalidValue, "\"sha256\" must be 64 hexadecimal digits", item: id); return nil
        }
        return lower
    }

    private mutating func readBpm(_ o: NativeJSONObject, id: String) -> Double? {
        guard let raw = o["bpm"] else { return nil }
        guard case .number(let value) = raw, value.isFinite, value >= 20, value <= 400 else {
            add(.invalidValue, "\"bpm\" must be a number from 20 to 400", item: id); return nil
        }
        return value
    }

    private mutating func readLoopable(_ o: NativeJSONObject, id: String) -> Bool {
        guard let raw = o["loopable"] else { return false }
        guard case .bool(let flag) = raw else { add(.invalidValue, "\"loopable\" must be true or false", item: id); return false }
        return flag
    }

    private mutating func resolveItemFile(_ file: String, id: String, packReal: String) -> String? {
        switch SoundPackReader.resolve(file, inside: packReal) {
        case .success(let path): return path
        case .failure(let failure): add(failure.code, failure.message, item: id); return nil
        }
    }

    /// Hash, probe and import-table checks. `.deferred` stops after the file is known to exist and not be empty.
    fileprivate mutating func checkContent(_ path: String, _ item: ItemFields) -> Bool {
        let info: FileInfo
        do { info = try ProjectFS.statInfo(path) } catch { add(.fileMissing, "the file \"\(item.file)\" can't be read", item: item.id); return false }
        guard info.size > 0 else { add(.fileMissing, "the file \"\(item.file)\" is empty", item: item.id); return false }
        if let refusal = ImportFormats.refusal(forName: item.file) ?? (ImportFormats.kind(of: item.file) == .audio ? nil : "\(item.file) is not an audio file the app imports") {
            add(.formatRefused, refusal, item: item.id); return false
        }
        guard checks == .full else { return true }
        let key = cache?.key(path, info)
        if let key, cache?.contains(key, sha256: item.sha256) == true { return true }
        guard verifyHash(path, item), verifyProbe(path, item) else { return false }
        if let key { cache?.insert(key, sha256: item.sha256) }
        return true
    }

    private mutating func verifyHash(_ path: String, _ item: ItemFields) -> Bool {
        var hasher = SHA256Hasher()
        do {
            let file = try NativeFile.openRead(path)
            defer { file.close() }
            try file.forEachChunk(path: path) { hasher.update($0) }
        } catch { add(.fileMissing, "the file \"\(item.file)\" can't be read", item: item.id); return false }
        let actual = hasher.finalizeHex()
        if actual != item.sha256 { add(.hashMismatch, "\"\(item.file)\" does not match its sha256 (expected \(item.sha256.prefix(12))…, found \(actual.prefix(12))…)", item: item.id); return false }
        return true
    }

    private mutating func verifyProbe(_ path: String, _ item: ItemFields) -> Bool {
        let probe: MediaProbe
        do { probe = try MediaProbe.probe(path: path) }
        catch let error as MediaError { add(.formatRefused, error.message, item: item.id); return false }
        catch { add(.formatRefused, "the file can't be read as audio", item: item.id); return false }
        do { try ImportFormats.check(probe, as: .audio) }
        catch let error as MediaToolError { add(.formatRefused, error.message, item: item.id); return false }
        catch { add(.formatRefused, "the audio format is not supported", item: item.id); return false }
        guard let seconds = probe.duration, seconds.isFinite else { add(.formatRefused, "the length of \"\(item.file)\" can't be read", item: item.id); return false }
        let probed = Int((seconds * 1000).rounded())
        if abs(probed - item.durationMs) > SoundPackReader.durationToleranceMs {
            add(.durationMismatch, "declared length \(item.durationMs) ms differs from the file's \(probed) ms by more than \(SoundPackReader.durationToleranceMs) ms", item: item.id)
            return false
        }
        return true
    }
}

extension SoundPackReader {
    /// Runs the content checks (size, import table, SHA-256, probe, length) on an indexed item: the catalogue defers
    /// them to the first use of a sound. An empty result means the file is as the pack declared it.
    public static func verify(_ item: SoundItem, inPack packId: String, cache: SoundVerificationCache? = nil) -> [SoundPackIssue] {
        var reading = PackReading(folder: packId + "." + soundPackFolderExtension, checks: .full, cache: cache)
        reading.packId = packId
        let fields = PackReading.ItemFields(id: item.id, title: item.title, kind: item.kind, moods: item.moods, tags: item.tags,
                                            file: item.file, sha256: item.sha256, durationMs: item.durationMs,
                                            sampleRate: item.sampleRate, channels: item.channels, bpm: item.bpm, loopable: item.loopable)
        _ = reading.checkContent(item.path, fields)
        return reading.issues
    }
}

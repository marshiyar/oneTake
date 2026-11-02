// The person-matte cache: one file per (media file digest, source range, quality, analysis size) under
// `<project>/.studio/analysis/person-matte/<key>.matte`. It holds only mattes (8-bit, at most 512 px on the long edge,
// run-length coded), never picture data. A cache is rebuildable: a missing or corrupt file never stops a project
// opening, the clip draws without the matte and is reported once as needing analysis.
//
// File layout, little endian:
//   "MATT"                      4 bytes
//   header length               UInt32
//   header                      UTF-8 JSON `PersonMatteCacheHeader` (`"v": 1`)
//   frame sizes                 UInt32 x frame count (compressed bytes of each frame)
//   frames                      each frame: runs of (value: UInt8, length: LEB128 varint) covering width x height bytes
// The codec is run-length: a matte is mostly long runs of 0 and 255, so it needs no deflate and no engine call, and a
// frame decodes in one pass.
import Foundation

public struct PersonMatteCacheKey: Equatable, Hashable, Sendable {
    public var digest: String
    public var sourceStartMs: Int
    public var sourceDurationMs: Int
    public var quality: String
    public var width: Int
    public var height: Int
    public init(digest: String, sourceStartMs: Int, sourceDurationMs: Int, quality: String, width: Int, height: Int) {
        self.digest = digest; self.sourceStartMs = sourceStartMs; self.sourceDurationMs = sourceDurationMs
        self.quality = quality; self.width = width; self.height = height
    }
    /// The file name without its extension; it is also written into the header and checked on read.
    public var name: String { "\(digest)-\(sourceStartMs)-\(sourceDurationMs)-\(quality)-\(width)x\(height)" }
    public static let relativeDirectory = ".studio/analysis/person-matte"
    public func path(projectDir: String) -> String {
        (projectDir.hasSuffix("/") ? projectDir : projectDir + "/") + Self.relativeDirectory + "/" + name + ".matte"
    }
    /// Frames a complete matte for this range holds at `fps` analysed frames per source second.
    public func expectedFrameCount(fps: Double) -> Int { max(1, Int((Double(sourceDurationMs) / 1000 * fps - 1e-6).rounded(.up))) }
}

public struct PersonMatteCacheHeader: Codable, Equatable, Sendable {
    public var v: Int
    public var codec: String
    public var frames: Int
    public var width: Int
    public var height: Int
    public var fps: Double
    public var key: String
    public var digest: String
    public var sourceStartMs: Int
    public var sourceDurationMs: Int
    public var quality: String
    public init(v: Int, codec: String, frames: Int, width: Int, height: Int, fps: Double, key: String, digest: String,
                sourceStartMs: Int, sourceDurationMs: Int, quality: String) {
        self.v = v; self.codec = codec; self.frames = frames; self.width = width; self.height = height; self.fps = fps
        self.key = key; self.digest = digest; self.sourceStartMs = sourceStartMs; self.sourceDurationMs = sourceDurationMs
        self.quality = quality
    }
}

public struct PersonMatteCacheError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String { "The person matte cache \(path) is not usable: \(reason)" }
}

/// One analysed matte frame: 8-bit coverage, 255 keeps the picture.
public struct PersonMatteFrame: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var alpha: [UInt8]
    public init(width: Int, height: Int, alpha: [UInt8]) { self.width = width; self.height = height; self.alpha = alpha }
}

public enum PersonMatteCodec {
    static let magic: [UInt8] = Array("MATT".utf8)
    public static let codecName = "rle8"

    public static func rleEncode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let value = bytes[i]
            var j = i + 1
            while j < bytes.count, bytes[j] == value { j += 1 }
            out.append(value)
            var n = j - i
            while n >= 0x80 { out.append(UInt8(n & 0x7f) | 0x80); n >>= 7 }
            out.append(UInt8(n))
            i = j
        }
        return out
    }

    /// nil when the runs do not cover exactly `count` bytes.
    public static func rleDecode(_ data: Data, count: Int) -> [UInt8]? {
        var out = [UInt8](); out.reserveCapacity(count)
        var i = data.startIndex
        while i < data.endIndex {
            let value = data[i]; i += 1
            var n = 0, shift = 0
            while true {
                guard i < data.endIndex, shift < 28 else { return nil }
                let b = Int(data[i]); i += 1
                n |= (b & 0x7f) << shift
                if b & 0x80 == 0 { break }
                shift += 7
            }
            guard n > 0, out.count + n <= count else { return nil }
            out.append(contentsOf: repeatElement(value, count: n))
        }
        return out.count == count ? out : nil
    }

    private static func le32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8((n >> ($0 * 8)) & 0xff) } }

    /// The whole file for `frames` (each `header.width * header.height` bytes).
    public static func encode(header: PersonMatteCacheHeader, frames: [[UInt8]]) throws -> Data {
        try encode(header: header, packed: frames.map(rleEncode))
    }

    /// The whole file for frames already run-length coded.
    public static func encode(header: PersonMatteCacheHeader, packed: [[UInt8]]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(header)
        var out = Data(magic)
        out.append(contentsOf: le32(json.count)); out.append(json)
        for p in packed { out.append(contentsOf: le32(p.count)) }
        for p in packed { out.append(contentsOf: p) }
        return out
    }

    /// Where each frame's compressed bytes sit in the file.
    public struct Index {
        public let header: PersonMatteCacheHeader
        public let ranges: [Range<Int>]
    }

    public static func index(of data: Data, path: String, expectedKey: PersonMatteCacheKey?) throws -> Index {
        func bad(_ why: String) -> PersonMatteCacheError { PersonMatteCacheError(path: path, reason: why) }
        func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[data.startIndex + at + $1]) << ($1 * 8) } }
        guard data.count >= 8, Array(data.prefix(4)) == magic else { throw bad("not a matte file") }
        let headerLength = u32(4)
        guard headerLength > 0, 8 + headerLength <= data.count else { throw bad("truncated header") }
        let header: PersonMatteCacheHeader
        do {
            header = try JSONDecoder().decode(PersonMatteCacheHeader.self,
                                              from: data.subdata(in: (data.startIndex + 8)..<(data.startIndex + 8 + headerLength)))
        } catch { throw bad("unreadable header") }
        guard header.v == 1 else { throw bad("unknown version \(header.v)") }
        guard header.codec == codecName else { throw bad("unknown codec \(header.codec)") }
        guard header.frames > 0, header.width > 0, header.height > 0, header.fps.isFinite, header.fps > 0,
              header.width <= PersonMatteEffect.maxLongEdge, header.height <= PersonMatteEffect.maxLongEdge else { throw bad("bad header values") }
        if let key = expectedKey {
            guard header.key == key.name, header.digest == key.digest, header.sourceStartMs == key.sourceStartMs,
                  header.sourceDurationMs == key.sourceDurationMs, header.quality == key.quality,
                  header.width == key.width, header.height == key.height else { throw bad("the key does not match the file") }
        }
        let tableStart = 8 + headerLength
        guard tableStart + header.frames * 4 <= data.count else { throw bad("truncated frame table") }
        var cursor = tableStart + header.frames * 4
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(header.frames)
        for i in 0..<header.frames {
            let size = u32(tableStart + i * 4)
            guard cursor + size <= data.count else { throw bad("truncated at frame \(i)") }
            ranges.append(cursor..<(cursor + size)); cursor += size
        }
        guard cursor == data.count else { throw bad("trailing bytes") }
        return Index(header: header, ranges: ranges)
    }
}

/// Reads one matte file, decoding frames on demand and keeping at most `maxFrames` decoded.
public final class PersonMatteCacheReader: @unchecked Sendable {
    public static let maxFrames = 64
    public let header: PersonMatteCacheHeader
    private let data: Data
    private let ranges: [Range<Int>]
    private let path: String
    private let lock = NSLock()
    private var decoded: [Int: PersonMatteFrame] = [:]
    private var order: [Int] = []

    /// Throws `PersonMatteCacheError` for a file that is missing its parts, has another version or another key.
    public init(path: String, expectedKey: PersonMatteCacheKey?) throws {
        self.path = path
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) }
        catch { throw PersonMatteCacheError(path: path, reason: "unreadable") }
        let index = try PersonMatteCodec.index(of: data, path: path, expectedKey: expectedKey)
        self.data = data; header = index.header; ranges = index.ranges
    }

    public var frameCount: Int { header.frames }
    /// Frames currently decoded (at most `maxFrames`).
    public var decodedFrameCount: Int { lock.lock(); defer { lock.unlock() }; return decoded.count }

    /// The frame at `sourceSeconds`: the nearest analysed frame at or before it, never blended; nil outside the range.
    public func frame(atSourceSeconds t: Double) -> PersonMatteFrame? {
        let local = t - Double(header.sourceStartMs) / 1000
        guard local >= -1e-6, local < Double(header.sourceDurationMs) / 1000 + 1e-6 else { return nil }
        return frame(index: min(header.frames - 1, max(0, Int((local * header.fps + 1e-6).rounded(.down)))))
    }

    /// Frame `index`; nil when it fails to decode (the file is corrupt).
    public func frame(index: Int) -> PersonMatteFrame? {
        guard ranges.indices.contains(index) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let f = decoded[index] {
            if let at = order.firstIndex(of: index) { order.remove(at: at); order.append(index) }
            return f
        }
        let r = ranges[index]
        guard let alpha = PersonMatteCodec.rleDecode(data.subdata(in: (data.startIndex + r.lowerBound)..<(data.startIndex + r.upperBound)),
                                                     count: header.width * header.height) else { return nil }
        let frame = PersonMatteFrame(width: header.width, height: header.height, alpha: alpha)
        decoded[index] = frame; order.append(index)
        while order.count > Self.maxFrames { decoded[order.removeFirst()] = nil }
        return frame
    }

    /// Whether every frame decodes (a full check for the export pre-flight).
    public func verifiesEveryFrame() -> Bool {
        for i in 0..<header.frames {
            let r = ranges[i]
            if PersonMatteCodec.rleDecode(data.subdata(in: (data.startIndex + r.lowerBound)..<(data.startIndex + r.upperBound)),
                                          count: header.width * header.height) == nil { return false }
        }
        return true
    }
}

/// The readers of one composition, opened once per file. A file that cannot be read is reported once through
/// `onProblem` and the clip is drawn without its matte.
public final class PersonMatteCacheStore: @unchecked Sendable {
    public enum Outcome { case reader(PersonMatteCacheReader), missing, corrupt(PersonMatteCacheError) }
    private let lock = NSLock()
    private var outcomes: [String: Outcome] = [:]
    private var reported: [PersonMatteCacheError] = []
    private let onProblem: (@Sendable (PersonMatteCacheError) -> Void)?

    public init(onProblem: (@Sendable (PersonMatteCacheError) -> Void)? = nil) { self.onProblem = onProblem }

    /// Every corruption reported so far, once per file.
    public var corruptionReports: [PersonMatteCacheError] { lock.lock(); defer { lock.unlock() }; return reported }

    public func outcome(for key: PersonMatteCacheKey, projectDir: String) -> Outcome {
        let path = key.path(projectDir: projectDir)
        lock.lock()
        if let known = outcomes[path] { lock.unlock(); return known }
        lock.unlock()
        let result: Outcome
        if !FileManager.default.fileExists(atPath: path) { result = .missing }
        else {
            do { result = .reader(try PersonMatteCacheReader(path: path, expectedKey: key)) }
            catch let e as PersonMatteCacheError { result = .corrupt(e) }
            catch { result = .corrupt(PersonMatteCacheError(path: path, reason: "\(error)")) }
        }
        lock.lock()
        if let known = outcomes[path] { lock.unlock(); return known }
        outcomes[path] = result
        if case .corrupt(let e) = result { reported.append(e) }
        lock.unlock()
        if case .corrupt(let e) = result { onProblem?(e) }
        return result
    }

    /// Reports a frame that failed to decode inside an otherwise readable file (once per file).
    public func reportUndecodable(path: String) {
        lock.lock()
        guard !reported.contains(where: { $0.path == path }) else { lock.unlock(); return }
        let e = PersonMatteCacheError(path: path, reason: "a frame does not decode")
        reported.append(e)
        lock.unlock()
        onProblem?(e)
    }
}

public extension MemoryBudget {
    /// The person-matte readers: 64 frames of 512 x 512 bytes at most, a slice of 0.2% of RAM clamped to 20...32 MB.
    static func personMatteFrames(physical: Int = physicalMemory) -> Int {
        bytes(fraction: 0.002, cap: 32 << 20, floor: 20 << 20, physical: physical)
    }
}

/// A cheap, stable identity of a media file: its size and a hash of its first, middle and last mebibyte. It changes
/// when the file is replaced or edited in place, and costs a few milliseconds for a file of any size.
public enum PersonMatteMediaDigest {
    public static func digest(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let chunk: UInt64 = 1 << 20
        var offsets: [UInt64] = [0]
        if size > chunk { offsets.append(size >= 2 * chunk ? (size - chunk) / 2 : 0); offsets.append(size - chunk) }
        var hash: UInt64 = 0xcbf29ce484222325
        for offset in Set(offsets).sorted() {
            guard (try? handle.seek(toOffset: offset)) != nil, let bytes = try? handle.read(upToCount: Int(chunk)) else { return nil }
            for b in bytes { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        }
        return String(size, radix: 16) + "-" + String(hash, radix: 16)
    }
}

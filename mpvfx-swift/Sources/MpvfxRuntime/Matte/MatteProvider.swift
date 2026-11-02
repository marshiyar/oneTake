// The person-matte provider interface: what analyses a clip's media into mattes and writes them to the cache. The
// macOS Vision provider is a separate slice; `StubMatteProvider` is the test double.
import Foundation
import MpvfxShared

public enum MatteUnavailableReason: Equatable, Sendable {
    case platformHasNoPersonSegmentation
    case osTooOld(required: String)

    public var message: String {
        switch self {
        case .platformHasNoPersonSegmentation:
            return "Person matte analysis needs macOS. Mattes already analysed on a Mac are still shown."
        case .osTooOld(let required):
            return "Person matte analysis needs \(required) or later. Mattes already analysed are still shown."
        }
    }
}

public enum MatteAvailability: Equatable, Sendable {
    case available
    case unavailable(MatteUnavailableReason)
}

public enum MatteError: Error, Equatable, Sendable, CustomStringConvertible {
    case unavailable(MatteUnavailableReason)
    case mediaUnreadable(assetName: String)
    case cancelled
    case cacheWriteFailed(path: String, underlying: String)
    case cacheCorrupt(path: String)
    case providerFailed(code: String, message: String)

    public var description: String {
        switch self {
        case .unavailable(let r): return r.message
        case .mediaUnreadable(let name): return "\(name) could not be read for person matte analysis."
        case .cancelled: return "Person matte analysis was cancelled."
        case .cacheWriteFailed(let path, let why): return "The person matte could not be saved to \(path): \(why)"
        case .cacheCorrupt(let path): return "The person matte cache \(path) is damaged and needs analysing again."
        case .providerFailed(_, let message): return message
        }
    }
}

/// One analysis: the media to read, the cache entry to produce and where its frames go.
public struct MatteAnalysisRequest: Sendable {
    public var mediaPath: String
    public var assetName: String
    public var key: PersonMatteCacheKey
    /// Analysed frames per source second.
    public var fps: Double
    /// Receives one frame after another, in order, then `finish()`.
    public var writer: MatteCacheWriter
    public init(mediaPath: String, assetName: String, key: PersonMatteCacheKey, fps: Double, writer: MatteCacheWriter) {
        self.mediaPath = mediaPath; self.assetName = assetName; self.key = key; self.fps = fps; self.writer = writer
    }
    public var frameCount: Int { key.expectedFrameCount(fps: fps) }
}

public protocol MatteProvider: Sendable {
    func availability() -> MatteAvailability
    /// Writes every frame of `request.key`'s range to `request.writer` and finishes it. `progress` takes 0...1;
    /// `cancel` is polled between frames and ends the analysis with `MatteError.cancelled`.
    func analyse(_ request: MatteAnalysisRequest, progress: @Sendable (Double) -> Void,
                 cancel: @Sendable () -> Bool) async throws
}

/// Writes one matte file: frames are coded as they arrive and the file is written once, through the durable write path
/// (temporary file, fsync, rename, directory fsync), so an interrupted write leaves the previous file intact.
public final class MatteCacheWriter: @unchecked Sendable {
    public let key: PersonMatteCacheKey
    public let path: String
    private let fps: Double
    private let durableWrite: DurableWrite
    private let lock = NSLock()
    private var packed: [[UInt8]] = []
    private var finished = false

    public init(key: PersonMatteCacheKey, fps: Double, projectDir: String, durableWrite: DurableWrite) {
        self.key = key; self.fps = fps; self.durableWrite = durableWrite; path = key.path(projectDir: projectDir)
    }

    public var frameCount: Int { lock.lock(); defer { lock.unlock() }; return packed.count }

    /// One frame of `key.width * key.height` bytes, 255 keeping the picture.
    public func append(_ alpha: [UInt8]) throws {
        guard alpha.count == key.width * key.height else {
            throw MatteError.providerFailed(code: "frame-size", message: "A matte frame must be \(key.width) x \(key.height) bytes.")
        }
        lock.lock(); defer { lock.unlock() }
        packed.append(PersonMatteCodec.rleEncode(alpha))
    }

    public func finish() throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        guard !packed.isEmpty else { throw MatteError.providerFailed(code: "no-frames", message: "The analysis produced no frames.") }
        let header = PersonMatteCacheHeader(v: 1, codec: PersonMatteCodec.codecName, frames: packed.count, width: key.width,
                                            height: key.height, fps: fps, key: key.name, digest: key.digest,
                                            sourceStartMs: key.sourceStartMs, sourceDurationMs: key.sourceDurationMs,
                                            quality: key.quality)
        do {
            let data = try PersonMatteCodec.encode(header: header, packed: packed)
            try ProjectFS.mkdirRecursive(PosixPath.dirname(path))
            try durableWrite.write(data, to: path, tempName: ".\(key.name).\(UUID().uuidString.prefix(8)).tmp", preserveMode: false,
                                   beforeRename: {})
            finished = true
        } catch {
            throw MatteError.cacheWriteFailed(path: path, underlying: "\(error)")
        }
    }
}

/// A test double: writes scripted mattes (by default a centred ellipse) for every frame.
public struct StubMatteProvider: MatteProvider {
    public typealias Script = @Sendable (_ frame: Int, _ width: Int, _ height: Int) -> [UInt8]
    public var stubAvailability: MatteAvailability
    public var script: Script
    /// Fails with this error after `failAfterFrames` frames, to test an analysis that stops part way.
    public var failure: (afterFrames: Int, error: MatteError)?

    public init(availability: MatteAvailability = .available, failure: (afterFrames: Int, error: MatteError)? = nil,
                script: @escaping Script = StubMatteProvider.centredEllipse()) {
        self.stubAvailability = availability; self.script = script; self.failure = failure
    }

    public func availability() -> MatteAvailability { stubAvailability }

    public func analyse(_ request: MatteAnalysisRequest, progress: @Sendable (Double) -> Void,
                        cancel: @Sendable () -> Bool) async throws {
        if case .unavailable(let reason) = stubAvailability { throw MatteError.unavailable(reason) }
        let count = request.frameCount
        for frame in 0..<count {
            if cancel() { throw MatteError.cancelled }
            if let failure, frame >= failure.afterFrames { throw failure.error }
            try request.writer.append(script(frame, request.key.width, request.key.height))
            progress(Double(frame + 1) / Double(count))
        }
        try request.writer.finish()
    }

    /// An ellipse centred in the frame, `radiusX` and `radiusY` as fractions of the width and height (hard edge).
    public static func centredEllipse(radiusX: Double = 0.35, radiusY: Double = 0.35) -> Script {
        { _, w, h in
            var out = [UInt8](repeating: 0, count: w * h)
            let cx = Double(w) / 2, cy = Double(h) / 2, rx = radiusX * Double(w), ry = radiusY * Double(h)
            for y in 0..<h { for x in 0..<w {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                if dx * dx + dy * dy <= 1 { out[y * w + x] = 255 }
            } }
            return out
        }
    }
}

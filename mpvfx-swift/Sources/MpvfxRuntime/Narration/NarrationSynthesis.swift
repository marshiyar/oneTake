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
// Speaking a narration into the project: check the request and the voice, let the service write a WAV into a private
// temporary folder, then publish it into the project through the media import (exclusive publish, never an
// overwrite, a collision gets the next free name) and remove the temporary folder whatever happened. The result is an
// ordinary audio file; the document edit that places it is `planNativeNarrationInsert` / `planNativeNarrationRespeak`.
import Foundation
import MpvfxShared

/// One narration to speak.
public struct NarrationJob {
    public var service: SpeechSynthesisService
    public var narration: NativeClipNarration
    public var progress: @Sendable (Double) -> Void
    public var cancel: SynthesisCancellation
    /// Where the private temporary folder is made (the system's temporary folder by default).
    public var temporaryRoot: URL
    public init(service: SpeechSynthesisService, narration: NativeClipNarration, progress: @escaping @Sendable (Double) -> Void = { _ in },
                cancel: SynthesisCancellation = SynthesisCancellation(),
                temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.service = service; self.narration = narration; self.progress = progress; self.cancel = cancel; self.temporaryRoot = temporaryRoot
    }
}

/// A spoken narration published into the project.
public struct NarrationMedia: Equatable, Sendable {
    /// Project-relative path of the WAV.
    public var path: String
    public var name: String
    public var samples48k: Int

    /// The audio a narration plan places, under the new asset id `assetId`.
    public func audio(assetId: String) -> NativeNarrationAudio {
        NativeNarrationAudio(assetId: assetId, source: path, name: name, samples48k: samples48k)
    }
}

/// Moves a finished temporary WAV into the project and returns its project-relative path.
public typealias NarrationPublish = (_ wavPath: String) async throws -> String

/// The folder inside the project that spoken narration is published to.
public let NARRATION_MEDIA_DIRECTORY = "Narration"

/// Publishes into `projectRoot/Narration` with `importLocalMedia` (the project media import).
public func narrationPublisher(projectRoot: String, durableWrite: DurableWrite) -> NarrationPublish {
    { wavPath in
        let result = try importLocalMedia(projectRoot: projectRoot, paths: [wavPath], directory: NARRATION_MEDIA_DIRECTORY,
                                          durableWrite: durableWrite)
        guard let file = result.files.first else {
            throw SynthesisError.writeFailed(path: PosixPath.join(projectRoot, NARRATION_MEDIA_DIRECTORY),
                                             underlying: result.invalid.first?.reason ?? "the audio was not imported")
        }
        return file
    }
}

/// Speaks `job.narration` and publishes the WAV with `publish`. Throws `SynthesisError` only.
public func speakNarration(_ job: NarrationJob, publish: NarrationPublish) async throws -> NarrationMedia {
    let request = SynthesisRequest(job.narration)
    try validateSynthesisRequest(request)
    if case .unavailable(let reason) = job.service.availability() { throw SynthesisError.unavailable(reason) }
    guard job.service.voices().contains(where: { $0.id == request.voiceId }) else {
        throw SynthesisError.unavailable(.voiceMissing(id: request.voiceId, name: job.narration.voiceName))
    }
    if job.cancel.isCancelled { throw SynthesisError.cancelled }
    let folder = job.temporaryRoot.appendingPathComponent("mpvfx-narration-\(UUID().uuidString.lowercased())", isDirectory: true)
    do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    catch { throw SynthesisError.writeFailed(path: folder.path, underlying: error.localizedDescription) }
    defer { removeNarrationTemporary(folder) }
    let wav = folder.appendingPathComponent("Narration.wav")
    let result = try await synthesizeTyped(job, request, wav)
    if job.cancel.isCancelled { throw SynthesisError.cancelled }
    let expectedBytes = 44 + result.durationFrames48k * 2
    let written = try narrationFileSize(wav)
    guard written == expectedBytes else {
        throw SynthesisError.writeFailed(path: wav.path, underlying: "the voice wrote \(written) bytes, expected \(expectedBytes)")
    }
    let path: String
    do { path = try await publish(wav.path) }
    catch let e as SynthesisError { throw e }
    catch { throw SynthesisError.writeFailed(path: wav.path, underlying: "\(error)") }
    return NarrationMedia(path: path, name: PosixPath.basename(path), samples48k: result.durationFrames48k)
}

/// The service's call with every error typed: a cancel is `.cancelled`, anything else not a `SynthesisError` is a
/// synthesizer failure.
private func synthesizeTyped(_ job: NarrationJob, _ request: SynthesisRequest, _ wav: URL) async throws -> SynthesisResult {
    do { return try await job.service.synthesize(request, to: wav, progress: job.progress, cancel: job.cancel) }
    catch let e as SynthesisError { throw e }
    catch is MediaAbortError { throw SynthesisError.cancelled }
    catch { throw SynthesisError.synthesizerFailed(code: -1, message: "\(error)") }
}

private func narrationFileSize(_ url: URL) throws -> Int {
    let attributes: [FileAttributeKey: Any]
    do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
    catch { throw SynthesisError.writeFailed(path: url.path, underlying: "the voice wrote no audio file") }
    guard let size = attributes[.size] as? NSNumber else {
        throw SynthesisError.writeFailed(path: url.path, underlying: "the audio file's size cannot be read")
    }
    return size.intValue
}

private func removeNarrationTemporary(_ folder: URL) {
    // A leftover folder in the system temporary directory loses nothing of the user's; the OS clears it.
    do { try FileManager.default.removeItem(at: folder) } catch {}
}

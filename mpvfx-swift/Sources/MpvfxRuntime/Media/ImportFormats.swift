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
// What import accepts: exactly the v1 rows of the media engine's format table, decided by the media engine's probe.
// Formats marked "later" or "blocked" there are refused with that table's message, by extension before anything
// is copied and by codec after the probe (the engine words the codec refusals: ProRes, VP9, AV1, MP3, ...). HEVC,
// AAC and MPEG audio Layers I/II decode; an .mp3 file goes to the probe, which refuses Layer III by its frames.
// Every video container of the table imports (MP4/MOV, Matroska/WebM, AVI, MPEG-TS/M2TS, MXF); what decides is
// the codec of the track inside, so a VP9 WebM is refused as "vp9 in webm", not as a WebM.
import Foundation
import OneTakeMedia
import MpvfxShared

public enum ImportFormats {
    /// v1 formats beyond the base import list (MediaImportPolicy): FLAC, MPEG audio Layer I/II files, Opus and `.oga`
    /// Ogg audio, BMP stills, CUR cursors and the video containers the engine demuxes besides MP4/MOV/WebM
    /// (formats.md "Container" rows). (`.ogg` is already on that list; Ogg files are decided by the probe: Vorbis and
    /// Opus import.)
    static let engineOnlyKinds: [String: MediaImportKind] = [
        "flac": .audio, "mp2": .audio, "mp1": .audio, "mpa": .audio, "opus": .audio, "oga": .audio, "bmp": .image,
        "cur": .image,
        "mkv": .video, "avi": .video, "ts": .video, "mts": .video, "m2ts": .video, "mxf": .video,
    ]
    /// formats.md "later" audio: extension to the codec the refusal names. None is left: .mp3 is decided by the probe
    /// (Layer II files named .mp3 import, Layer III is refused with "This audio format is not supported yet: mp3."),
    /// and Ogg Vorbis and Opus import.
    static let laterAudio: [String: String] = [:]
    static let laterImages: Set<String> = ["avif", "svg"]
    /// Image containers whose files may hold an animation; the probe reports those as video (not still), and they
    /// import as images (GIF, WebP: formats.md v1).
    static let animatedImageContainers: Set<String> = ["gif", "webp"]
    /// The `container` names the engine's probe reports for files with a video track.
    static let videoContainers: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "ts", "m2ts", "mxf"]

    /// Lowercase extension without the dot ("" when none).
    static func fileExtension(_ name: String) -> String { String(PosixPath.extname(name).lowercased().dropFirst()) }

    /// The import kind of a file name: the base list's kinds, plus FLAC, MPEG audio, Opus, `.oga`, BMP, CUR and the
    /// engine's other video containers.
    public static func kind(of name: String) -> MediaImportKind? {
        let ext = fileExtension(name)
        if let kind = engineOnlyKinds[ext] { return kind }
        guard case let .accepted(kind, _, _) = inspectMediaImportFile(MediaImportFile(name: name, type: "", size: 1)) else { return nil }
        return kind
    }

    /// The formats.md message for a file refused by its extension alone; nil when the probe decides.
    public static func refusal(forName name: String) -> String? {
        let ext = fileExtension(name)
        if let codec = laterAudio[ext] { return "This audio format is not supported yet: \(codec)." }
        if laterImages.contains(ext) { return "This image format is not supported yet: \(ext)." }
        return nil
    }

    /// Refuses a probed file that `kind` cannot import, with the engine's reason when it gave one.
    public static func check(_ probe: MediaProbe, as kind: MediaImportKind) throws {
        switch kind {
        case .video:
            guard videoContainers.contains(probe.container), let video = probe.video, !video.still else {
                throw MediaToolError("This file has no video track.")
            }
            guard video.decodable else {
                throw MediaToolError(video.reason ?? "This video format is not supported yet: \(video.codec) in \(probe.container).")
            }
        case .audio:
            guard let audio = probe.audio else { throw MediaToolError("This file has no audio track.") }
            guard audio.decodable else { throw MediaToolError(audio.reason ?? "This audio format is not supported yet: \(audio.codec).") }
        case .image:
            guard let video = probe.video, video.decodable, video.still || animatedImageContainers.contains(probe.container) else {
                throw MediaToolError("This image format is not supported yet: \(probe.container).")
            }
        case .font, .lut:
            return
        }
    }

    /// Probes `path` (named `name`) and refuses it unless it imports as `kind`.
    public static func validate(_ path: String, name: String, as kind: MediaImportKind) throws {
        if let message = refusal(forName: name) { throw MediaToolError(message) }
        guard kind == .video || kind == .audio || kind == .image else { return }
        let probe: MediaProbe
        do { probe = try MediaProbe.probe(path: path) } catch let e as MediaError { throw mediaToolError(e) }
        try check(probe, as: kind)
    }

    /// Why a video imports without sound (its audio track cannot be decoded); nil when it has none or it plays.
    public static func silentVideoNotice(_ probe: MediaProbe) -> String? {
        guard probe.video?.still == false, let audio = probe.audio, !audio.decodable else { return nil }
        return audio.reason ?? "This audio format is not supported yet: \(audio.codec)."
    }
}

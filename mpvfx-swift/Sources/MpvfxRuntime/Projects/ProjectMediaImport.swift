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
// Media import for the native editor: copy the picked files into the project (importLocalMedia, or the
// library's managed import for library projects), then read each file's stream facts with the media engine's
// probe so the editor can add it to the document with a real duration.
import Foundation
import MpvfxShared

public struct ImportedProjectMedia: Equatable {
    /// Project-relative path of the copy inside the project.
    public var path: String
    public var name: String
    public var kind: MediaImportKind
    /// Seconds; 0 for stills and fonts.
    public var duration: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Natural picture size (sample aspect, rotation and EXIF orientation applied), probed during the import so
    /// the asset is placeable at its fitted box from its first draw; nil without a picture or when unreadable.
    public var width: Double? = nil, height: Double? = nil
    /// Why an imported video has no sound (formats.md: a video whose sound the engine cannot decode imports without
    /// it); nil otherwise.
    public var notice: String? = nil
    public init(path: String, name: String, kind: MediaImportKind, duration: Double, hasVideo: Bool, hasAudio: Bool,
                width: Double? = nil, height: Double? = nil) {
        self.path = path; self.name = name; self.kind = kind; self.duration = duration; self.hasVideo = hasVideo; self.hasAudio = hasAudio
        self.width = width; self.height = height
    }
}

public struct ProjectMediaImportResult: Equatable {
    public var media: [ImportedProjectMedia] = []
    /// (file name, reason) for every file that was not imported.
    public var invalid: [LocalMediaImportResult.Invalid] = []
    public init(media: [ImportedProjectMedia] = [], invalid: [LocalMediaImportResult.Invalid] = []) { self.media = media; self.invalid = invalid }
}

/// Describes files already copied into `projectDir` (project-relative `files`). A file whose streams
/// cannot be read is reported invalid; it stays in the project folder.
public func describeImportedMedia(projectDir: String, files: [String]) -> ProjectMediaImportResult {
    var result = ProjectMediaImportResult()
    for file in files {
        let name = PosixPath.basename(file)
        guard let kind = ImportFormats.kind(of: name) else {
            result.invalid.append(.init(name: name, reason: "Unsupported media file")); continue
        }
        switch kind {
        case .video, .audio, .image:
            do { result.media.append(try describeProbedMedia(projectDir, file, kind)) }
            catch { result.invalid.append(.init(name: name, reason: importErrorMessage(error))) }
        default:
            result.media.append(.init(path: file, name: name, kind: kind, duration: 0, hasVideo: false, hasAudio: false))
        }
    }
    return result
}

/// One picture or sound file, checked against the import formats with the engine's probe.
private func describeProbedMedia(_ projectDir: String, _ file: String, _ kind: MediaImportKind) throws -> ImportedProjectMedia {
    let probe = try probeProjectMedia(projectDir, file).probe
    try ImportFormats.check(probe, as: kind)
    let meta = mediaMetadata(probe)
    let isAudio = kind == .audio
    var media = ImportedProjectMedia(path: file, name: PosixPath.basename(file), kind: kind, duration: kind == .image ? 0 : meta.duration,
                                     hasVideo: meta.hasVideo, hasAudio: meta.hasAudio,
                                     width: isAudio ? nil : meta.width, height: isAudio ? nil : meta.height)
    media.notice = ImportFormats.silentVideoNotice(probe)
    return media
}

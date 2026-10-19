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
// Media metadata: stream facts of a project media file, confined to the project. The
// facts come from the media engine's probe (MediaProbe).
import Foundation
import OneTakeMedia
import MpvfxShared

/// Confinement: realpath both sides, require a regular file strictly inside the project, and refuse a
/// file that changed (dev/ino/size/mtime/ctime) while it was probed. Returns the real path and the probe.
public func probeProjectMedia(_ projectDir: String, _ source: String, cancellation: MediaCancellation? = nil) throws -> (path: String, probe: MediaProbe) {
    try cancellation?.throwIfCancelled()
    guard !source.isEmpty, !source.contains("\0") else { throw MediaToolError("A project media path is required") }
    let root = try ProjectFS.realpath(projectDir)
    let path = try ProjectFS.realpath(PosixPath.resolve(root, source))
    let offset = PosixPath.relative(root, path)
    if offset.isEmpty || PosixPath.isAbsolute(offset) || offset == ".." || offset.hasPrefix("../") {
        throw MediaToolError("Media must be a file inside this project")
    }
    let before = try ProjectFS.statInfo(path)
    guard before.isFile else { throw MediaToolError("Media must be a regular file") }
    let probe: MediaProbe
    do { probe = try MediaProbe.probe(path: path) } catch let e as MediaError { throw mediaToolError(e) }
    let after = try ProjectFS.statInfo(path)
    if before.dev != after.dev || before.ino != after.ino || before.size != after.size ||
        before.mtimeNs != after.mtimeNs || before.ctimeNs != after.ctimeNs {
        throw MediaToolError("Media changed while reading its streams: \(source)")
    }
    try cancellation?.throwIfCancelled()
    return (path, probe)
}

/// Duration, picture and sound of a project media file. `hasAudio` is false when the audio track cannot be decoded
/// (a video whose sound uses a later codec plays without it); the natural size is the probe's display size (rotation,
/// pixel aspect and EXIF orientation applied).
public func readProjectMediaMetadata(_ projectDir: String, _ source: String, cancellation: MediaCancellation? = nil) throws -> MediaMetadata {
    mediaMetadata(try probeProjectMedia(projectDir, source, cancellation: cancellation).probe)
}

func mediaMetadata(_ probe: MediaProbe) -> MediaMetadata {
    let duration = probe.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
    let natural = probe.video.flatMap {
        NativeMediaNaturalSize.display(width: Double($0.displayWidth), height: Double($0.displayHeight))
    }
    return MediaMetadata(duration: duration, hasVideo: probe.video != nil, hasAudio: probe.audio?.decodable == true,
                         width: natural?.width, height: natural?.height)
}

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
import MpvfxShared
import OneTakeMedia

/// Saves one composited frame through the same prepared document and painter as video export.
/// The pinned media engine exposes JPEG encoding only; TODO(#293): PNG needs a still-image encoder in the pinned engine.
public enum SaveFrame {
    public static func jpeg(project: NativeProjectDocument, projectDir: String, time: Double, outputPath: String,
                            durableWrite: DurableWrite, keyframeEngine: KeyframeEngine? = nil,
                            renderer: NativeExportFrameRendererFactory? = nil) throws {
        guard time.isFinite, time >= 0 else { throw MediaToolError("Invalid frame time") }
        guard [".jpg", ".jpeg"].contains(PosixPath.extname(outputPath).lowercased()) else {
            throw MediaToolError("Save frame supports JPEG: choose a .jpg or .jpeg name.")
        }
        if try ProjectFS.entry(outputPath) != nil { throw ExportOutputExistsError(path: outputPath) }
        // Use export's media probing, visible-track filtering and natural-size resolution too: constructing a
        // painter directly from the stored document could otherwise size an untouched clip differently.
        var input = NativeTimelineRenderInput(project: project, projectDir: projectDir, outputPath: outputPath,
                                             format: .mov, keyframeEngine: keyframeEngine)
        let plan = try planNativeTimelineRender(&input)
        guard let makeRenderer = renderer ?? NativeExportFrames.defaultRenderer else {
            throw MediaToolError(EXPORT_NO_FRAME_RENDERER_MESSAGE)
        }
        var request = NativeExportFrameRequest(document: plan.project, projectDir: plan.root, width: plan.width, height: plan.height)
        request.keyframeEngine = input.keyframeEngine
        let pixels = try makeRenderer(request).frame(at: time)
        let data = try ImageCodec.encodeJPEG(rgba: pixels, width: plan.width, height: plan.height, quality: 95)
        let directory = PosixPath.dirname(outputPath)
        let staging = try makeTemporaryDirectory(PosixPath.join(directory, ".mpvfx-frame-"))
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let staged = PosixPath.join(staging, "frame.jpg")
        try durableWrite.write(data, to: staged, tempName: "frame.tmp", preserveMode: false, beforeRename: {})
        try publishExport(staged, to: outputPath)
        try ProjectFS.syncDirectory(directory, durableWrite)
    }
}

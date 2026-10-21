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
/// The pinned media engine exposes JPEG encoding only; PNG requires a still-image encoder in a future engine.
public enum SaveFrame {
    /// Quality chosen to preserve exported frame detail within the documented PSNR tolerance.
    private static let jpegQuality: Int = 95

    /// Render, encode and durably publish one frame without replacing an existing destination.
    public static func jpeg(
        project: NativeProjectDocument,
        projectDir: String,
        time: Double,
        outputPath: String,
        durableWrite: DurableWrite,
        keyframeEngine: KeyframeEngine? = nil,
        renderer: NativeExportFrameRendererFactory? = nil
    ) throws {
        guard time.isFinite, time >= 0 else { throw MediaToolError("Invalid frame time") }
        guard [".jpg", ".jpeg"].contains(PosixPath.extname(outputPath).lowercased()) else {
            throw MediaToolError("Save frame supports JPEG: choose a .jpg or .jpeg name.")
        }
        if try ProjectFS.entry(outputPath) != nil { throw ExportOutputExistsError(path: outputPath) }
        // Use export's media probing, visible-track filtering and natural-size resolution too: constructing a
        // painter directly from the stored document could otherwise size an untouched clip differently.
        var input: NativeTimelineRenderInput = NativeTimelineRenderInput(
            project: project,
            projectDir: projectDir,
            outputPath: outputPath,
            format: .mov,
            keyframeEngine: keyframeEngine
        )
        let plan: NativeTimelineRenderPlan = try planNativeTimelineRender(&input)
        guard let makeRenderer = renderer ?? NativeExportFrames.defaultRenderer else {
            throw MediaToolError(EXPORT_NO_FRAME_RENDERER_MESSAGE)
        }
        var request: NativeExportFrameRequest = NativeExportFrameRequest(
            document: plan.project,
            projectDir: plan.root,
            width: plan.width,
            height: plan.height
        )
        request.keyframeEngine = input.keyframeEngine
        let pixels: [UInt8] = try makeRenderer(request).frame(at: time)
        let data: Data = try ImageCodec.encodeJPEG(
            rgba: pixels,
            width: plan.width,
            height: plan.height,
            quality: jpegQuality
        )
        let directory: String = PosixPath.dirname(outputPath)
        let staging: String = try makeTemporaryDirectory(PosixPath.join(directory, ".mpvfx-frame-"))
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let staged: String = PosixPath.join(staging, "frame.jpg")
        try durableWrite.write(
            data,
            to: staged,
            tempName: "frame.tmp",
            preserveMode: false,
            beforeRename: { /* No caller-side action is needed before this private staged rename. */  }
        )
        try publishExport(staged, to: outputPath)
        try ProjectFS.syncDirectory(directory, durableWrite)
    }
}

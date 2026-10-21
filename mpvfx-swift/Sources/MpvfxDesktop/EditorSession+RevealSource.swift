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
import MpvfxPanels
import MpvfxDesktopCore

extension EditorSession {
    /// Navigation only: the document, undo history and playback position stay as they are.
    func revealClipSource(clipId: String, inFileManager: Bool) {
        do {
            let source = try clipSource(clipId: clipId)
            guard let panels else { throw DesktopError("Open the editor window and try again.", name: "SourceUnavailableError") }
            if inFileManager {
                guard let reveal = panels.revealPath else {
                    throw DesktopError("The file manager is unavailable. Open this folder manually: \((source.path as NSString).deletingLastPathComponent)", name: "SourceUnavailableError")
                }
                reveal(source.path)
            } else {
                panels.left.revealMedia(source.source)
                shell?.reveal(DockPanels.media)
            }
            redraw()
        } catch {
            onError("Could not reveal clip source", (error as? DesktopError)?.message ?? String(describing: error))
        }
    }

    func clipSource(clipId: String) throws -> (source: String, path: String) {
        guard let (_, clip) = editor.clip(clipId),
              let asset = editor.document.assets.first(where: { $0.id == clip.assetId }),
              let source = asset.source, !source.isEmpty else {
            throw DesktopError("This clip has no source file. Select a video, image or audio clip.", name: "SourceUnavailableError")
        }
        let path: String
        if HostPath.isAbsolute(source) { path = source }
        else if let projectDir { path = projectDir.appendingPathComponent(source).path }
        else {
            throw DesktopError("Open the clip's project folder and try again.", name: "SourceUnavailableError")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw DesktopError("The source file is missing: \(path). Reconnect its drive, restore the file, or relink the clip's media.", name: "SourceMissingError")
        }
        return (source, path)
    }
}

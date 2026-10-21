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
import MpvfxBackend
import MpvfxDesktopCore
import MpvfxRuntime
import MpvfxShared
import MpvfxTimeline

extension EditorSession {
    /// Filename-safe playhead timecode at the exact rational composition rate.
    internal static func saveFrameTimecode(_ time: Double, frameRate: RationalFrameRate) -> String {
        let framesPerSecond: Double = Double(frameRate.numerator) / Double(frameRate.denominator)
        return TimelineRuler.timecode(time, frameRate: framesPerSecond, hours: true)
            .replacingOccurrences(of: ":", with: "-")
    }

    /// Captures the document and playhead before opening the dialog; playback and selection cannot change the still.
    @discardableResult
    internal func requestSaveFrame() -> Bool {
        guard let projectDir, let dialogs = panels?.dialogs else {
            return false
        }
        let document: NativeProjectDocument = editor.document
        let time: Double = playback.currentTime
        let engine: KeyframeEngine? = engine
        let timecode: String = Self.saveFrameTimecode(time, frameRate: document.frameRate)
        let name: String = projectDir.lastPathComponent.components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
        Task.detached(priority: .userInitiated) {
            guard
                let path = await dialogs.showSave(
                    .init(
                        title: "Save frame",
                        defaultPath: "\(name) \(timecode).jpg",
                        buttonLabel: "Save",
                        filters: [.init(name: "JPEG image", extensions: ["jpg", "jpeg"])]
                    )
                )
            else {
                return
            }
            do {
                try SaveFrame.jpeg(
                    project: document,
                    projectDir: projectDir.path,
                    time: time,
                    outputPath: path,
                    durableWrite: NativeDurableWrite(),
                    keyframeEngine: engine
                )
            } catch {
                await dialogs.showError(title: "Could not save frame", message: "\(error)")
            }
        }
        return true
    }
}

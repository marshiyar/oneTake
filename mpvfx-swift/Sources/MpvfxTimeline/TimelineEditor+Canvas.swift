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

public extension TimelineEditor {
    /// Sets the composition size (document.canvas) as one undo step, "Set composition size": untouched media clips
    /// refit to the new frame and placed clips and text keep their size and offset from the centre
    /// (nativeDocumentResizingCanvas). The same size is no edit (true, nothing recorded); a size the document cannot
    /// take is refused with `lastFailure` set and nothing changed.
    @discardableResult
    func setCanvasSize(width: Double, height: Double) -> Bool {
        if width == document.canvas.width && height == document.canvas.height { lastFailure = nil; return true }
        let resized: NativeProjectDocument
        do { resized = try nativeDocumentResizingCanvas(document, width: width, height: height, natural: naturalSize, engine: engine) } catch {
            lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: (error as? NativeCanvasSizeError)?.message ?? "\(error)")
            return false
        }
        let before = document
        withHistory("Set composition size") { replaceDocument(resized, inverse: .restoreDocument(before)) }
        lastFailure = nil
        return true
    }
}

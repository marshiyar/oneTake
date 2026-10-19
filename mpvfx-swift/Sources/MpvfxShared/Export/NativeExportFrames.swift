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

/// What export asks for when it starts drawing frames: the document exactly as it renders (hidden tracks removed,
/// muted groups dropped, untouched clips at their natural box), the folder its media paths are relative to, and the
/// output picture. The project canvas is fitted into `width` × `height` and centred; the margin is opaque black, or
/// transparent when `transparentPad` (formats that keep alpha).
public struct NativeExportFrameRequest {
    public var document: NativeProjectDocument
    public var projectDir: String
    public var width: Int, height: Int
    public var transparentPad: Bool
    public var keyframeEngine: KeyframeEngine?
    public init(document: NativeProjectDocument, projectDir: String, width: Int, height: Int) {
        self.document = document; self.projectDir = projectDir; self.width = width; self.height = height
        transparentPad = false
    }
}

/// Paints export frames. Export asks for frames in increasing time order, so an implementation may decode forward.
public protocol NativeExportFrameRenderer: AnyObject {
    /// The output frame shown at timeline `time` (seconds) as straight-alpha RGBA8, width × height × 4 bytes.
    /// Throws when a layer cannot be decoded or drawn: export never leaves a clip out silently.
    func frame(at time: Double) throws -> [UInt8]
}

public typealias NativeExportFrameRendererFactory = (NativeExportFrameRequest) throws -> NativeExportFrameRenderer

/// The process-wide frame renderer export uses when the render input names none. The app installs the preview's
/// painter (MpvfxPlayer `PreviewExportFrames`) at startup, so an exported frame is the preview's frame.
public enum NativeExportFrames {
    nonisolated(unsafe) public static var defaultRenderer: NativeExportFrameRendererFactory?
}

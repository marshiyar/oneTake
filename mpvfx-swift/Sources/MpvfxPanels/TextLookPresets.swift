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
import MpvfxTimeline

/// Built-in text looks are recipes for ordinary text, layout and keyframe fields. They never add a renderer or
/// depend on a bundled font or image. A nil family uses the platform's installed default sans-serif.
public struct TextLookPreset: Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case titles = "Plain titles", straps = "Name straps", credits = "Rolling credits"
        case animated = "Animated in and out", vertical = "Vertical-video styles"
    }
    public enum Motion: Equatable, Sendable { case none, fade, roll }
    public var id: String, name: String, group: Group
    public var text: NativeClipText
    public var x: Double, y: Double, width: Double, height: Double, fontHeight: Double
    public var seconds: Double
    public var motion: Motion

    /// Explicit families must come from the host's installed-font catalogue. No font is imported implicitly.
    public func isAvailable(installedFamilies: Set<String>) -> Bool {
        guard let family = text.fontFamily, !family.isEmpty else { return true }
        return installedFamilies.contains { $0.caseInsensitiveCompare(family) == .orderedSame }
    }

    public static let all: [TextLookPreset] = [
        .init(id: "title", name: "Plain title", group: .titles, text: .init(content: "Your title", fontWeight: 700, color: NativeClipText.newLayerColor, align: "center"),
              x: 0.1, y: 0.4, width: 0.8, height: 0.2, fontHeight: 0.10, seconds: 5, motion: .none),
        .init(id: "name-strap", name: "Name and role", group: .straps, text: .init(content: "YOUR NAME\nYour role", fontWeight: 600, color: NativeClipText.newLayerColor, align: "left"),
              x: 0.08, y: 0.72, width: 0.84, height: 0.22, fontHeight: 0.065, seconds: 5, motion: .none),
        .init(id: "credits", name: "Rolling credits", group: .credits, text: .init(content: "DIRECTOR\nYour name\n\nPRODUCER\nYour name", fontWeight: 400, color: NativeClipText.newLayerColor, align: "center"),
              x: 0.1, y: 1, width: 0.8, height: 0.9, fontHeight: 0.055, seconds: 12, motion: .roll),
        .init(id: "fade-title", name: "Fade in and out", group: .animated, text: .init(content: "Your title", fontWeight: 700, color: NativeClipText.newLayerColor, align: "center"),
              x: 0.1, y: 0.4, width: 0.8, height: 0.2, fontHeight: 0.10, seconds: 5, motion: .fade),
        .init(id: "vertical-title", name: "Bold vertical title", group: .vertical, text: .init(content: "YOUR\nSTORY", fontWeight: 800, color: NativeClipText.newLayerColor, align: "center"),
              x: 0.08, y: 0.3, width: 0.84, height: 0.4, fontHeight: 0.12, seconds: 5, motion: .none),
        .init(id: "vertical-caption", name: "Vertical caption", group: .vertical, text: .init(content: "Tell your story", fontWeight: 600, color: NativeClipText.newLayerColor, align: "center"),
              x: 0.08, y: 0.7, width: 0.84, height: 0.22, fontHeight: 0.065, seconds: 5, motion: .fade),
    ]
    public static func preset(_ id: String) -> TextLookPreset? { all.first { $0.id == id } }
    /// A drag carries a recipe id, never an asset filename or a path to unimported artwork.
    public static let dragPrefix = "text-look:"
    public static func draggedPreset(_ token: String) -> TextLookPreset? {
        token.hasPrefix(dragPrefix) ? preset(String(token.dropFirst(dragPrefix.count))) : nil
    }
}

public extension TimelineEditor {
    /// Instantiates a recipe as a regular text clip. Layout follows the composition size, animation is ordinary
    /// parameter tracks, and the asset, clip and tracks are undone together. Uninstalled font recipes are refused.
    @discardableResult
    func addTextLook(_ look: TextLookPreset, at time: Double, installedFamilies: Set<String> = []) -> String? {
        guard time.isFinite, time >= 0, look.isAvailable(installedFamilies: installedFamilies) else { return nil }
        let cw = document.canvas.width, ch = document.canvas.height
        let frames = max(2, (look.seconds * fps).rounded()), last = frames - 1
        let token = UUID().uuidString
        func track(_ parameter: String, _ points: [(Double, Double)]) throws -> NativeParameterTrack {
            let id = "text-look:\(token):\(parameter)"
            return try createNativeParameterTrack(.init(id: id, parameterId: parameter, valueType: .number, frameRate: document.frameRate,
                keyframes: points.enumerated().map { i, point in
                    NativeKeyframe(id: "\(id):\(i)", frame: point.0, value: .number(point.1), outgoing: .linear)
                }), engine: engine)
        }
        let tracks: [NativeParameterTrack]
        do {
            switch look.motion {
            case .none: tracks = []
            case .roll: tracks = [try track("layout.top", [(0, ch), (last, -ch * look.height)])]
            case .fade:
                let edge = max(1, min((fps * 0.4).rounded(), (last / 3).rounded(.down)))
                tracks = [try track(Self.opacityId, [(0, 0), (edge, 1), (last - edge, 1), (last, 0)])]
            }
        } catch { return nil }
        return withHistory("Add text look", coalesceKey: token) {
            guard let assetId = addAsset(kind: .element, name: look.name, source: nil, durationFrames: frames) else { return nil }
            return insertClip(assetId: assetId, at: time, durationFrames: frames) { clip in
                var text = look.text
                text.fontSize = max(8, min(2000, (ch * look.fontHeight).rounded()))
                clip.text = text
                clip.staticParameters = ["layout.left": .number(cw * look.x), "layout.top": .number(ch * look.y),
                    "layout.width": .number(cw * look.width), "layout.height": .number(ch * look.height)]
                clip.parameterTracks = tracks
            }
        }
    }
}

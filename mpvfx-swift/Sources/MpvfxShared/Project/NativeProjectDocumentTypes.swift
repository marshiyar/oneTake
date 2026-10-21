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
// The native project document model (`.studio/project.json`).
// Optional fields (`x?:`) are Swift optionals; synthesized Codable omits nil keys,
// so an absent field stays absent on save.
import Foundation

public let NATIVE_PROJECT_DOCUMENT_SCHEMA_VERSION = 1
public let NATIVE_PROJECT_DOCUMENT_PATH = ".studio/project.json"

public enum NativeProjectAssetKind: String, Codable, Sendable { case video, audio, image, element }

public func nativeAssetConsumesSourceFrames(_ kind: NativeProjectAssetKind) -> Bool { kind == .video || kind == .audio }

public enum NativeProjectTrackKind: String, Codable, Sendable { case video, audio, mixed }

public struct NativeCanvas: Codable, Equatable, Sendable {
    public var width: Double; public var height: Double; public var background: String
    /// Input key order and unknown keys (`{ ...document.canvas }`).
    public var spread = NativeSpreadKeys()
    static let known = ["width", "height", "background"]
    public init(width: Double, height: Double, background: String, spread: NativeSpreadKeys = .init()) {
        self.width = width; self.height = height; self.background = background; self.spread = spread
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        width = try c.req(Double.self, "width"); height = try c.req(Double.self, "height"); background = try c.req(String.self, "background")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k { case "width": try c.put(width, k); case "height": try c.put(height, k); default: try c.put(background, k) }
        }
    }
}

/// Records copied whole (`...asset`, `...effect`, `...segment.reference`) keep unknown keys; these helpers do that.
public struct NativeProjectAsset: Codable, Equatable, Sendable {
    public var id: String; public var kind: NativeProjectAssetKind; public var name: String
    public var source: String?; public var durationFrames: Double
    /// Input key order and unknown keys (`{ ...asset }`).
    public var spread = NativeSpreadKeys()
    static let known = ["id", "kind", "name", "source", "durationFrames"]
    public init(id: String, kind: NativeProjectAssetKind, name: String, source: String? = nil, durationFrames: Double, spread: NativeSpreadKeys = .init()) {
        self.id = id; self.kind = kind; self.name = name; self.source = source; self.durationFrames = durationFrames; self.spread = spread
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        id = try c.req(String.self, "id"); kind = try c.req(NativeProjectAssetKind.self, "kind"); name = try c.req(String.self, "name")
        source = try c.opt(String.self, "source"); durationFrames = try c.req(Double.self, "durationFrames")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k { case "id": try c.put(id, k); case "kind": try c.put(kind, k); case "name": try c.put(name, k)
            case "source": try c.put(source, k); default: try c.put(durationFrames, k) }
        }
    }
}

public struct NativeClipEffect: Codable, Equatable, Sendable {
    public var id: String; public var effectId: String; public var enabled: Bool
    public var parameters: NativeJSONObject?
    /// Input key order and unknown keys (`{ ...effect }`).
    public var spread = NativeSpreadKeys()
    static let known = ["id", "effectId", "enabled", "parameters"]
    public init(id: String, effectId: String, enabled: Bool, parameters: NativeJSONObject? = nil, spread: NativeSpreadKeys = .init()) {
        self.id = id; self.effectId = effectId; self.enabled = enabled; self.parameters = parameters; self.spread = spread
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        id = try c.req(String.self, "id"); effectId = try c.req(String.self, "effectId"); enabled = try c.req(Bool.self, "enabled")
        parameters = try c.opt(NativeJSONObject.self, "parameters")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k { case "id": try c.put(id, k); case "effectId": try c.put(effectId, k); case "enabled": try c.put(enabled, k)
            default: try c.put(parameters, k) }
        }
    }
}

/// Also used for sourceInFraction, which is copied whole (`{ ...clip.sourceInFraction }`); playbackRate is rebuilt,
/// so parse strips its unknown keys before decoding.
public struct NativePlaybackRate: Codable, Equatable, Hashable, Sendable {
    public var numerator: Double; public var denominator: Double
    public var spread = NativeSpreadKeys()
    static let known = ["numerator", "denominator"]
    public init(numerator: Double, denominator: Double, spread: NativeSpreadKeys = .init()) {
        self.numerator = numerator; self.denominator = denominator; self.spread = spread
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        numerator = try c.req(Double.self, "numerator"); denominator = try c.req(Double.self, "denominator")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in try c.put(k == "numerator" ? numerator : denominator, k) }
    }
}
public let DEFAULT_NATIVE_PLAYBACK_RATE = NativePlaybackRate(numerator: 1, denominator: 1)

public struct NativeClipDomBinding: Codable, Equatable, Sendable {
    public var sourceFile: String; public var domId: String?; public var hfId: String?
    public var selector: String?; public var selectorIndex: Double?
}

public struct NativeCropPivotSegment: Codable, Equatable, Sendable {
    public struct Reference: Codable, Equatable, Sendable {
        public var frameOffset: Double; public var durationFrames: Double
        public var startRotationKeyId: String; public var endRotationKeyId: String
        public var parameterTracks: [NativeParameterTrack]
        public var staticParameters: NativeOrderedMap<NativeParameterValue>?
        /// Input key order and unknown keys (`{ ...segment.reference }`).
        public var spread = NativeSpreadKeys()
        static let known = ["frameOffset", "durationFrames", "startRotationKeyId", "endRotationKeyId", "parameterTracks", "staticParameters"]
        public init(frameOffset: Double, durationFrames: Double, startRotationKeyId: String, endRotationKeyId: String,
                    parameterTracks: [NativeParameterTrack], staticParameters: NativeOrderedMap<NativeParameterValue>? = nil, spread: NativeSpreadKeys = .init()) {
            self.frameOffset = frameOffset; self.durationFrames = durationFrames; self.startRotationKeyId = startRotationKeyId
            self.endRotationKeyId = endRotationKeyId; self.parameterTracks = parameterTracks; self.staticParameters = staticParameters; self.spread = spread
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
            frameOffset = try c.req(Double.self, "frameOffset"); durationFrames = try c.req(Double.self, "durationFrames")
            startRotationKeyId = try c.req(String.self, "startRotationKeyId"); endRotationKeyId = try c.req(String.self, "endRotationKeyId")
            parameterTracks = try c.req([NativeParameterTrack].self, "parameterTracks")
            staticParameters = try c.opt(NativeOrderedMap<NativeParameterValue>.self, "staticParameters")
            spread = try decodeSpread(decoder, known: Self.known)
        }
        public func encode(to encoder: Encoder) throws {
            try encodeSpread(encoder, spread, known: Self.known) { k, c in
                switch k {
                case "frameOffset": try c.put(frameOffset, k); case "durationFrames": try c.put(durationFrames, k)
                case "startRotationKeyId": try c.put(startRotationKeyId, k); case "endRotationKeyId": try c.put(endRotationKeyId, k)
                case "parameterTracks": try c.put(parameterTracks, k); default: try c.put(staticParameters, k)
                }
            }
        }
    }
    public var startRotationKeyId: String; public var endRotationKeyId: String
    public var offsetFraction: Vec2Value
    public var reference: Reference?
}

public struct NativeProjectClip: Codable, Equatable, Sendable {
    public var id: String; public var assetId: String
    public var audioGroupId: String?; public var audioFxChain: String?; public var audioAutomation: String?
    public var audioDetachedFrom: String?
    public var binding: NativeClipDomBinding?
    public var startFrame: Double; public var durationFrames: Double; public var sourceInFrame: Double
    public var sourceInFraction: NativePlaybackRate?
    public var playbackRate: NativePlaybackRate?
    /// False plays a sped-up or slowed clip's sound at a pitch that follows the speed; absent or true keeps the pitch.
    public var preservesPitch: Bool? = nil
    /// Required on the document; optional only on input (NativeProjectDocumentInput).
    public var muted: Bool
    public var staticParameters: NativeOrderedMap<NativeParameterValue>?
    public var cropPivotSegments: [NativeCropPivotSegment]?
    public var effects: [NativeClipEffect]
    public var parameterTracks: [NativeParameterTrack]
    /// Non-destructive crop; absent means uncropped.
    public var crop: NativeClipCrop? = nil
    /// Hidden clip (timeline eye toggle): kept on the timeline but meant to be left out of preview and export.
    public var hidden: Bool? = nil
    /// Fill, stroke and shadow (the inspector's Style section); absent means none.
    public var style: NativeClipStyle? = nil
    /// A text layer's words and typography (the inspector's Text section); only on clips of a text element asset.
    public var text: NativeClipText? = nil
    /// How a media clip's picture fills its box (the inspector's Fit row); absent means Fit, the contain fit every
    /// clip had before the option existed. Text clips ignore it.
    public var fit: NativeMediaFit? = nil
    /// Fade-in length in project frames from the clip start (`NativeClipFade`); absent means none.
    public var fadeInFrames: Double? = nil
    /// Fade-out length in project frames up to the clip end; absent means none.
    public var fadeOutFrames: Double? = nil
}

/// Crop insets in canvas pixels, measured from the edges of the clip's untransformed box.
public struct NativeClipCrop: Codable, Equatable, Hashable, Sendable {
    public var top: Double; public var right: Double; public var bottom: Double; public var left: Double
    public init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left
    }
    public var isZero: Bool { top <= 0 && right <= 0 && bottom <= 0 && left <= 0 }
}

public struct NativeProjectTrackLane: Codable, Equatable, Sendable {
    public var authoredTrack: Double; public var displayTrack: Double
    /// Input key order and unknown keys (`{ ...(track.lane ?? defaultTrackLane(i)) }`).
    public var spread = NativeSpreadKeys()
    static let known = ["authoredTrack", "displayTrack"]
    public init(authoredTrack: Double, displayTrack: Double, spread: NativeSpreadKeys = .init()) {
        self.authoredTrack = authoredTrack; self.displayTrack = displayTrack; self.spread = spread
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        authoredTrack = try c.req(Double.self, "authoredTrack"); displayTrack = try c.req(Double.self, "displayTrack")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in try c.put(k == "authoredTrack" ? authoredTrack : displayTrack, k) }
    }
}

public struct NativeProjectTrack: Codable, Equatable, Sendable {
    public var id: String; public var kind: NativeProjectTrackKind
    public var lane: NativeProjectTrackLane?; public var clips: [NativeProjectClip]
    /// Track visibility: a hidden track is meant to be left out of preview and export. Absent means shown.
    public var hidden: Bool?
    /// A locked track refuses clip edits (move, trim, split, delete, paste). Absent means unlocked.
    public var locked: Bool?

    public init(id: String, kind: NativeProjectTrackKind, lane: NativeProjectTrackLane? = nil, clips: [NativeProjectClip], hidden: Bool? = nil, locked: Bool? = nil) {
        self.id = id; self.kind = kind; self.lane = lane; self.clips = clips; self.hidden = hidden; self.locked = locked
    }
}

public struct NativeAudioGroup: Codable, Equatable, Sendable {
    public var id: String; public var label: String?; public var volume: Double?; public var muted: Bool?
    public var fxChain: String?; public var automation: String?
}

public extension NativeAudioGroup {
    /// A new bus at unity gain, unmuted.
    static func bus(id: String, label: String? = nil) -> NativeAudioGroup {
        NativeAudioGroup(id: id, label: label, volume: 1, muted: false, fxChain: nil, automation: nil)
    }
}

public struct NativeProjectSequence: Codable, Equatable, Sendable {
    public var id: String; public var name: String; public var durationFrames: Double?
    public var audioGroups: [NativeAudioGroup]?; public var tracks: [NativeProjectTrack]
    /// The caption track (`NativeCaptionTrack.swift`); absent in a project without captions and in every project
    /// written before captions existed, which open unchanged.
    public var captions: NativeCaptionTrack? = nil
}

/// The timeline kind a document stores in `mediaEngine`. Every document is a native timeline drawn by the Swift
/// renderer: parsing accepts `"native"`, `"ffmpeg"` (a legacy value written by older versions) and a missing
/// field, and writes `"native"` back, so the first save after opening an older project migrates it (nothing else
/// in the document changes).
public enum NativeMediaEngine: String, Codable, Sendable {
    case native
    /// Every stored spelling of the native timeline; parseNativeProjectDocument rewrites them to `native`.
    public static let acceptedStoredValues: Set<String> = ["native", "ffmpeg"]
}

public struct NativeProjectDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var mediaEngine: NativeMediaEngine?
    public var id: String; public var revision: Double
    public var frameRate: RationalFrameRate; public var canvas: NativeCanvas
    public var assets: [NativeProjectAsset]; public var sequence: NativeProjectSequence
}

public extension NativeProjectDocument {
    /// An element clip with no `text`: a layer authored in an earlier version of the editor, whose content the
    /// renderer cannot draw. It stays in the document unchanged (never lose the user's edit); preview and export
    /// skip it, and `undrawnElementLayersNotice` tells the user.
    func isUndrawnElementClip(_ clip: NativeProjectClip) -> Bool {
        clip.text == nil && assets.first(where: { $0.id == clip.assetId })?.kind == .element
    }

    /// How many clips `isUndrawnElementClip` skips.
    var undrawnElementLayerCount: Int {
        sequence.tracks.reduce(0) { n, track in n + track.clips.filter(isUndrawnElementClip).count }
    }

    /// The one notice shown when the document holds layers the renderer skips; nil when it has none.
    var undrawnElementLayersNotice: String? {
        let n = undrawnElementLayerCount
        guard n > 0 else { return nil }
        return n == 1
            ? "1 layer from an earlier version of the editor is kept in the project but not drawn in preview or export."
            : "\(n) layers from an earlier version of the editor are kept in the project but not drawn in preview or export."
    }

    /// One notice for future colour-key contracts retained in the document but deliberately not rendered.
    var unsupportedColorKeysNotice: String? {
        let count = sequence.tracks.flatMap(\.clips).flatMap(\.effects).filter { effect in
            guard effect.enabled, effect.effectId == "color-key", let parameters = effect.parameters else { return false }
            return parameters["v"]?.numberValue != 1 || parameters["kind"]?.stringValue != "chroma"
        }.count
        guard count > 0 else { return nil }
        return count == 1
            ? "1 colour-key effect from a newer version of the editor is kept in the project but not drawn in preview or export."
            : "\(count) colour-key effects from a newer version of the editor are kept in the project but not drawn in preview or export."
    }

    /// Notices presented once when opening or exporting content deliberately retained but not drawn.
    var undrawnContentNotices: [String] {
        [undrawnElementLayersNotice, unsupportedColorKeysNotice].compactMap { $0 }
    }
}

public enum NativeProjectDocumentValidationCode: String, Codable, Sendable {
    case invalidRoot = "invalid-root", unsupportedSchemaVersion = "unsupported-schema-version", invalidId = "invalid-id"
    case duplicateId = "duplicate-id", invalidRevision = "invalid-revision", invalidFrameRate = "invalid-frame-rate"
    case invalidCanvas = "invalid-canvas", invalidAsset = "invalid-asset", invalidTrack = "invalid-track", invalidClip = "invalid-clip"
    case invalidPlaybackRate = "invalid-playback-rate", invalidBinding = "invalid-binding", duplicateBinding = "duplicate-binding"
    case invalidEffect = "invalid-effect", invalidStaticParameters = "invalid-static-parameters", missingReference = "missing-reference"
    case mediaTypeMismatch = "media-type-mismatch", sourceOutOfBounds = "source-out-of-bounds", invalidParameterTrack = "invalid-parameter-track"
    case invalidCaption = "invalid-caption"
    case invalidFade = "invalid-fade", fadeExceedsClip = "fade-exceeds-clip"
}

public struct NativeProjectDocumentValidationIssue: Codable, Equatable, Sendable {
    public var code: NativeProjectDocumentValidationCode; public var path: String; public var message: String
}

public struct NativeProjectDocumentValidationError: Error, Equatable, CustomStringConvertible {
    public let issues: [NativeProjectDocumentValidationIssue]
    public let name = "NativeProjectDocumentValidationError"
    public var message: String { issues.map { "\($0.path): \($0.message)" }.joined(separator: "; ") }
    public var description: String { message }
    public init(issues: [NativeProjectDocumentValidationIssue]) { self.issues = issues }
}

public extension NativeProjectClip {
    /// A fresh clip with no effects, keyframes or bindings (timeline insert / drop).
    static func fresh(id: String, assetId: String, startFrame: Double, durationFrames: Double, sourceInFrame: Double = 0) -> NativeProjectClip {
        NativeProjectClip(id: id, assetId: assetId, audioGroupId: nil, audioFxChain: nil, audioAutomation: nil, audioDetachedFrom: nil,
                          binding: nil, startFrame: startFrame, durationFrames: durationFrames, sourceInFrame: sourceInFrame,
                          sourceInFraction: nil, playbackRate: nil, muted: false, staticParameters: [:], cropPivotSegments: nil,
                          effects: [], parameterTracks: [])
    }
}

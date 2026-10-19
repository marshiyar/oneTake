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

// Export policy: formats, resolution presets, output dimensions, sizes and validation. Untyped (`unknown`)
// inputs take `NativeJSONValue?` (nil = undefined). docs/IMPLEMENTATION_NOTES.md lists the edge cases.

// MARK: - Constants

public enum ExportFormat: String, CaseIterable, Codable, Sendable { case mp4, webm, mov }
public enum ExportQuality: String, CaseIterable, Codable, Sendable { case draft, standard, high }
public enum ExportFrameRate: Double, CaseIterable, Codable, Sendable { case fps24 = 24, fps30 = 30, fps60 = 60 }
public enum ExportScale: String, CaseIterable, Codable, Sendable { case auto, p1080 = "1080p", k4 = "4k" }
public enum ExportAspect: String, Codable, Sendable { case landscape, portrait, square }

public let SUPPORTED_EXPORT_FORMATS: [ExportFormat] = [.mp4, .webm, .mov]
public let SUPPORTED_EXPORT_QUALITIES: [ExportQuality] = [.draft, .standard, .high]
public let SUPPORTED_EXPORT_FRAME_RATES: [Double] = [24, 30, 60]
public let SUPPORTED_EXPORT_SCALES: [ExportScale] = [.auto, .p1080, .k4]

public let MAX_EXPORT_LONG_EDGE: Double = 7680
public let MAX_EXPORT_SHORT_EDGE: Double = 4320

/// `{ width, height }` plus any other own keys of the caller's object, in JS own-property order (the whole object is
/// stored as an ordered NativeJSONObject). Sites that copy the object (`{ ...d }`) keep
/// every key, so Swift returns the same value unchanged there; sites that rebuild it (`{ width, height }`
/// and `{ ...CANVAS_DIMENSIONS[r] }`) use `init(width:height:)`, which has only those two keys.
/// Equality ignores key order (vitest toEqual); compare `json.keys` or jsJSONStringify(`jsonValue`) for order.
public struct ExportDimensions: Codable, Equatable {
    public private(set) var json: NativeJSONObject
    public var width: Double {
        get { json["width"]?.numberValue ?? .nan }
        set { json["width"] = .number(newValue) }
    }
    public var height: Double {
        get { json["height"]?.numberValue ?? .nan }
        set { json["height"] = .number(newValue) }
    }
    public init(width: Double, height: Double) {
        json = NativeJSONObject([("width", NativeJSONValue.number(width)), ("height", .number(height))])
    }
    /// Keeps every key of `object` in order. nil unless width and height are numbers (the only objects the typed
    /// API carries; `unknown` inputs go through the NativeJSONValue overloads).
    public init?(json object: NativeJSONObject) {
        guard case .number? = object["width"], case .number? = object["height"] else { return nil }
        json = object
    }
    public var jsonValue: NativeJSONValue { .object(json) }
    /// `{ width: undefined, height: undefined }`: undefined values vanish from JSON, so the object is `{}`.
    /// width/height read as NaN, which fails every dimension check exactly as undefined does.
    public static let missingWidthAndHeight = ExportDimensions(unchecked: NativeJSONObject())
    private init(unchecked object: NativeJSONObject) { json = object }
    public init(from decoder: Decoder) throws {
        let v = try NativeJSONValue(from: decoder)
        guard case .object(let o) = v, let d = ExportDimensions(json: o) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not ExportDimensions"))
        }
        self = d
    }
    public func encode(to encoder: Encoder) throws { try jsonValue.encode(to: encoder) }
}

public struct ExportResolutionPresetInfo: Equatable, Sendable {
    public let label: String, width: Double, height: Double, ratio: String, group: String
}

/// Declaration order of the resolution presets.
public enum ExportResolutionPreset: String, CaseIterable, Sendable {
    case hd720 = "hd-720", fullHd = "full-hd", qhd, uhd4k = "uhd-4k", uhd8k = "uhd-8k"
    case verticalHd = "vertical-hd", verticalFullHd = "vertical-full-hd", verticalQhd = "vertical-qhd"
    case vertical4k = "vertical-4k", vertical8k = "vertical-8k"
    case squareHd = "square-hd", squareFullHd = "square-full-hd", square4k = "square-4k", squareMax = "square-max"
    case social45 = "social-4-5", social54 = "social-5-4"
    case classic43 = "classic-4-3", classic34 = "classic-3-4", dci2k = "dci-2k", dci4k = "dci-4k"
    case cinema219 = "cinema-21-9", cinema8k = "cinema-8k"

    public var info: ExportResolutionPresetInfo {
        func p(_ l: String, _ w: Double, _ h: Double, _ r: String, _ g: String) -> ExportResolutionPresetInfo {
            .init(label: l, width: w, height: h, ratio: r, group: g)
        }
        switch self {
        case .hd720: return p("HD", 1280, 720, "16:9", "Landscape")
        case .fullHd: return p("Full HD", 1920, 1080, "16:9", "Landscape")
        case .qhd: return p("QHD", 2560, 1440, "16:9", "Landscape")
        case .uhd4k: return p("4K UHD", 3840, 2160, "16:9", "Landscape")
        case .uhd8k: return p("8K UHD", 7680, 4320, "16:9", "Landscape")
        case .verticalHd: return p("Vertical HD", 720, 1280, "9:16", "Portrait")
        case .verticalFullHd: return p("Vertical Full HD", 1080, 1920, "9:16", "Portrait")
        case .verticalQhd: return p("Vertical QHD", 1440, 2560, "9:16", "Portrait")
        case .vertical4k: return p("Vertical 4K", 2160, 3840, "9:16", "Portrait")
        case .vertical8k: return p("Vertical 8K", 4320, 7680, "9:16", "Portrait")
        case .squareHd: return p("Square HD", 720, 720, "1:1", "Square")
        case .squareFullHd: return p("Square Full HD", 1080, 1080, "1:1", "Square")
        case .square4k: return p("Square 4K", 2160, 2160, "1:1", "Square")
        case .squareMax: return p("Square Max", 4320, 4320, "1:1", "Square")
        case .social45: return p("Social Portrait", 1080, 1350, "4:5", "Social")
        case .social54: return p("Social Landscape", 1350, 1080, "5:4", "Social")
        case .classic43: return p("Classic 4:3", 2880, 2160, "4:3", "Classic & Cinema")
        case .classic34: return p("Classic 3:4", 2160, 2880, "3:4", "Classic & Cinema")
        case .dci2k: return p("DCI 2K", 2048, 1080, "256:135", "Classic & Cinema")
        case .dci4k: return p("DCI 4K", 4096, 2160, "256:135", "Classic & Cinema")
        case .cinema219: return p("Ultrawide 5K", 5120, 2160, "64:27", "Classic & Cinema")
        case .cinema8k: return p("Ultrawide 8K", 7680, 3240, "64:27", "Classic & Cinema")
        }
    }
}

public var EXPORT_RESOLUTION_PRESETS: [(ExportResolutionPreset, ExportResolutionPresetInfo)] {
    ExportResolutionPreset.allCases.map { ($0, $0.info) }
}

/// Own property names of Object.prototype in V8 (Node v20.19.2, `Object.getOwnPropertyNames(Object.prototype)`,
/// recorded in Tests/MpvfxSharedTests/Export/Fixtures/exportParity.json `objectPrototypeKeys`).
/// `key in EXPORT_RESOLUTION_PRESETS` is true for each of them.
public let JS_OBJECT_PROTOTYPE_KEYS: [String] = [
    "constructor", "__defineGetter__", "__defineSetter__", "hasOwnProperty", "__lookupGetter__", "__lookupSetter__",
    "isPrototypeOf", "propertyIsEnumerable", "toString", "valueOf", "__proto__", "toLocaleString",
]

/// ExportScale | ExportResolutionPreset | "custom", plus what an `in` check also lets through:
/// an inherited Object.prototype key (see docs/IMPLEMENTATION_NOTES.md). It counts as a choice, and
/// resolveExportTargetDimensions returns `{}` (preset lookup gives a function/object without width/height).
public enum ExportResolutionChoice: Equatable, Sendable {
    case scale(ExportScale), preset(ExportResolutionPreset), custom
    case objectPrototypeKey(String)
    public init?(rawValue: String) {
        if let s = ExportScale(rawValue: rawValue) { self = .scale(s) }
        else if rawValue == "custom" { self = .custom }
        else if let p = ExportResolutionPreset(rawValue: rawValue) { self = .preset(p) }
        else if JS_OBJECT_PROTOTYPE_KEYS.contains(rawValue) { self = .objectPrototypeKey(rawValue) }
        else { return nil }
    }
    public var rawValue: String {
        switch self {
        case .scale(let s): return s.rawValue
        case .preset(let p): return p.rawValue
        case .custom: return "custom"
        case .objectPrototypeKey(let k): return k
        }
    }
}

// MARK: - CANVAS_DIMENSIONS (the named canvas sizes)

public enum CanvasResolution: String, CaseIterable, Sendable {
    case landscape, portrait, landscape4k = "landscape-4k", portrait4k = "portrait-4k", square, square4k = "square-4k"
    public var dimensions: ExportDimensions {
        switch self {
        case .landscape: return .init(width: 1920, height: 1080)
        case .portrait: return .init(width: 1080, height: 1920)
        case .landscape4k: return .init(width: 3840, height: 2160)
        case .portrait4k: return .init(width: 2160, height: 3840)
        case .square: return .init(width: 1080, height: 1080)
        case .square4k: return .init(width: 2160, height: 2160)
        }
    }
}
public enum CanvasResolutionOrAuto: Equatable, Sendable {
    case auto, resolution(CanvasResolution)
    public var rawValue: String { if case .resolution(let r) = self { return r.rawValue }; return "auto" }
}

// MARK: - Capabilities (what the media engine writes; the media engine's format table "Export (encode)")

// What the in-house Rust media engine produces for each format. The recorded reference values in
// Tests/MpvfxSharedTests/Export/Fixtures/exportParity.json are checked only for the fields that apply (extension,
// MIME type, resolution scaling and the dimension rules).

/// The refusal formats.md gives every preset the engine does not encode yet.
public let WEBM_EXPORT_UNSUPPORTED_MESSAGE = "WebM export is not supported yet."

public struct ExportColorSpace: Equatable, Sendable {
    public let primaries: String?, transfer: String?, matrix: String?, range: String?
}
public struct ExportFormatCapability: Equatable, Sendable {
    public struct Video: Equatable, Sendable {
        /// `encoder` names the mpvfx-media crate that writes the stream (crates/h264enc, crates/png); nil when the
        /// app has no encoder for the format (it is refused).
        public let codec: String, encoder: String?, pixelFormat: String?
        /// How quality is chosen: "quality-preset" (draft/standard/high), "lossless", or nil when nothing is encoded.
        public let rateControl: String?, qualityApplies: Bool
    }
    public struct Audio: Equatable, Sendable {
        /// `encoder`: "mpvfx-flac" (crates/flac) or "mpvfx-pcm" (the engine writer's own 16-bit LPCM samples).
        public let codec: String, encoder: String?
        /// The 16-bit PCM rate, used for size estimates: exact for LPCM, an estimate from above for FLAC (lossless
        /// compression of real sound stays below it); 0 when nothing is encoded.
        public let maxBitrateKbps: Double
        public let sampleRateHz: Double, channels: Double, bitDepth: Double, optional: Bool
    }
    public struct Alpha: Equatable, Sendable { public let supported: Bool, bitDepth: Double }
    /// `hdr` is false for every format: the engine writes SDR only.
    public struct Color: Equatable, Sendable { public let sdr: ExportColorSpace, hdr: Bool }
    /// `label` is the picker text; `name` is the short format name used in messages.
    public let label: String, name: String, `extension`: String, mimeType: String
    /// The refusal shown to the user when the engine cannot write the format yet; nil when it can.
    public let unsupportedMessage: String?
    /// False when the engine cannot write the format yet (WebM): planExport and the renderer refuse it.
    public var supported: Bool { unsupportedMessage == nil }
    public let video: Video, audio: Audio, alpha: Alpha, color: Color
    public let supportsResolutionScaling: Bool
}

/// 16-bit PCM at 48 kHz stereo: 48 000 × 16 × 2 / 1000.
private let PCM16_STEREO_48K_KBPS: Double = 1536
private let SDR_BT709_LIMITED = ExportColorSpace(primaries: "bt709", transfer: "bt709", matrix: "bt709", range: "limited")
/// PNG frames carry straight RGBA with no colour tags.
private let UNTAGGED_RGB = ExportColorSpace(primaries: nil, transfer: nil, matrix: nil, range: nil)
private func stereo48k(_ codec: String, encoder: String?) -> ExportFormatCapability.Audio {
    .init(codec: codec, encoder: encoder, maxBitrateKbps: encoder == nil ? 0 : PCM16_STEREO_48K_KBPS,
          sampleRateHz: 48_000, channels: 2, bitDepth: 16, optional: true)
}

public func exportFormatCapability(_ format: ExportFormat) -> ExportFormatCapability {
    switch format {
    case .mp4:
        return .init(label: "MP4", name: "MP4", extension: ".mp4", mimeType: "video/mp4", unsupportedMessage: nil,
                     video: .init(codec: "h264", encoder: "mpvfx-h264enc", pixelFormat: "yuv420p",
                                  rateControl: "quality-preset", qualityApplies: true),
                     audio: stereo48k("flac", encoder: "mpvfx-flac"), alpha: .init(supported: false, bitDepth: 0),
                     color: .init(sdr: SDR_BT709_LIMITED, hdr: false), supportsResolutionScaling: true)
    case .webm:
        return .init(label: "WebM (not supported yet)", name: "WebM", extension: ".webm", mimeType: "video/webm",
                     unsupportedMessage: WEBM_EXPORT_UNSUPPORTED_MESSAGE,
                     video: .init(codec: "vp9", encoder: nil, pixelFormat: nil, rateControl: nil, qualityApplies: false),
                     audio: stereo48k("opus", encoder: nil), alpha: .init(supported: false, bitDepth: 0),
                     color: .init(sdr: UNTAGGED_RGB, hdr: false), supportsResolutionScaling: false)
    case .mov:
        return .init(label: "MOV (PNG, alpha)", name: "MOV", extension: ".mov", mimeType: "video/quicktime",
                     unsupportedMessage: nil,
                     video: .init(codec: "png", encoder: "mpvfx-png", pixelFormat: "rgba",
                                  rateControl: "lossless", qualityApplies: false),
                     audio: stereo48k("pcm_s16le", encoder: "mpvfx-pcm"), alpha: .init(supported: true, bitDepth: 8),
                     color: .init(sdr: UNTAGGED_RGB, hdr: false), supportsResolutionScaling: false)
    }
}

/// Every format in ExportFormat order (mp4, webm, mov), the order of EXPORT_FORMAT_CAPABILITIES.
public var EXPORT_FORMAT_CAPABILITIES: [(ExportFormat, ExportFormatCapability)] {
    ExportFormat.allCases.map { ($0, exportFormatCapability($0)) }
}

public let UNSUPPORTED_STANDALONE_EXPORT_FORMATS: [(String, String)] = [
    ("gif", "not exposed by the standalone Studio render route"),
    ("png-sequence", "not exposed by the standalone Studio render route"),
]

// MARK: - Guards

/// JS Number.isSafeInteger.
@inlinable public func jsIsSafeInteger(_ x: Double) -> Bool { jsIsInteger(x) && abs(x) <= jsMaxSafeInteger }

public func isExportFormat(_ value: NativeJSONValue?) -> Bool { value?.stringValue.flatMap(ExportFormat.init(rawValue:)) != nil }
public func isExportQuality(_ value: NativeJSONValue?) -> Bool { value?.stringValue.flatMap(ExportQuality.init(rawValue:)) != nil }
/// `includes` uses SameValueZero, so -0 matches nothing here and 30 matches 30.
public func isExportFrameRate(_ value: NativeJSONValue?) -> Bool { value?.numberValue.flatMap(ExportFrameRate.init(rawValue:)) != nil }
public func isExportScale(_ value: NativeJSONValue?) -> Bool { value?.stringValue.flatMap(ExportScale.init(rawValue:)) != nil }
/// As with `value in EXPORT_RESOLUTION_PRESETS`, Object.prototype keys count as choices (see docs/IMPLEMENTATION_NOTES.md).
public func isExportResolutionChoice(_ value: NativeJSONValue?) -> Bool {
    value?.stringValue.flatMap(ExportResolutionChoice.init(rawValue:)) != nil
}

/// `typeof value === "object" && value !== null`, then `{ width, height } = value` (arrays have neither key).
public func isValidExportDimensions(_ value: NativeJSONValue?) -> Bool {
    guard let value else { return false }
    switch value {
    case .object(let o):
        guard let d = ExportDimensions(json: o) else { return false }
        return isValidExportDimensions(d)
    case .array: return false
    default: return false
    }
}
public func isValidExportDimensions(_ d: ExportDimensions?) -> Bool {
    guard let d else { return false }
    return jsIsSafeInteger(d.width) && jsIsSafeInteger(d.height) && d.width > 0 && d.height > 0
}

public func isValidExportOutputDimensions(_ value: NativeJSONValue?) -> Bool {
    guard isValidExportDimensions(value), case .object(let o)? = value, let d = ExportDimensions(json: o) else { return false }
    return isValidExportOutputDimensions(d)
}
public func isValidExportOutputDimensions(_ d: ExportDimensions?) -> Bool {
    guard let d, isValidExportDimensions(d) else { return false }
    let longEdge = max(d.width, d.height), shortEdge = min(d.width, d.height)   // safe integers: no NaN here
    return jsRemainder(d.width, 2) == 0 && jsRemainder(d.height, 2) == 0
        && longEdge <= MAX_EXPORT_LONG_EDGE && shortEdge <= MAX_EXPORT_SHORT_EDGE
}

// MARK: - Dimensions

private func greatestCommonDivisor(_ a: Double, _ b: Double) -> Double {
    var left = abs(a), right = abs(b)
    while right > 0 { let r = jsRemainder(left, right); left = right; right = r }
    return left == 0 || left.isNaN ? 1 : left   // `left || 1`
}

public func exportAspectRatioLabel(_ d: ExportDimensions) -> String {
    let divisor = greatestCommonDivisor(d.width, d.height)
    return "\(jsNumberString(d.width / divisor)):\(jsNumberString(d.height / divisor))"
}

public func resolveExportTargetDimensions(_ resolution: ExportResolutionChoice, _ authored: ExportDimensions?,
                                          _ custom: ExportDimensions? = nil) -> ExportDimensions? {
    switch resolution {
    case .scale(.auto): return isValidExportOutputDimensions(authored) ? authored : nil
    case .custom: return isValidExportOutputDimensions(custom) ? custom : nil
    case .preset(let p): return .init(width: p.info.width, height: p.info.height)
    // An unknown preset builds `{ width: undefined, height: undefined }` (JSON `{}`): truthy but not valid dimensions.
    case .objectPrototypeKey: return .missingWidthAndHeight
    case .scale(let s):
        guard isValidExportDimensions(authored) else { return nil }
        return resolveExportDimensions(.mp4, s, authored)
    }
}

public func compositionAspect(_ d: ExportDimensions?) -> ExportAspect {
    guard let d, isValidExportDimensions(d) else { return .landscape }
    if d.width == d.height { return .square }
    return d.height > d.width ? .portrait : .landscape
}

public func normalizeExportScaleForFormat(_ format: ExportFormat, _ scale: ExportScale) -> ExportScale {
    exportFormatCapability(format).supportsResolutionScaling ? scale : .auto
}

public func resolveExportResolution(_ format: ExportFormat, _ scale: ExportScale, _ d: ExportDimensions?) -> CanvasResolutionOrAuto {
    let normalized = normalizeExportScaleForFormat(format, scale)
    if normalized == .auto || !isValidExportDimensions(d) { return .auto }
    let aspect = compositionAspect(d)
    if normalized == .p1080 { return .resolution(CanvasResolution(rawValue: aspect.rawValue)!) }
    switch aspect {
    case .landscape: return .resolution(.landscape4k)
    case .portrait: return .resolution(.portrait4k)
    case .square: return .resolution(.square4k)
    }
}

public func exportScaleApplies(_ format: ExportFormat, _ scale: ExportScale, _ d: ExportDimensions?) -> Bool {
    if scale == .auto { return true }
    if !exportFormatCapability(format).supportsResolutionScaling { return false }
    guard let d, isValidExportDimensions(d) else { return false }
    guard case .resolution(let r) = resolveExportResolution(format, scale, d) else { return false }
    let target = r.dimensions
    if target.width * d.height != target.height * d.width { return false }
    if target.width < d.width || target.height < d.height { return false }
    return jsIsInteger(target.width / d.width) && jsIsInteger(target.height / d.height)
}

public func resolveExportDimensions(_ format: ExportFormat, _ scale: ExportScale, _ d: ExportDimensions?) -> ExportDimensions? {
    guard let d, isValidExportDimensions(d) else { return nil }
    if case .resolution(let r) = resolveExportResolution(format, scale, d) { return r.dimensions }  // rebuild (:321)
    return d  // `{ ...dimensions }` (:321): every key kept
}

public func resolveEncodedDimensions(_ format: ExportFormat, _ d: ExportDimensions?) -> ExportDimensions? {
    guard let d, isValidExportDimensions(d) else { return nil }
    if format == .mov { return d }
    let isEven = jsRemainder(d.width, 2) == 0 && jsRemainder(d.height, 2) == 0
    if format == .webm { return isEven ? d : nil }
    return .init(width: d.width + jsRemainder(d.width, 2), height: d.height + jsRemainder(d.height, 2))
}

// MARK: - Sizes, frames

/// Bytes of sound at the format's PCM rate: exact for MOV LPCM, an estimate from above for MP4 FLAC.
public func estimateExportAudioSizeBytes(_ durationSeconds: Double, _ format: ExportFormat, _ hasAudio: Bool) -> Double {
    if !hasAudio || !durationSeconds.isFinite || durationSeconds <= 0 { return 0 }
    return jsMathRound((durationSeconds * exportFormatCapability(format).audio.maxBitrateKbps * 1000) / 8)
}

public func exportFrameCount(_ durationSeconds: Double, _ fps: ExportFrameRate) -> Double {
    if !durationSeconds.isFinite || durationSeconds <= 0 { return 0 }
    let raw = durationSeconds * fps.rawValue
    let nearest = jsMathRound(raw)
    return abs(raw - nearest) <= 1e-3 ? nearest : raw.rounded(.up)
}

public func formatExportFileSize(_ bytes: Double) -> String {
    if !bytes.isFinite || bytes < 0 { return "Unknown size" }
    if bytes < 1024 { return "\(jsNumberString(bytes)) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var value = bytes / 1024
    var unit = units[0]
    var index = 1
    while index < units.count && value >= 1024 { value /= 1024; unit = units[index]; index += 1 }
    let rounded = value >= 10 || jsIsInteger(value) ? jsMathRound(value) : jsMathRound(value * 10) / 10
    return "\(jsNumberString(rounded)) \(unit)"
}

// MARK: - Validation

public struct ExportSettingsInput {
    public var format: NativeJSONValue?, quality: NativeJSONValue?, fps: NativeJSONValue?
    public var scale: NativeJSONValue?, dimensions: NativeJSONValue?
    public init(format: NativeJSONValue?, quality: NativeJSONValue?, fps: NativeJSONValue?,
                scale: NativeJSONValue?, dimensions: NativeJSONValue?) {
        self.format = format; self.quality = quality; self.fps = fps; self.scale = scale; self.dimensions = dimensions
    }
}
public struct ExportValidationResult: Equatable { public let ok: Bool; public let issues: [String] }

public func validateExportSettings(_ input: ExportSettingsInput) -> ExportValidationResult {
    var issues: [String] = []
    if !isExportFormat(input.format) { issues.append("Unsupported export format.") }
    if !isExportQuality(input.quality) { issues.append("Unsupported export quality.") }
    if !isExportFrameRate(input.fps) { issues.append("Unsupported export frame rate.") }
    if !isExportScale(input.scale) { issues.append("Unsupported export resolution.") }
    if !isValidExportDimensions(input.dimensions) { issues.append("Invalid composition dimensions.") }

    if let format = input.format?.stringValue.flatMap(ExportFormat.init(rawValue:)),
       let scale = input.scale?.stringValue.flatMap(ExportScale.init(rawValue:)),
       isValidExportDimensions(input.dimensions), case .object(let o)? = input.dimensions,
       let dims = ExportDimensions(json: o) {
        let cap = exportFormatCapability(format)
        if !exportScaleApplies(format, scale, dims) {
            issues.append(cap.supportsResolutionScaling
                ? "The selected resolution is not an integer upscale of the composition."
                : "\(cap.name) exports at native resolution.")
        }
        if let out = resolveExportDimensions(format, scale, dims), resolveEncodedDimensions(format, out) == nil {
            issues.append("\(cap.name) requires even dimensions.")
        }
    }
    return .init(ok: issues.isEmpty, issues: issues)
}

// MARK: - Telemetry dimension label

/// The `${dimensions.width}x${dimensions.height}` label for render telemetry and job names (callers must use
/// this). JS `String()` of each value: a missing key is "undefined" (e.g. the `{}` from an Object.prototype preset
/// name gives "undefinedxundefined"), a number is jsNumberString, and any other JSON value carried in the object is
/// rendered like JS template interpolation of that value.
public func exportDimensionsLabel(_ d: ExportDimensions) -> String {
    func part(_ v: NativeJSONValue?) -> String {
        switch v {
        case nil: return "undefined"
        case .null?: return "null"
        case .number(let n)?: return jsNumberString(n)
        case .string(let s)?: return s
        case .bool(let b)?: return b ? "true" : "false"
        case .array(let a)?: return a.map { $0 == .null ? "" : part($0) }.joined(separator: ",")
        case .object?: return "[object Object]"
        }
    }
    return "\(part(d.json["width"]))x\(part(d.json["height"]))"
}

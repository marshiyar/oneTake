// The person-matte effect entry of a clip (`effectId: "person-matte"`): its parameters, validation and the notice for
// an entry this build cannot read. The matte itself lives in a cache beside the project (PersonMatteCache.swift).
import Foundation

public enum PersonMatteEffect {
    public static let effectId = "person-matte"
    public static let currentVersion = 1.0
    public static let qualities = ["fast", "balanced", "accurate"]
    public static let defaultQuality = "balanced"
    public static let shrinkRange = -10.0...10.0
    public static let softenRange = 0.0...20.0
    /// Longest edge, in px, of a stored matte frame.
    public static let maxLongEdge = 512

    /// The validated parameters of a version 1 entry.
    public struct Parameters: Equatable, Sendable {
        public var quality: String
        public var shrink: Double
        public var soften: Double
        public var invert: Bool
        public init(quality: String = PersonMatteEffect.defaultQuality, shrink: Double = 0, soften: Double = 0, invert: Bool = false) {
            self.quality = quality; self.shrink = shrink; self.soften = soften; self.invert = invert
        }
        /// The `parameters` object of the effect: `shrink`, `soften` and `invert` are left out when they hold their default.
        public var json: NativeJSONObject {
            var o: NativeJSONObject = ["v": .number(PersonMatteEffect.currentVersion), "quality": .string(quality)]
            if shrink != 0 { o["shrink"] = .number(shrink) }
            if soften != 0 { o["soften"] = .number(soften) }
            if invert { o["invert"] = .bool(true) }
            return o
        }
    }

    /// The parameters when `object` is a complete, valid version 1 entry; nil otherwise (unknown version, bad value).
    public static func parameters(_ object: NativeJSONObject?) -> Parameters? {
        guard let object, object["v"]?.numberValue == currentVersion else { return nil }
        guard let quality = object["quality"]?.stringValue, qualities.contains(quality) else { return nil }
        func number(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let value = object[key] else { return 0 }
            guard let n = value.numberValue, n.isFinite, range.contains(n) else { return nil }
            return n
        }
        guard let shrink = number("shrink", shrinkRange), let soften = number("soften", softenRange) else { return nil }
        var invert = false
        if let v = object["invert"] {
            guard let b = v.boolValue else { return nil }
            invert = b
        }
        return Parameters(quality: quality, shrink: shrink, soften: soften, invert: invert)
    }

    public static func effect(id: String, parameters: Parameters, enabled: Bool = true) -> NativeClipEffect {
        NativeClipEffect(id: id, effectId: effectId, enabled: enabled, parameters: parameters.json)
    }

    /// Whether this build draws the entry (a known version with valid values).
    public static func supports(_ effect: NativeClipEffect) -> Bool {
        effect.effectId == effectId && parameters(effect.parameters) != nil
    }

    /// The clip's enabled entry this build draws, with its parameters.
    public static func active(_ clip: NativeProjectClip) -> (effect: NativeClipEffect, parameters: Parameters)? {
        for e in clip.effects where e.enabled && e.effectId == effectId {
            if let p = parameters(e.parameters) { return (e, p) }
        }
        return nil
    }

    /// The analysis size of a matte for media of `aspect` (width over height): the long edge is `maxLongEdge`.
    public static func analysisSize(aspect: Double) -> (width: Int, height: Int) {
        guard aspect.isFinite, aspect > 0 else { return (maxLongEdge, maxLongEdge) }
        if aspect >= 1 { return (maxLongEdge, max(1, Int((Double(maxLongEdge) / aspect).rounded()))) }
        return (max(1, Int((Double(maxLongEdge) * aspect).rounded())), maxLongEdge)
    }
}

/// The validator's rules for a person-matte entry. An object with an unknown `v` is kept and reports nothing here.
func validatePersonMatteEffect(_ effect: NativeJSONValue, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let parameters = effect["parameters"], parameters.isRecord else {
        if effect["parameters"] == nil { pushIssue(&issues, .invalidEffect, "\(path).parameters", "Person-matte parameters must be an object") }
        return
    }
    let base = "\(path).parameters"
    guard let v = parameters["v"]?.numberValue else {
        return pushIssue(&issues, .invalidEffect, "\(base).v", "Person-matte v must be the number 1")
    }
    guard v == PersonMatteEffect.currentVersion else { return }
    if parameters["quality"]?.stringValue.map(PersonMatteEffect.qualities.contains) != true {
        pushIssue(&issues, .invalidEffect, "\(base).quality", "Person-matte quality must be fast, balanced or accurate")
    }
    if let value = parameters["shrink"], !(value.numberValue.map { $0.isFinite && PersonMatteEffect.shrinkRange.contains($0) } ?? false) {
        pushIssue(&issues, .invalidEffect, "\(base).shrink", "Person-matte shrink must be a finite value from -10 through 10")
    }
    if let value = parameters["soften"], !(value.numberValue.map { $0.isFinite && PersonMatteEffect.softenRange.contains($0) } ?? false) {
        pushIssue(&issues, .invalidEffect, "\(base).soften", "Person-matte soften must be a finite value from 0 through 20")
    }
    if let value = parameters["invert"], value.boolValue == nil {
        pushIssue(&issues, .invalidEffect, "\(base).invert", "Person-matte invert must be true or false")
    }
}

extension NativeProjectDocument {
    /// One notice for person-matte entries kept in the document but not drawn (a newer version, or invalid values).
    var unsupportedPersonMattesNotice: String? {
        let count = sequence.tracks.flatMap(\.clips).flatMap(\.effects).filter {
            $0.enabled && $0.effectId == PersonMatteEffect.effectId && !PersonMatteEffect.supports($0)
        }.count
        guard count > 0 else { return nil }
        return count == 1
            ? "1 person-matte effect from a newer version of the editor is kept in the project but not drawn in preview or export."
            : "\(count) person-matte effects from a newer version of the editor are kept in the project but not drawn in preview or export."
    }
}

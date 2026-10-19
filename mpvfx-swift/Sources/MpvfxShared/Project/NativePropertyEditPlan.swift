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
// Property edit plans: resolve the selected clip and turn property values into keyframe commands.
import Foundation

public enum NativeEditableProperty: String, CaseIterable {
    case x, y, z, rotation, rotationX, rotationY, rotationZ, scale, scaleX, scaleY, scaleZ
    case perspective, transformPerspective, opacity, autoAlpha, width, height
}

/// Fields typed `string | null | undefined`: nil covers both null and undefined, which are
/// treated identically here (only whether the value is a string matters).
public struct NativeSelectedElementReference: Equatable {
    public var id: String?, hfId: String?, sourceFile: String?, selector: String?
    public var selectorIndex: Double?
    public var attributes: [String: String?]?
    public var datasetStudioClipId: String?
    public init(id: String? = nil, hfId: String? = nil, sourceFile: String? = nil, selector: String? = nil, selectorIndex: Double? = nil,
                attributes: [String: String?]? = nil, datasetStudioClipId: String? = nil) {
        self.id = id; self.hfId = hfId; self.sourceFile = sourceFile; self.selector = selector; self.selectorIndex = selectorIndex
        self.attributes = attributes; self.datasetStudioClipId = datasetStudioClipId
    }
}

public struct NativeSelectionBounds: Equatable { public var width: Double, height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height } }

/// Property values are untyped; non-numbers fail with "nonfinite-value".
public enum NativePropertyInputValue: Equatable { case number(Double), other(NativeJSONValue) }

public enum NativePropertyEditIntent: String { case edit, keyframe }

public struct NativePropertyEditPlanRequest {
    public var selectedElement: NativeSelectedElementReference
    public var playheadSeconds: Double
    /// Ordered like JS Object.keys of the literal (insertion order).
    public var properties: [(String, NativePropertyInputValue)]
    public var selectionBounds: NativeSelectionBounds?
    public var propertyBaselines: [String: Double]?
    public var intent: NativePropertyEditIntent?
    public var autoKeyframeEnabled: Bool?
    public init(selectedElement: NativeSelectedElementReference, playheadSeconds: Double, properties: [(String, NativePropertyInputValue)],
                selectionBounds: NativeSelectionBounds? = nil, propertyBaselines: [String: Double]? = nil,
                intent: NativePropertyEditIntent? = nil, autoKeyframeEnabled: Bool? = nil) {
        self.selectedElement = selectedElement; self.playheadSeconds = playheadSeconds; self.properties = properties
        self.selectionBounds = selectionBounds; self.propertyBaselines = propertyBaselines; self.intent = intent; self.autoKeyframeEnabled = autoKeyframeEnabled
    }
}

public enum NativePropertyEditPlanFailureCode: String {
    case missingSelectionId = "missing-selection-id", clipNotFound = "clip-not-found", ambiguousClip = "ambiguous-clip"
    case invalidPlayhead = "invalid-playhead", playheadOutsideClip = "playhead-outside-clip", emptyPropertySet = "empty-property-set"
    case unsupportedProperty = "unsupported-property", nonfiniteValue = "nonfinite-value"
    case missingSelectionBounds = "missing-selection-bounds", duplicateParameter = "duplicate-parameter"
}

public struct NativePropertyEditPlanFailure: Equatable, Error {
    public var code: NativePropertyEditPlanFailureCode
    public var message: String
    public var property: String?
}

public struct NativePropertyEditPlan: Equatable {
    public var clipId: String
    public var projectFrame: Double
    public var clipLocalFrame: Double
    /// Always a batch (`{type:"batch", commands}`).
    public var commands: [NativeProjectAtomicPropertyCommand]
}

public typealias NativePropertyEditPlanResult = Result<NativePropertyEditPlan, NativePropertyEditPlanFailure>

public struct NativeLocatedClip: Equatable { public var trackId: String; public var clip: NativeProjectClip }
public typealias NativeClipSelectionResolution = Result<NativeLocatedClip, NativePropertyEditPlanFailure>

private let propertyOrder = NativeEditableProperty.allCases

private func parameterId(_ p: NativeEditableProperty) -> String {
    switch p {
    case .x: "transform.position.x"; case .y: "transform.position.y"; case .z: "transform.position.z"
    case .rotation, .rotationZ: "transform.rotation"; case .rotationX: "transform.rotationX"; case .rotationY: "transform.rotationY"
    case .scale: "transform.scale"; case .scaleX: "transform.scaleX"; case .scaleY: "transform.scaleY"; case .scaleZ: "transform.scaleZ"
    case .perspective, .transformPerspective: "transform.perspective"
    case .opacity, .autoAlpha: "visual.opacity"; case .width: "layout.width"; case .height: "layout.height"
    }
}

private func definitionBaseline(_ p: NativeEditableProperty, _ bounds: NativeSelectionBounds?) -> Double? {
    switch p {
    case .scale, .scaleX, .scaleY, .scaleZ, .opacity, .autoAlpha: 1
    case .width: bounds?.width
    case .height: bounds?.height
    default: 0
    }
}

public struct NativePlayheadError: Error, CustomStringConvertible { public let message: String; public var description: String { message } }

/// Quantize editor time exactly as native preview and export address project frames.
public func projectFrameFromSeconds(_ seconds: Double, frameRate: RationalFrameRate) throws -> Double {
    if !seconds.isFinite { throw NativePlayheadError(message: "Playhead seconds must be finite") }
    if seconds < 0 { throw NativePlayheadError(message: "Playhead seconds must not be negative") }
    let r = try validateRationalFrameRate(frameRate)
    return ((seconds * r.numerator) / r.denominator + 1e-9).rounded(.down)
}

private func explicitSelectedClipId(_ e: NativeSelectedElementReference) -> String? {
    if let attr = e.attributes?["data-studio-clip-id"], let v = attr { return v }
    return e.datasetStudioClipId
}

private func findClip(_ d: NativeProjectDocument, _ clipId: String) -> [NativeLocatedClip] {
    d.sequence.tracks.flatMap { t in t.clips.filter { $0.id == clipId }.map { NativeLocatedClip(trackId: t.id, clip: $0) } }
}

private func rfail(_ code: NativePropertyEditPlanFailureCode, _ m: String, _ property: String? = nil) -> NativePropertyEditPlanFailure {
    .init(code: code, message: m, property: (property?.isEmpty ?? true) ? nil : property)
}

private func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

/// Ordered map keyed by clip id (JS Map insertion order; re-set keeps first position).
private struct OrderedMatches {
    var keys: [String] = []; var values: [String: NativeLocatedClip] = [:]
    mutating func set(_ k: String, _ v: NativeLocatedClip) { if values[k] == nil { keys.append(k) }; values[k] = v }
    var count: Int { keys.count }
    var first: NativeLocatedClip { values[keys[0]]! }
}

/// Resolve one selected preview node without making DOM identity canonical.
public func resolveNativeClipSelection(_ document: NativeProjectDocument, _ e: NativeSelectedElementReference) -> NativeClipSelectionResolution {
    if let explicit = explicitSelectedClipId(e) {
        if explicit.isEmpty { return .failure(rfail(.missingSelectionId, "The selected element has an empty native clip identity")) }
        let m = findClip(document, explicit)
        if m.count == 1 {
            let located = m[0]
            if let b = located.clip.binding,
               (nonEmpty(e.sourceFile) != nil && e.sourceFile != b.sourceFile) ||
               (nonEmpty(e.hfId) != nil && nonEmpty(b.hfId) != nil && e.hfId != b.hfId) {
                return .failure(rfail(.clipNotFound, "The selected element's native identity belongs to a different source element"))
            }
            return .success(located)
        }
        if m.count > 1 { return .failure(rfail(.ambiguousClip, "More than one native clip exactly matches \(explicit)")) }
        return .failure(rfail(.clipNotFound, "No native clip exactly matches \(explicit)"))
    }
    let id = nonEmpty(e.id), hfId = nonEmpty(e.hfId), sourceFile = nonEmpty(e.sourceFile), selector = nonEmpty(e.selector)
    let selectorIndex: Double = { if let i = e.selectorIndex, jsIsInteger(i), i >= 0 { return i }; return 0 }()
    if id == nil && hfId == nil && selector == nil {
        return .failure(rfail(.missingSelectionId, "The selected element has no exact native clip or compatibility identity"))
    }
    func matches(_ b: NativeClipDomBinding) -> Bool {
        (id != nil && b.domId == id) || (hfId != nil && b.hfId == hfId) ||
        (selector != nil && b.selector == selector && (b.selectorIndex ?? 0) == selectorIndex)
    }
    if let sourceFile {
        var found = OrderedMatches()
        for t in document.sequence.tracks { for c in t.clips {
            guard let b = c.binding, b.sourceFile == sourceFile, matches(b) else { continue }
            found.set(c.id, .init(trackId: t.id, clip: c))
        } }
        if found.count == 1 { return .success(found.first) }
        if found.count > 1 { return .failure(rfail(.ambiguousClip, "Selection identifiers resolve to more than one scoped native clip binding")) }
    } else {
        var found = OrderedMatches()
        for t in document.sequence.tracks { for c in t.clips {
            guard let b = c.binding, matches(b) else { continue }
            found.set(c.id, .init(trackId: t.id, clip: c))
        } }
        if let id {
            let direct = findClip(document, id)
            if direct.count > 1 { return .failure(rfail(.ambiguousClip, "More than one native clip exactly matches \(id)")) }
            if direct.count == 1 { found.set(direct[0].clip.id, direct[0]) }
        }
        if found.count == 1 { return .success(found.first) }
        if found.count > 1 { return .failure(rfail(.ambiguousClip, "Selection identifiers resolve to more than one unscoped native clip binding")) }
    }
    if let id {
        let direct = findClip(document, id)
        if direct.count == 1 { return .success(direct[0]) }
        if direct.count > 1 { return .failure(rfail(.ambiguousClip, "More than one native clip exactly matches \(id)")) }
    }
    return .failure(rfail(.clipNotFound, "No native clip exactly matches the selected element or its scoped compatibility binding"))
}

private func validBounds(_ b: NativeSelectionBounds?) -> Bool {
    guard let b else { return false }
    return b.width.isFinite && b.width > 0 && b.height.isFinite && b.height > 0
}

public func planNativePropertyEdit(_ document: NativeProjectDocument, _ request: NativePropertyEditPlanRequest) -> NativePropertyEditPlanResult {
    let located: NativeLocatedClip
    switch resolveNativeClipSelection(document, request.selectedElement) {
    case .failure(let f): return .failure(f)
    case .success(let l): located = l
    }
    let projectFrame: Double
    do { projectFrame = try projectFrameFromSeconds(request.playheadSeconds, frameRate: document.frameRate) }
    catch { return .failure(rfail(.invalidPlayhead, "\(error)")) }
    let clipLocalFrame = max(0, min(located.clip.durationFrames - 1, projectFrame - located.clip.startFrame))

    // JS objects keep only the last value for a repeated key; keep first position like Object.keys.
    var names: [String] = []; var values: [String: NativePropertyInputValue] = [:]
    for (k, v) in request.properties { if values[k] == nil { names.append(k) }; values[k] = v }
    if names.isEmpty { return .failure(rfail(.emptyPropertySet, "At least one property edit is required")) }
    if let unsupported = names.first(where: { NativeEditableProperty(rawValue: $0) == nil }) {
        return .failure(rfail(.unsupportedProperty, "Property \(unsupported) is not supported by native keyframes", unsupported))
    }
    var numbers: [NativeEditableProperty: Double] = [:]
    for name in names {
        guard case .number(let n)? = values[name], n.isFinite else {
            return .failure(rfail(.nonfiniteValue, "Property \(name) must have a finite numeric value", name))
        }
        numbers[NativeEditableProperty(rawValue: name)!] = n
    }
    let writesKeyframe = request.intent != .edit || request.autoKeyframeEnabled != false
    if writesKeyframe && (numbers[.width] != nil || numbers[.height] != nil) && !validBounds(request.selectionBounds) {
        return .failure(rfail(.missingSelectionBounds, "Finite positive selection bounds are required to keyframe width or height"))
    }

    var commands: [NativeProjectAtomicPropertyCommand] = []
    var parameterIds = Set<String>()
    for property in propertyOrder {
        guard let value = numbers[property] else { continue }
        let pid = parameterId(property)
        if parameterIds.contains(pid) {
            return .failure(rfail(.duplicateParameter, "Properties target native parameter \(pid) more than once", property.rawValue))
        }
        parameterIds.insert(pid)
        let address = NativeProjectParameterAddress(sequenceId: document.sequence.id, trackId: located.trackId, clipId: located.clip.id, parameterId: pid)
        let parameterTrack = located.clip.parameterTracks.first { $0.parameterId == pid }

        if writesKeyframe {
            let baseline: Double?
            if case .number(let s)? = located.clip.staticParameters?[pid] { baseline = s }
            else if let m = request.propertyBaselines?[property.rawValue], m.isFinite { baseline = m }
            else { baseline = definitionBaseline(property, request.selectionBounds) }
            guard let baseline else {
                return .failure(rfail(.missingSelectionBounds, "Property \(property.rawValue) requires a selection-bound baseline", property.rawValue))
            }
            commands.append(.keyframe(.upsert(address: address, valueType: .number, frame: clipLocalFrame, value: .number(value), baselineValue: .number(baseline))))
            continue
        }
        if parameterTrack == nil, let routed = routedPosition(located.clip, parameterId: pid) {
            if routed.track.keyframes.contains(where: { $0.frame == clipLocalFrame }) {
                commands.append(.keyframe(.updateValue(address: address, frame: clipLocalFrame, value: .number(value))))
            } else {
                var base = Double.nan   // keyframes[0].value[component]; always vec2 here
                if case .vec2(let v) = routed.track.keyframes[0].value { base = routed.component == .x ? v.x : v.y }
                commands.append(.keyframe(.upsert(address: address, valueType: .number, frame: clipLocalFrame, value: .number(value), baselineValue: .number(base))))
            }
            continue
        }
        guard let track = parameterTrack else {
            commands.append(.setStatic(address: address, value: .number(value)))
            continue
        }
        if track.valueType != .number {
            return .failure(rfail(.unsupportedProperty, "Property \(property.rawValue) is bound to a non-numeric native parameter", property.rawValue))
        }
        if track.keyframes.contains(where: { $0.frame == clipLocalFrame }) {
            commands.append(.keyframe(.updateValue(address: address, frame: clipLocalFrame, value: .number(value))))
            continue
        }
        guard case .number(let first) = track.keyframes[0].value else { continue }
        commands.append(.keyframe(.upsert(address: address, valueType: .number, frame: clipLocalFrame, value: .number(value), baselineValue: .number(first))))
    }
    return .success(.init(clipId: located.clip.id, projectFrame: projectFrame, clipLocalFrame: clipLocalFrame, commands: commands))
}

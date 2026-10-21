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
// Helpers for the native project document validator.
// Validators run over untyped NativeJSONValue. `nil` = a missing key; `.null` = JSON null.
import Foundation

typealias Issues = [NativeProjectDocumentValidationIssue]

/// JS `s.trim().length === 0` (JS whitespace set, see jsTrim).
func jsTrimmedIsEmpty(_ s: String) -> Bool { s.utf16.allSatisfy(jsIsTrimmable) }
func isNonEmptyString(_ v: NativeJSONValue?) -> Bool { if let s = v?.stringValue { return !jsTrimmedIsEmpty(s) }; return false }
func isSafeInteger(_ x: Double) -> Bool { jsIsInteger(x) && abs(x) <= jsMaxSafeInteger }
func isNonNegativeInteger(_ v: NativeJSONValue?) -> Bool { if let n = v?.numberValue { return isSafeInteger(n) && n >= 0 }; return false }
func isPositiveInteger(_ v: NativeJSONValue?) -> Bool { isNonNegativeInteger(v) && v!.numberValue! > 0 }
func isRecordValue(_ v: NativeJSONValue?) -> Bool { v?.isRecord ?? false }
func isFiniteNumber(_ v: NativeJSONValue?) -> Bool { v?.numberValue?.isFinite ?? false }

func defaultTrackLane(_ trackIndex: Int) -> NativeProjectTrackLane {
    NativeProjectTrackLane(authoredTrack: Double(trackIndex), displayTrack: Double(trackIndex))
}

func pushIssue(_ issues: inout Issues, _ code: NativeProjectDocumentValidationCode, _ path: String, _ message: String) {
    issues.append(.init(code: code, path: path, message: message))
}

/// A clip's look: `style`, `fit` and `text`, in that issue order (NativeProjectIssueOrderTests pins style before text).
func validateNativeClipPresentation(_ clip: NativeJSONValue, _ clipPath: String, _ issues: inout Issues) {
    validateNativeClipStyle(clip["style"], "\(clipPath).style", &issues)
    validateNativeMediaFit(clip["fit"], "\(clipPath).fit", &issues)
    validateNativeClipText(clip["text"], "\(clipPath).text", &issues)
}

func validateTrackLane(_ raw: NativeJSONValue?, _ trackIndex: Int, _ path: String, _ issues: inout Issues) -> NativeProjectTrackLane? {
    guard let raw else { return defaultTrackLane(trackIndex) }
    guard raw.isRecord else { pushIssue(&issues, .invalidTrack, path, "Track lane metadata must be an object"); return nil }
    var valid = true
    if !isNonNegativeInteger(raw["authoredTrack"]) {
        pushIssue(&issues, .invalidTrack, "\(path).authoredTrack", "Authored track must be a non-negative integer"); valid = false
    }
    if !isNonNegativeInteger(raw["displayTrack"]) {
        pushIssue(&issues, .invalidTrack, "\(path).displayTrack", "Display track must be a non-negative integer"); valid = false
    }
    return valid ? NativeProjectTrackLane(authoredTrack: raw["authoredTrack"]!.numberValue!, displayTrack: raw["displayTrack"]!.numberValue!) : nil
}

@discardableResult
func requireId(_ v: NativeJSONValue?, _ path: String, _ issues: inout Issues) -> Bool {
    if isNonEmptyString(v) { return true }
    pushIssue(&issues, .invalidId, path, "Stable ID must be a non-empty string"); return false
}

func collectDuplicateId(_ ids: inout Set<String>, _ v: NativeJSONValue?, _ path: String, _ issues: inout Issues) {
    guard isNonEmptyString(v), let s = v?.stringValue else { return }
    if ids.contains(s) { pushIssue(&issues, .duplicateId, path, "Duplicate stable ID \(s)"); return }
    ids.insert(s)
}

func validateFrameRate(_ v: NativeJSONValue?, _ path: String, _ issues: inout Issues) -> RationalFrameRate? {
    guard let v, v.isRecord else { pushIssue(&issues, .invalidFrameRate, path, "Frame rate must be an object"); return nil }
    // The raw object reaches validateRationalFrameRate; a non-number fails Number.isInteger the same way NaN does.
    let r = RationalFrameRate(numerator: v["numerator"]?.numberValue ?? .nan, denominator: v["denominator"]?.numberValue ?? .nan)
    do { return try validateRationalFrameRate(r) } catch {
        pushIssue(&issues, .invalidFrameRate, path, (error as? NativeKeyframeValidationError)?.message ?? "Invalid rational frame rate")
        return nil
    }
}

func validatePlaybackRate(_ v: NativeJSONValue, _ path: String, _ issues: inout Issues) -> NativePlaybackRate? {
    guard v.isRecord else {
        pushIssue(&issues, .invalidPlaybackRate, path, "Playback rate must be an exact numerator/denominator object"); return nil
    }
    guard isPositiveInteger(v["numerator"]), isPositiveInteger(v["denominator"]) else {
        pushIssue(&issues, .invalidPlaybackRate, path, "Playback rate numerator and denominator must be positive safe integers"); return nil
    }
    return NativePlaybackRate(numerator: v["numerator"]!.numberValue!, denominator: v["denominator"]!.numberValue!)
}

/// Throws NativeSourceTimeRangeError on 64-bit overflow; the caller maps it.
func sourceRangeExceedsAsset(_ sourceInFrame: Double, _ durationFrames: Double, _ playbackRate: NativePlaybackRate,
                             _ assetDurationFrames: Double, _ sourceInFraction: NativePlaybackRate?) throws -> Bool {
    !(try sourceRangeFits(NativeSourcePosition(sourceInFrame: sourceInFrame, sourceInFraction: sourceInFraction),
                          playbackRate: playbackRate, durationFrames: durationFrames, sourceDurationFrames: assetDurationFrames))
}

/// Decode the raw track for the core constructor. These messages
/// reach the UI (NativeProjectDocumentValidationError.message -> showToast), so the checks run in the same order as
/// createNativeParameterTrack and use its text: track ID, parameter ID, frame rate, keyframes.length / .map (V8
/// TypeError text), then each keyframe's ID and duplicate ID. What the constructor leaves to the engine (valueType, frame, value,
/// interpolation, path) is handed to the engine exactly as the Node binding would read it (see engineTrackFromRaw).
struct TrackShapeError: Error { let message: String }

/// The track exactly as the original engine binding read it from untyped keyframes (its compileTrack,
/// parseValueType, parseKey, numberOrNaN and string steps, kept in the keyframe engine's history). The C ABI (the keyframe engine) takes
/// typed keys, so the checks the binding makes before the core sees the data (valueType and interpolation/path type
/// strings, object shapes) are made here with the binding's text and error code, key by key in the binding's order.
/// Everything the core can see (frame, value components, control points, curviness) is passed to the real engine,
/// which produces its own message: non-numbers become NaN as in numberOrNaN. A bad frame is checked by the engine
/// itself (one-key track) at the point the binding would check it, so the message is the engine's.
func engineTrackFromRaw(_ rawValueType: NativeJSONValue?, _ rawKeys: [NativeJSONValue], engine: KeyframeEngine) throws -> KeyframeTrack {
    func fail(_ code: KeyframeTrackErrorCode, _ m: String) -> KeyframeEngineError { KeyframeEngineError(code: code.rawValue, message: m) }
    func num(_ v: NativeJSONValue?) -> Double { if case .number(let n)? = v { return n }; return .nan }
    func str(_ v: NativeJSONValue?) -> String { v?.stringValue ?? "" }
    func isObject(_ v: NativeJSONValue?) -> Bool { switch v { case .object?, .array?: return true; default: return false } }
    func jsTruthy(_ v: NativeJSONValue?) -> Bool {
        switch v { case nil, .null?, .bool(false)?, .string("")?: return false
        case .number(let n)?: return n != 0 && !n.isNaN; default: return true }
    }
    let typeName = str(rawValueType)
    guard let type = NativeValueType(rawValue: typeName) else { throw fail(.invalidValue, "Unknown track valueType \"\(typeName)\"") }
    var keys: [KeyframeTrack.Key] = []
    for k in rawKeys {
        if !isObject(k) { throw fail(.invalidValue, "Keyframe must be an object") }
        let frame = num(k["frame"])
        if !frame.isFinite || frame.rounded(.down) != frame || abs(frame) > 9.0e15 {
            try engine.validate(KeyframeTrack(valueType: .number, keyframes: [.init(frame: frame, value: .number(0), outgoing: .linear)]))
            throw fail(.invalidKeyframeFrame, "Keyframe frame must be an integer project frame") // engine accepted: unreachable
        }
        let v = k["value"]; let value: NativeParameterValue
        switch type {
        case .number: value = .number(num(v))
        case _ where !isObject(v): throw fail(.invalidValue, "Keyframe at frame \(Int64(frame)) value must be an object")
        case .vec2: value = .vec2(Vec2Value(x: num(v?["x"]), y: num(v?["y"])))
        case .rgba: value = .rgba(RgbaValue(red: num(v?["red"]), green: num(v?["green"]), blue: num(v?["blue"]), alpha: num(v?["alpha"])))
        }
        let o = k["outgoing"]
        if !isObject(o) { throw fail(.invalidInterpolation, "Keyframe outgoing interpolation is missing") }
        let outgoing: NativeInterpolation
        switch str(o?["type"]) {
        case "hold": outgoing = .hold
        case "linear": outgoing = .linear
        case "cubic-bezier":
            let cp = o?["controlPoints"]
            if !isObject(cp) { throw fail(.invalidInterpolation, "cubic-bezier controlPoints are missing") }
            outgoing = .cubicBezier(CubicBezierControlPoints(x1: num(cp?["x1"]), y1: num(cp?["y1"]), x2: num(cp?["x2"]), y2: num(cp?["y2"])))
        case let kind: throw fail(.invalidInterpolation, "Unknown interpolation \"\(kind)\"")
        }
        // createNativeParameterTrack copies outgoingPath only when truthy.
        var path: NativeMotionPath? = nil
        let p = k["outgoingPath"]
        if jsTruthy(p) {
            if !isObject(p) { throw fail(.invalidPath, "outgoingPath must be an object") }
            func point(_ n: String) -> Vec2Value { let q = p?[n]; return isObject(q) ? Vec2Value(x: num(q?["x"]), y: num(q?["y"])) : Vec2Value(x: .nan, y: .nan) }
            switch str(p?["type"]) {
            case "line": path = nil
            case "curve": path = .curve(curviness: num(p?["curviness"]))
            case "bezier": path = .bezier(cp1: point("cp1"), cp2: point("cp2"))
            case let shape: throw fail(.invalidPath, "Unknown path type \"\(shape)\"")
            }
        }
        keys.append(.init(frame: frame, value: value, outgoing: outgoing, outgoingPath: path))
    }
    return KeyframeTrack(valueType: type, keyframes: keys)
}
private func jsTypeErrorRead(_ v: NativeJSONValue?, _ prop: String) -> String {
    "Cannot read properties of \(v == .null ? "null" : "undefined") (reading '\(prop)')"
}
private func decodeTrackInput(_ raw: NativeJSONValue, engine: KeyframeEngine?) -> Result<NativeParameterTrackInput, TrackShapeError> {
    func blank(_ v: NativeJSONValue?) -> Bool { guard let s = v?.stringValue else { return true }; return jsTrimmedIsEmpty(s) }
    if blank(raw["id"]) { return .failure(.init(message: "Track ID must not be empty")) }
    if blank(raw["parameterId"]) { return .failure(.init(message: "Parameter ID must not be empty")) }
    let id = raw["id"]!.stringValue!, parameterId = raw["parameterId"]!.stringValue!
    let fr = raw["frameRate"]!
    let frameRate = RationalFrameRate(numerator: fr["numerator"]?.numberValue ?? .nan, denominator: fr["denominator"]?.numberValue ?? .nan)
    do { _ = try validateRationalFrameRate(frameRate) } catch let e as NativeKeyframeValidationError { return .failure(.init(message: e.message)) }
    catch { return .failure(.init(message: "Invalid parameter track")) }
    let rawKeyframes = raw["keyframes"]
    switch rawKeyframes {
    case nil, .null?: return .failure(.init(message: jsTypeErrorRead(rawKeyframes, "length")))
    case .string("")?, .array([])?: return .failure(.init(message: "Parameter track \(id) must contain at least one keyframe"))
    case .array?: break
    default: return .failure(.init(message: "input.keyframes.map is not a function"))
    }
    var seen = Set<String>()
    for k in rawKeyframes!.arrayValue! {
        if k == .null { return .failure(.init(message: jsTypeErrorRead(k, "id"))) }
        if blank(k["id"]) { return .failure(.init(message: "Keyframe ID must not be empty")) }
        let kid = k["id"]!.stringValue!
        if !seen.insert(kid).inserted { return .failure(.init(message: "Parameter track \(id) has duplicate keyframe ID \(kid)")) }
    }
    // Engine stage (keyframeEngine().validate({ valueType, keyframes }) inside createNativeParameterTrack).
    let e: KeyframeEngine
    do { e = try engine ?? keyframeEngine() } catch { return .failure(.init(message: "\(error)")) }
    func engineFailure(_ error: Error) -> TrackShapeError {
        if let err = error as? KeyframeEngineError {
            // createNativeParameterTrack prefixes track errors; any other engine error is rethrown as is.
            return .init(message: err.trackErrorCode != nil ? "Parameter track \(id): \(err.message)" : err.message)
        }
        return .init(message: "\(error)")
    }
    let valueType: NativeValueType
    do {
        let track = try engineTrackFromRaw(raw["valueType"], rawKeyframes!.arrayValue!, engine: e)
        try e.validate(track)
        valueType = track.valueType
    } catch { return .failure(engineFailure(error)) }
    var keys: [NativeKeyframe] = []
    for (i, k) in rawKeyframes!.arrayValue!.enumerated() {
        guard let key = try? k.decode(NativeKeyframe.self) else { return .failure(.init(message: "Parameter track \(id): keyframe \(i) is malformed")) }
        keys.append(key)
    }
    return .success(NativeParameterTrackInput(id: id, parameterId: parameterId, valueType: valueType, frameRate: frameRate, keyframes: keys))
}

@discardableResult
func validateParameterTracks(_ rawTracks: NativeJSONValue?, _ projectFrameRate: RationalFrameRate?, _ clipDurationFrames: Double?,
                             _ path: String, _ issues: inout Issues, engine: KeyframeEngine?) -> Bool {
    guard let tracks = rawTracks?.arrayValue else {
        pushIssue(&issues, .invalidParameterTrack, path, "Parameter tracks must be an array"); return false
    }
    var ids = Set<String>(), parameterIds = Set<String>()
    for (index, raw) in tracks.enumerated() {
        let trackPath = "\(path)[\(index)]"
        guard raw.isRecord else { pushIssue(&issues, .invalidParameterTrack, trackPath, "Parameter track must be an object"); continue }
        collectDuplicateId(&ids, raw["id"], "\(trackPath).id", &issues)
        if isNonEmptyString(raw["parameterId"]), let pid = raw["parameterId"]?.stringValue {
            if parameterIds.contains(pid) { pushIssue(&issues, .duplicateId, "\(trackPath).parameterId", "Duplicate parameter ID \(pid)") }
            parameterIds.insert(pid)
        }
        if raw["schemaVersion"] != .number(Double(NATIVE_KEYFRAME_SCHEMA_VERSION)) {
            pushIssue(&issues, .invalidParameterTrack, "\(trackPath).schemaVersion", "Parameter track schemaVersion must be \(NATIVE_KEYFRAME_SCHEMA_VERSION)")
            continue
        }
        guard let fr = raw["frameRate"], fr.isRecord else {
            pushIssue(&issues, .invalidParameterTrack, "\(trackPath).frameRate", "Missing frame rate"); continue
        }
        if let p = projectFrameRate, fr["numerator"] != .number(p.numerator) || fr["denominator"] != .number(p.denominator) {
            pushIssue(&issues, .invalidParameterTrack, "\(trackPath).frameRate", "Parameter-track frame rate must match the project frame rate")
        }
        // The core owns keyframe, interpolation, value and duplicate-keyframe validation. Its sorted result is
        // discarded: parsing never silently changes authored document ordering.
        switch decodeTrackInput(raw, engine: engine) {
        case .failure(let e): pushIssue(&issues, .invalidParameterTrack, trackPath, e.message)
        case .success(let input):
            do { _ = try createNativeParameterTrack(input, engine: engine) } catch {
                let message = (error as? NativeKeyframeValidationError)?.message ?? (error as? KeyframeEngineError)?.message
                    ?? (error as? KeyframeEngineNotLoadedError)?.description ?? "Invalid parameter track"
                pushIssue(&issues, .invalidParameterTrack, trackPath, message)
            }
        }
        if let limit = clipDurationFrames, let keys = raw["keyframes"]?.arrayValue {
            for (ki, k) in keys.enumerated() where k.isRecord && isNonNegativeInteger(k["frame"]) && k["frame"]!.numberValue! > limit {
                pushIssue(&issues, .invalidParameterTrack, "\(trackPath).keyframes[\(ki)].frame",
                          "Keyframe frame \(jsNumberString(k["frame"]!.numberValue!)) exceeds clip duration \(jsNumberString(limit))")
            }
        }
    }
    return true
}

private func hasExactlyKeys(_ o: NativeJSONObject, _ keys: [String]) -> Bool { Array(o.keys).sorted() == keys.sorted() }

/// Entries are visited in input key order (Object.entries), so issues come out in document order.
func validateStaticParameters(_ raw: NativeJSONValue?, _ path: String, _ issues: inout Issues) {
    guard let raw else { return }
    guard let entries = raw.objectValue else { pushIssue(&issues, .invalidStaticParameters, path, "Static parameters must be an object"); return }
    for parameterId in entries.keys {
        let value = entries[parameterId]!, valuePath = "\(path).\(parameterId)"
        if jsTrimmedIsEmpty(parameterId) {
            pushIssue(&issues, .invalidStaticParameters, path, "Static parameter IDs must be non-empty strings"); continue
        }
        if let n = value.numberValue {
            if !n.isFinite { pushIssue(&issues, .invalidStaticParameters, valuePath, "Static number must be finite") }
            continue
        }
        guard let o = value.objectValue else {
            pushIssue(&issues, .invalidStaticParameters, valuePath, "Static parameter must be a finite number, vec2, or RGBA value"); continue
        }
        if hasExactlyKeys(o, ["x", "y"]) {
            if !isFiniteNumber(o["x"]) || !isFiniteNumber(o["y"]) {
                pushIssue(&issues, .invalidStaticParameters, valuePath, "Vec2 components must be finite")
            }
            continue
        }
        if hasExactlyKeys(o, ["alpha", "blue", "green", "red"]) {
            if let bad = ["alpha", "blue", "green", "red"].first(where: { c in
                guard let n = o[c]?.numberValue, n.isFinite else { return true }; return n < 0 || n > 1 }) {
                pushIssue(&issues, .invalidStaticParameters, "\(valuePath).\(bad)", "RGBA channels must be finite numbers between 0 and 1")
            }
            continue
        }
        pushIssue(&issues, .invalidStaticParameters, valuePath, "Static object must contain exactly x/y or red/green/blue/alpha")
    }
}

func validateClipBinding(_ raw: NativeJSONValue, _ path: String, _ identities: inout Set<String>, _ issues: inout Issues) {
    guard raw.isRecord else { pushIssue(&issues, .invalidBinding, path, "Clip binding must be an object"); return }
    let sourceFileValid = isNonEmptyString(raw["sourceFile"])
    if !sourceFileValid { pushIssue(&issues, .invalidBinding, "\(path).sourceFile", "Binding sourceFile must be a non-empty string") }
    var hasIdentifier = false
    for identifier in ["domId", "hfId", "selector"] {
        guard let v = raw[identifier] else { continue }
        if !isNonEmptyString(v) {
            pushIssue(&issues, .invalidBinding, "\(path).\(identifier)", "Binding \(identifier) must be a non-empty string when provided"); continue
        }
        hasIdentifier = true
    }
    if !hasIdentifier { pushIssue(&issues, .invalidBinding, path, "Binding must provide domId, hfId, or selector") }
    if raw["selectorIndex"] != nil {
        if !isNonEmptyString(raw["selector"]) {
            pushIssue(&issues, .invalidBinding, "\(path).selectorIndex", "Binding selectorIndex requires a selector")
        }
        if !isNonNegativeInteger(raw["selectorIndex"]) {
            pushIssue(&issues, .invalidBinding, "\(path).selectorIndex", "Binding selectorIndex must be a non-negative integer")
        }
    }
    guard sourceFileValid, let file = raw["sourceFile"]?.stringValue else { return }
    var scoped: [String] = []
    if isNonEmptyString(raw["domId"]) { scoped.append("\(file)\u{0}domId\u{0}\(raw["domId"]!.stringValue!)") }
    if isNonEmptyString(raw["hfId"]) { scoped.append("\(file)\u{0}hfId\u{0}\(raw["hfId"]!.stringValue!)") }
    if isNonEmptyString(raw["selector"]) {
        let index = isNonNegativeInteger(raw["selectorIndex"]) ? jsNumberString(raw["selectorIndex"]!.numberValue!) : "0"
        scoped.append("\(file)\u{0}selector\u{0}\(raw["selector"]!.stringValue!)\u{0}\(index)")
    }
    for identity in scoped {
        if identities.contains(identity) {
            pushIssue(&issues, .duplicateBinding, path, "Two native clips cannot share the same scoped DOM binding")
        } else { identities.insert(identity) }
    }
}

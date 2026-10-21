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
// Validates an untyped native project document. Never throws; returns every issue.
import Foundation

private func str(_ v: NativeJSONValue?) -> String? { v?.stringValue }

public func validateNativeProjectDocument(_ input: NativeJSONValue, engine: KeyframeEngine? = nil) -> [NativeProjectDocumentValidationIssue] {
    var issues: Issues = []
    guard input.isRecord else { pushIssue(&issues, .invalidRoot, "", "Project document must be an object"); return issues }

    if input["schemaVersion"] != .number(Double(NATIVE_PROJECT_DOCUMENT_SCHEMA_VERSION)) {
        pushIssue(&issues, .unsupportedSchemaVersion, "schemaVersion", "Project schemaVersion must be \(NATIVE_PROJECT_DOCUMENT_SCHEMA_VERSION)")
    }
    if let engineValue = input["mediaEngine"], !(engineValue.stringValue.map(NativeMediaEngine.acceptedStoredValues.contains) ?? false) {
        pushIssue(&issues, .invalidRoot, "mediaEngine", "Unknown media engine")
    }
    requireId(input["id"], "id", &issues)
    if !isNonNegativeInteger(input["revision"]) {
        pushIssue(&issues, .invalidRevision, "revision", "Revision must be a non-negative integer")
    }
    let projectFrameRate = validateFrameRate(input["frameRate"], "frameRate", &issues)

    if let canvas = input["canvas"], canvas.isRecord {
        if !isPositiveInteger(canvas["width"]) { pushIssue(&issues, .invalidCanvas, "canvas.width", "Canvas width must be a positive integer") }
        if !isPositiveInteger(canvas["height"]) { pushIssue(&issues, .invalidCanvas, "canvas.height", "Canvas height must be a positive integer") }
        if !isNonEmptyString(canvas["background"]) { pushIssue(&issues, .invalidCanvas, "canvas.background", "Canvas background must be a non-empty string") }
    } else {
        pushIssue(&issues, .invalidCanvas, "canvas", "Canvas must be an object")
    }

    var assetsById: [String: NativeJSONValue] = [:]
    let kinds = ["video", "audio", "image", "element"]
    if let assets = input["assets"]?.arrayValue {
        var assetIds = Set<String>()
        for (index, asset) in assets.enumerated() {
            let path = "assets[\(index)]"
            guard asset.isRecord else { pushIssue(&issues, .invalidAsset, path, "Asset must be an object"); continue }
            requireId(asset["id"], "\(path).id", &issues)
            collectDuplicateId(&assetIds, asset["id"], "\(path).id", &issues)
            if isNonEmptyString(asset["id"]), let id = str(asset["id"]), assetsById[id] == nil { assetsById[id] = asset }
            let kind = str(asset["kind"])
            if kind.map(kinds.contains) != true {
                pushIssue(&issues, .invalidAsset, "\(path).kind", "Asset kind must be video, audio, image, or element")
            }
            if kind == "element" && asset["source"] != nil {
                pushIssue(&issues, .invalidAsset, "\(path).source", "Element assets have no source file")
            }
            if !isNonEmptyString(asset["name"]) { pushIssue(&issues, .invalidAsset, "\(path).name", "Asset name must be a non-empty string") }
            if asset["source"] != nil && !isNonEmptyString(asset["source"]) {
                pushIssue(&issues, .invalidAsset, "\(path).source", "Asset source must be a non-empty string")
            }
            if !isPositiveInteger(asset["durationFrames"]) {
                pushIssue(&issues, .invalidAsset, "\(path).durationFrames", "Asset duration must be a positive integer")
            }
        }
    } else {
        pushIssue(&issues, .invalidAsset, "assets", "Assets must be an array")
    }

    guard let sequence = input["sequence"], sequence.isRecord else {
        pushIssue(&issues, .invalidTrack, "sequence", "Sequence must be an object"); return issues
    }
    requireId(sequence["id"], "sequence.id", &issues)
    if !isNonEmptyString(sequence["name"]) { pushIssue(&issues, .invalidTrack, "sequence.name", "Sequence name must be a non-empty string") }
    if sequence["durationFrames"] != nil && !isPositiveInteger(sequence["durationFrames"]) {
        pushIssue(&issues, .invalidTrack, "sequence.durationFrames", "Sequence duration must be a positive integer")
    }
    guard let tracks = sequence["tracks"]?.arrayValue else {
        pushIssue(&issues, .invalidTrack, "sequence.tracks", "Tracks must be an array"); return issues
    }

    var audioGroupIds = Set<String>()
    if let rawGroups = sequence["audioGroups"] {
        if let groups = rawGroups.arrayValue {
            let maxGain = pow(10.0, 12.0 / 20.0)
            for (index, group) in groups.enumerated() {
                let path = "sequence.audioGroups[\(index)]"
                guard group.isRecord else { pushIssue(&issues, .invalidTrack, path, "Audio group must be an object"); continue }
                requireId(group["id"], "\(path).id", &issues)
                collectDuplicateId(&audioGroupIds, group["id"], "\(path).id", &issues)
                if group["label"] != nil && !isNonEmptyString(group["label"]) {
                    pushIssue(&issues, .invalidTrack, "\(path).label", "Audio group label must be a non-empty string")
                }
                if let v = group["volume"] {
                    if !(v.numberValue.map { $0.isFinite && $0 >= 0 && $0 <= maxGain } ?? false) {
                        pushIssue(&issues, .invalidTrack, "\(path).volume", "Audio group gain must be within the supported fader range")
                    }
                }
                if group["muted"] != nil && group["muted"]?.boolValue == nil {
                    pushIssue(&issues, .invalidTrack, "\(path).muted", "Audio group mute must be a boolean")
                }
                for name in ["fxChain", "automation"] where group[name] != nil && (str(group[name]) ?? "").isEmpty {
                    pushIssue(&issues, .invalidTrack, "\(path).\(name)", "\(name) must be serialized text")
                }
            }
        } else {
            pushIssue(&issues, .invalidTrack, "sequence.audioGroups", "Audio groups must be an array")
        }
    }

    var trackIds = Set<String>(), authoredLaneIds = Set<String>(), displayLaneIds = Set<Double>()
    var clipIds = Set<String>(), bindingIdentities = Set<String>()
    for (trackIndex, track) in tracks.enumerated() {
        let trackPath = "sequence.tracks[\(trackIndex)]"
        guard track.isRecord else { pushIssue(&issues, .invalidTrack, trackPath, "Track must be an object"); continue }
        requireId(track["id"], "\(trackPath).id", &issues)
        collectDuplicateId(&trackIds, track["id"], "\(trackPath).id", &issues)
        let trackKind = str(track["kind"]).flatMap(NativeProjectTrackKind.init(rawValue:))
        if trackKind == nil { pushIssue(&issues, .invalidTrack, "\(trackPath).kind", "Track kind must be video, audio, or mixed") }
        for flag in ["hidden", "locked"] where track[flag] != nil && track[flag]?.boolValue == nil {
            pushIssue(&issues, .invalidTrack, "\(trackPath).\(flag)", "Track \(flag) must be a boolean")
        }
        if let lane = validateTrackLane(track["lane"], trackIndex, "\(trackPath).lane", &issues) {
            if displayLaneIds.contains(lane.displayTrack) {
                pushIssue(&issues, .invalidTrack, "\(trackPath).lane.displayTrack",
                          "Display track \(jsNumberString(lane.displayTrack)) is already mapped by another native track")
            } else { displayLaneIds.insert(lane.displayTrack) }
            if let kind = trackKind {
                let laneId = "\(kind.rawValue)\u{0}\(jsNumberString(lane.authoredTrack))"
                if authoredLaneIds.contains(laneId) {
                    pushIssue(&issues, .invalidTrack, "\(trackPath).lane.authoredTrack",
                              "\(kind.rawValue) authored track \(jsNumberString(lane.authoredTrack)) is already mapped")
                } else { authoredLaneIds.insert(laneId) }
            }
        }
        guard let clips = track["clips"]?.arrayValue else {
            pushIssue(&issues, .invalidTrack, "\(trackPath).clips", "Track clips must be an array"); continue
        }
        for (clipIndex, clip) in clips.enumerated() {
            let clipPath = "\(trackPath).clips[\(clipIndex)]"
            guard clip.isRecord else { pushIssue(&issues, .invalidClip, clipPath, "Clip must be an object"); continue }
            requireId(clip["id"], "\(clipPath).id", &issues)
            collectDuplicateId(&clipIds, clip["id"], "\(clipPath).id", &issues)
            if let binding = clip["binding"] { validateClipBinding(binding, "\(clipPath).binding", &bindingIdentities, &issues) }
            if !isNonEmptyString(clip["assetId"]) {
                pushIssue(&issues, .missingReference, "\(clipPath).assetId", "Clip assetId must be a non-empty string")
            }
            let asset = isNonEmptyString(clip["assetId"]) ? assetsById[str(clip["assetId"])!] : nil
            let assetKind = asset.flatMap { str($0["kind"]) }
            if asset == nil && isNonEmptyString(clip["assetId"]) {
                pushIssue(&issues, .missingReference, "\(clipPath).assetId", "Missing asset \(str(clip["assetId"])!)")
            }
            if clip["audioGroupId"] != nil {
                if !isNonEmptyString(clip["audioGroupId"]) || !audioGroupIds.contains(str(clip["audioGroupId"])!) {
                    pushIssue(&issues, .missingReference, "\(clipPath).audioGroupId", "Clip audio group must name a defined bus")
                }
                if asset != nil && assetKind != "audio" && assetKind != "video" {
                    pushIssue(&issues, .invalidClip, "\(clipPath).audioGroupId", "Only audio and video clips can join an audio group")
                }
            }
            if clip["audioDetachedFrom"] != nil && (!isNonEmptyString(clip["audioDetachedFrom"]) || assetKind != "audio") {
                pushIssue(&issues, .invalidClip, "\(clipPath).audioDetachedFrom", "Only an audio clip can link to a source video clip")
            }
            for name in ["audioFxChain", "audioAutomation"] where clip[name] != nil && (str(clip[name]) ?? "").isEmpty {
                pushIssue(&issues, .invalidClip, "\(clipPath).\(name)", "\(name) must be serialized text")
            }
            if asset != nil && ((trackKind == .audio && assetKind != "audio") ||
                                (trackKind == .video && assetKind != "video" && assetKind != "image" && assetKind != "element")) {
                pushIssue(&issues, .mediaTypeMismatch, "\(clipPath).assetId", "Asset kind does not match track kind")
            }
            for (name, positive) in [("startFrame", false), ("durationFrames", true), ("sourceInFrame", false)] {
                if positive ? !isPositiveInteger(clip[name]) : !isNonNegativeInteger(clip[name]) {
                    pushIssue(&issues, .invalidClip, "\(clipPath).\(name)", "\(name) must be a \(positive ? "positive" : "non-negative") integer")
                }
            }
            let playbackRate: NativePlaybackRate? = clip["playbackRate"].map {
                validatePlaybackRate($0, "\(clipPath).playbackRate", &issues) } ?? DEFAULT_NATIVE_PLAYBACK_RATE
            let fraction = clip["sourceInFraction"]
            let validFraction = fraction == nil || (fraction!.isRecord && isNonNegativeInteger(fraction!["numerator"]) &&
                isPositiveInteger(fraction!["denominator"]) && fraction!["numerator"]!.numberValue! < fraction!["denominator"]!.numberValue!)
            if !validFraction {
                pushIssue(&issues, .invalidClip, "\(clipPath).sourceInFraction", "Source fraction must be a nonnegative rational smaller than one")
            }
            if clip["hidden"] != nil && clip["hidden"]?.boolValue == nil {
                pushIssue(&issues, .invalidClip, "\(clipPath).hidden", "Hidden must be a boolean")
            }
            if clip["preservesPitch"] != nil && clip["preservesPitch"]?.boolValue == nil {
                pushIssue(&issues, .invalidClip, "\(clipPath).preservesPitch", "Preserves pitch must be a boolean")
            }
            if clip["muted"] != nil && clip["muted"]?.boolValue == nil {
                pushIssue(&issues, .invalidClip, "\(clipPath).muted", "Muted must be a boolean")
            }
            validateSpeedRamp(clip["speedRamp"], duration: clip["durationFrames"]?.numberValue,
                              path: "\(clipPath).speedRamp", issues: &issues)
            if let rawSegments = clip["cropPivotSegments"] {
                if let segments = rawSegments.arrayValue {
                    var pairs = Set<[String]>()
                    for (index, segment) in segments.enumerated() {
                        let path = "\(clipPath).cropPivotSegments[\(index)]"
                        let offset = segment["offsetFraction"]
                        guard segment.isRecord, isNonEmptyString(segment["startRotationKeyId"]), isNonEmptyString(segment["endRotationKeyId"]),
                              segment["startRotationKeyId"] != segment["endRotationKeyId"], offset?.isRecord == true,
                              [offset!["x"], offset!["y"]].allSatisfy({ v in v?.numberValue.map { $0.isFinite && abs($0) <= 0.5 } ?? false })
                        else {
                            pushIssue(&issues, .invalidClip, path, "Crop pivot segment needs two key IDs and finite normalized offsets"); continue
                        }
                        let pair = [str(segment["startRotationKeyId"])!, str(segment["endRotationKeyId"])!]
                        if pairs.contains(pair) { pushIssue(&issues, .invalidClip, path, "Duplicate crop pivot segment") }
                        pairs.insert(pair)
                        if let reference = segment["reference"] {
                            if !reference.isRecord || !isNonNegativeInteger(reference["frameOffset"]) || !isPositiveInteger(reference["durationFrames"]) ||
                                !isNonEmptyString(reference["startRotationKeyId"]) || !isNonEmptyString(reference["endRotationKeyId"]) {
                                pushIssue(&issues, .invalidClip, "\(path).reference", "Invalid crop pivot reference")
                            } else {
                                validateParameterTracks(reference["parameterTracks"], projectFrameRate, reference["durationFrames"]!.numberValue!,
                                                        "\(path).reference.parameterTracks", &issues, engine: engine)
                                validateStaticParameters(reference["staticParameters"], "\(path).reference.staticParameters", &issues)
                                let hasKeys = reference["parameterTracks"]?.arrayValue?.contains { t in
                                    guard t.isRecord, t["parameterId"] == .string("transform.rotation"), let keys = t["keyframes"]?.arrayValue else { return false }
                                    return keys.contains { $0.isRecord && $0["id"] == reference["startRotationKeyId"] } &&
                                        keys.contains { $0.isRecord && $0["id"] == reference["endRotationKeyId"] }
                                } ?? false
                                if !hasKeys { pushIssue(&issues, .invalidClip, "\(path).reference", "Missing reference rotation keys") }
                            }
                        }
                    }
                } else {
                    pushIssue(&issues, .invalidClip, "\(clipPath).cropPivotSegments", "Crop pivot segments must be an array")
                }
            }
            if let crop = clip["crop"] {
                let sides = ["top", "right", "bottom", "left"]
                if !crop.isRecord || !sides.allSatisfy({ crop[$0]?.numberValue.map { $0.isFinite && $0 >= 0 } ?? false }) {
                    pushIssue(&issues, .invalidClip, "\(clipPath).crop", "Crop needs finite non-negative top, right, bottom and left insets")
                }
            }
            validateNativeClipFades(clip, clipPath, &issues); validateNativeClipStyle(clip["style"], "\(clipPath).style", &issues)
            validateNativeClipText(clip["text"], "\(clipPath).text", &issues)
            if clip["text"] != nil, assetKind != "element" {
                pushIssue(&issues, .invalidClip, "\(clipPath).text", "Only a clip of an element asset can carry text")
            }
            validateStaticParameters(clip["staticParameters"], "\(clipPath).staticParameters", &issues)
            if let asset, assetKind == "video" || assetKind == "audio",
               let sourceInFrame = clip["sourceInFrame"]?.numberValue, isNonNegativeInteger(clip["sourceInFrame"]),
               let durationFrames = clip["durationFrames"]?.numberValue, isPositiveInteger(clip["durationFrames"]),
               let assetDurationFrames = asset["durationFrames"]?.numberValue, isPositiveInteger(asset["durationFrames"]),
               let playbackRate, validFraction {
                let f = fraction.map { NativePlaybackRate(numerator: $0["numerator"]!.numberValue!, denominator: $0["denominator"]!.numberValue!) }
                let exceeds: Bool
                do {
                    if let rawRamp = clip["speedRamp"],
                       let ramp = try? rawRamp.decode(NativeSpeedRamp.self), ramp.isSupported {
                        let start = sourceInFrame + (f.map { $0.numerator / $0.denominator } ?? 0)
                        exceeds = start + ramp.sourcePosition(atClipFrame: durationFrames) > assetDurationFrames
                    } else {
                        exceeds = try sourceRangeExceedsAsset(sourceInFrame, durationFrames, playbackRate, assetDurationFrames, f)
                    }
                } catch {
                    // Overflow mapping: the exact answer needs more than 64 bits. The only way Int64 overflows with safe-integer
                    // inputs is an extreme rate/fraction denominator product; we report the clip as out of bounds, the
                    // same issue an out-of-range source value gets, so the document is rejected rather than accepted.
                    exceeds = true
                }
                if exceeds { pushIssue(&issues, .sourceOutOfBounds, clipPath, "Clip source range exceeds its asset duration") }
            }
            if let effects = clip["effects"]?.arrayValue {
                var effectIds = Set<String>()
                for (effectIndex, effect) in effects.enumerated() {
                    let effectPath = "\(clipPath).effects[\(effectIndex)]"
                    guard effect.isRecord else { pushIssue(&issues, .invalidEffect, effectPath, "Effect must be an object"); continue }
                    requireId(effect["id"], "\(effectPath).id", &issues)
                    collectDuplicateId(&effectIds, effect["id"], "\(effectPath).id", &issues)
                    if !isNonEmptyString(effect["effectId"]) { pushIssue(&issues, .invalidEffect, "\(effectPath).effectId", "Effect ID must be a non-empty string") }
                    if effect["enabled"]?.boolValue == nil { pushIssue(&issues, .invalidEffect, "\(effectPath).enabled", "Effect enabled must be a boolean") }
                    if effect["parameters"] != nil && !isRecordValue(effect["parameters"]) {
                        pushIssue(&issues, .invalidEffect, "\(effectPath).parameters", "Effect parameters must be an object")
                    }
                }
            } else {
                pushIssue(&issues, .invalidEffect, "\(clipPath).effects", "Effects must be an array")
            }
            validateParameterTracks(clip["parameterTracks"], projectFrameRate,
                                    isPositiveInteger(clip["durationFrames"]) ? clip["durationFrames"]!.numberValue! : nil,
                                    "\(clipPath).parameterTracks", &issues, engine: engine)
        }
    }
    return issues
}

private func validateSpeedRamp(_ raw: NativeJSONValue?, duration: Double?, path: String, issues: inout Issues) {
    guard let raw else { return }
    guard raw.isRecord, let version = raw["v"]?.numberValue, jsIsInteger(version),
          let kind = raw["kind"]?.stringValue else {
        pushIssue(&issues, .invalidSpeedRamp, path, "Speed ramp must be a versioned object with v and kind")
        return
    }
    // Forward-compatible objects are retained but intentionally not interpreted.
    guard version == Double(NativeSpeedRamp.version), kind == NativeSpeedRamp.supportedKind else { return }
    guard let points = raw["points"]?.arrayValue else {
        pushIssue(&issues, .invalidSpeedRamp, "\(path).points", "Speed ramp points must be an array")
        return
    }
    if points.isEmpty { pushIssue(&issues, .invalidSpeedRamp, "\(path).points", "Speed ramp needs at least one point") }
    if points.count > 64 { pushIssue(&issues, .invalidSpeedRamp, "\(path).points", "Speed ramp supports at most 64 points") }
    var previous = -Double.infinity
    for (index, point) in points.enumerated() {
        let p = "\(path).points[\(index)]"
        guard point.isRecord else { pushIssue(&issues, .invalidSpeedRamp, p, "Speed ramp point must be an object"); continue }
        if let t = point["t"]?.numberValue, t.isFinite {
            if t < 0 || (duration.map { t > $0 } ?? false) {
                pushIssue(&issues, .invalidSpeedRamp, "\(p).t", "Speed ramp point time must be within the clip")
            }
            if t <= previous { pushIssue(&issues, .invalidSpeedRamp, "\(p).t", "Speed ramp points must be strictly sorted by t") }
            previous = t
        } else { pushIssue(&issues, .invalidSpeedRamp, "\(p).t", "Speed ramp point time must be finite") }
        if !(point["speed"]?.numberValue.map { $0.isFinite && $0 >= 0.1 && $0 <= 10 } ?? false) {
            pushIssue(&issues, .invalidSpeedRamp, "\(p).speed", "Speed must be finite and between 0.1 and 10")
        }
        if let ease = point["ease"] {
            do { _ = try ease.decode(NativeInterpolation.self) }
            catch { pushIssue(&issues, .invalidSpeedRamp, "\(p).ease", "Speed ramp ease must be hold, linear, or cubic-bezier") }
        }
    }
}

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
// Gesture recording: turns a recorded pointer gesture into keyframes on the clip's parameter tracks.
import Foundation

public struct NativeRecordedKeyframe: Equatable, Sendable {
    public enum Property: Equatable, Sendable { case number(Double), string(String) }
    public var percentage: Double
    public var properties: NativeOrderedMap<Property>
    /// Easing of the segment arriving at this sample (velocity-fitter convention).
    public var ease: String?
    public init(percentage: Double, properties: NativeOrderedMap<Property>, ease: String? = nil) {
        self.percentage = percentage; self.properties = properties; self.ease = ease
    }
}

public struct NativeGestureRecordingError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}


/// `interpolation(ease)`: linear for missing/"none", else the fitter's
/// `custom(M0,0 Cx1,y1 x2,y2 1,1)` format, else throws.
public func nativeRecordedInterpolation(_ ease: String?) throws -> NativeInterpolation {
    guard let ease, !ease.isEmpty, ease != "none" else { return .linear }
    let fail = NativeGestureRecordingError(message: "Unsupported recorded gesture easing")
    let prefix = "custom(M0,0 C", suffix = " 1,1)"
    guard ease.hasPrefix(prefix), ease.hasSuffix(suffix), ease.count >= prefix.count + suffix.count else { throw fail }
    let body = ease.dropFirst(prefix.count).dropLast(suffix.count)   // "x1,y1 x2,y2"
    let pairs = body.split(separator: " ", omittingEmptySubsequences: false)
    guard pairs.count == 2 else { throw fail }
    var values: [Double] = []
    for pair in pairs {
        let parts = pair.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw fail }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }) else { throw fail }
            values.append(jsNumber(String(part)))
        }
    }
    return .cubicBezier(CubicBezierControlPoints(x1: values[0], y1: values[1], x2: values[2], y2: values[3]))
}

/// The property edit plan request without `properties` and `intent`.
public struct NativeGestureRecordingRequest: Sendable {
    public var selectedElement: NativeSelectedElementReference; public var playheadSeconds: Double
    public var selectionBounds: NativeSelectionBounds?; public var propertyBaselines: [String: Double]?; public var autoKeyframeEnabled: Bool?
    public init(selectedElement: NativeSelectedElementReference, playheadSeconds: Double, selectionBounds: NativeSelectionBounds? = nil,
                propertyBaselines: [String: Double]? = nil, autoKeyframeEnabled: Bool? = nil) {
        self.selectedElement = selectedElement; self.playheadSeconds = playheadSeconds; self.selectionBounds = selectionBounds
        self.propertyBaselines = propertyBaselines; self.autoKeyframeEnabled = autoKeyframeEnabled
    }
}

private func recordingError(_ m: String) -> NativeGestureRecordingError { .init(message: m) }

/// Replace the recorded interval atomically, preserving other properties and keys.
/// `properties` is a NativeOrderedMap, so samples reach the planner in input key order.
public func applyNativeGestureRecording(_ document: NativeProjectDocument, _ request: NativeGestureRecordingRequest, duration: Double,
                                        keys: [NativeRecordedKeyframe], engine: KeyframeEngine? = nil) throws -> NativeProjectDocument {
    if !duration.isFinite || duration <= 0 || keys.count < 2 { throw recordingError("A recording requires a positive duration and at least two samples") }
    let located: NativeLocatedClip
    switch resolveNativeClipSelection(document, request.selectedElement) {
    case .failure(let f): throw recordingError(f.message)
    case .success(let l): located = l
    }
    let clip = located.clip
    // Ordered maps (JS Map: re-set keeps the original position).
    var sampleKeys: [String] = []; var samples: [String: [NativeProjectAtomicPropertyCommand]] = [:]
    var incoming: [String: NativeInterpolation] = [:]
    var rangeKeys: [String] = []; var ranges: [String: (first: Double, last: Double)] = [:]
    var previous = -1.0
    for key in keys {
        if !key.percentage.isFinite || key.percentage < previous || key.percentage < 0 || key.percentage > 100 {
            throw recordingError("Recorded samples must be ordered within the recording interval")
        }
        previous = key.percentage
        let properties: [(String, NativePropertyInputValue)] = key.properties.keys.map { name in
            switch key.properties[name]! { case .number(let n): (name, .number(n)); case .string(let s): (name, .other(.string(s))) }
        }
        let planResult = planNativePropertyEdit(document, .init(selectedElement: request.selectedElement,
            playheadSeconds: request.playheadSeconds + duration * key.percentage / 100, properties: properties,
            selectionBounds: request.selectionBounds, propertyBaselines: request.propertyBaselines, intent: .keyframe,
            autoKeyframeEnabled: request.autoKeyframeEnabled))
        let plan: NativePropertyEditPlan
        switch planResult { case .failure(let f): throw recordingError(f.message); case .success(let p): plan = p }
        let arrival = try nativeRecordedInterpolation(key.ease)
        let outgoing = NativeInterpolation.linear
        for command in plan.commands {
            let upsert: NativeProjectAtomicKeyframeCommand, address: NativeProjectParameterAddress, frame: Double
            switch command {
            case .keyframe(.upsert(let a, let t, let f, let v, let b, _)):
                upsert = .upsert(address: a, valueType: t, frame: f, value: v, baselineValue: b, outgoing: outgoing); address = a; frame = f
            case .keyframe(.updateValue(let a, let f, let v)):
                upsert = .upsert(address: a, valueType: .number, frame: f, value: v, baselineValue: v, outgoing: outgoing); address = a; frame = f
            default: throw recordingError("Recording must produce native keyframes")
            }
            let id = address.parameterId
            if let r = ranges[id] { ranges[id] = (min(r.first, frame), frame) } else { rangeKeys.append(id); ranges[id] = (frame, frame) }
            let sampleId = jsJSONStringify(.array([.string(id), .number(frame)]))
            incoming[sampleId] = arrival
            if samples[sampleId] == nil { sampleKeys.append(sampleId) }
            samples[sampleId] = [.keyframe(upsert), .keyframe(.setOutgoing(address: address, frame: frame, outgoing: outgoing))]
        }
    }
    // Resolve frame collisions first, then transfer each retained destination's incoming ease to its preceding key.
    var preceding: [String: String] = [:]   // parameterId -> sample id
    for sampleId in sampleKeys {
        let parameterId = samples[sampleId]![0].address.parameterId
        if let priorId = preceding[parameterId] {
            let eased = incoming[sampleId]!
            samples[priorId] = samples[priorId]!.map { c in
                switch c {
                case .keyframe(.upsert(let a, let t, let f, let v, let b, _)): .keyframe(.upsert(address: a, valueType: t, frame: f, value: v, baselineValue: b, outgoing: eased))
                case .keyframe(.setOutgoing(let a, let f, _)): .keyframe(.setOutgoing(address: a, frame: f, outgoing: eased))
                default: c
                }
            }
        }
        preceding[parameterId] = sampleId
    }
    let commands = sampleKeys.flatMap { samples[$0]! }
    var deletes: [(address: NativeProjectParameterAddress, frames: [Double])] = []
    var cleared = Set<String>()
    for parameterId in rangeKeys {
        let range = ranges[parameterId]!
        let routed = routedPosition(clip, parameterId: parameterId)
        if routed != nil && (ranges["transform.position.x"] == nil || ranges["transform.position.y"] == nil) {
            throw recordingError("Recording a 2D motion path requires both position components")
        }
        guard let track = routed?.track ?? clip.parameterTracks.first(where: { $0.parameterId == parameterId }), !cleared.contains(track.id) else { continue }
        cleared.insert(track.id)
        let frames = track.keyframes.filter { $0.frame >= range.first && $0.frame <= range.last }.map(\.frame)
        if !frames.isEmpty {
            deletes.append((.init(sequenceId: document.sequence.id, trackId: located.trackId, clipId: clip.id, parameterId: track.parameterId), frames))
        }
    }
    func upsertAt(_ c: NativeProjectAtomicPropertyCommand) -> (String, Double)? {
        if case .keyframe(.upsert(let a, _, let f, _, _, _)) = c { return (a.parameterId, f) }; return nil
    }
    // Keep a vec2 track present while replacing its keys: inserting first prevents deleting its last original key.
    let filteredDeletes: [NativeProjectAtomicPropertyCommand] = deletes.compactMap { d in
        let frames = d.frames.filter { frame in !commands.contains { c in
            guard let (pid, f) = upsertAt(c), f == frame else { return false }
            return pid == d.address.parameterId || (d.address.parameterId == "transform.position" && pid.hasPrefix("transform.position."))
        } }
        return frames.isEmpty ? nil : .keyframe(.deleteMany(address: d.address, frames: frames))
    }
    let result = try applyNativeProjectPropertyCommand(document, .batch(commands + filteredDeletes), engine: engine)
    if let f = result.failure { throw recordingError(f.message) }
    // A recorded trajectory replaces spatial handles on its authored segments.
    let positionFrames = Set(commands.compactMap { c -> Double? in
        guard let (pid, f) = upsertAt(c), pid == "transform.position.x" else { return nil }; return f
    })
    var out = result.document
    for t in out.sequence.tracks.indices { for c in out.sequence.tracks[t].clips.indices where out.sequence.tracks[t].clips[c].id == clip.id {
        for p in out.sequence.tracks[t].clips[c].parameterTracks.indices where out.sequence.tracks[t].clips[c].parameterTracks[p].parameterId == "transform.position" {
            for k in out.sequence.tracks[t].clips[c].parameterTracks[p].keyframes.indices
            where positionFrames.contains(out.sequence.tracks[t].clips[c].parameterTracks[p].keyframes[k].frame) {
                out.sequence.tracks[t].clips[c].parameterTracks[p].keyframes[k].outgoingPath = nil
            }
        }
    } }
    return out
}

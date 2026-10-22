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
// Validation of `clip.moves` (NativeProjectDocumentValidation). Every bad value is one `invalid-move` issue at its
// path; nothing is clamped. A version other than 1, or a kind this build does not know, is not an error: the object
// is kept as stored and not drawn (NativeClipMovesDocument.swift).
import Foundation

typealias MoveIssues = [NativeProjectDocumentValidationIssue]

/// The clip's style, text and moves, in that order (NativeProjectDocumentValidation's clip loop).
func validateNativeClipMoves(_ moves: NativeJSONValue?, clipDuration: Double?, _ path: String, _ issues: inout MoveIssues) {
    guard let moves else { return }
    guard moves.isRecord else { return pushIssue(&issues, .invalidMove, path, "Moves must be an object") }
    guard let v = moves["v"]?.numberValue, jsIsInteger(v), v >= 1 else {
        return pushIssue(&issues, .invalidMove, "\(path).v", "Moves need a version v, a positive integer")
    }
    guard v == Double(NativeClipMoves.currentVersion) else { return }   // a newer version: kept, not drawn
    var edgeFrames = 0.0
    for edge in NativeMoveEdge.allCases {
        if let f = validateNativeEdgeMove(moves[edge.rawValue], "\(path).\(edge.rawValue)", &issues) { edgeFrames += f }
    }
    validateNativeLoopMove(moves["loop"], "\(path).loop", &issues)
    if let clipDuration, edgeFrames > clipDuration {
        pushIssue(&issues, .invalidMove, path, "In and Out moves together must not be longer than the clip")
    }
}

/// Validates one In or Out; returns its frames when they are valid (for the In + Out length rule).
private func validateNativeEdgeMove(_ move: NativeJSONValue?, _ path: String, _ issues: inout MoveIssues) -> Double? {
    guard let move else { return nil }
    guard move.isRecord else { pushIssue(&issues, .invalidMove, path, "A move must be an object"); return nil }
    guard let kindName = moveKindName(move, path, &issues), let kind = NativeEdgeMoveKind(rawValue: kindName) else { return nil }
    let frames = move["frames"]
    let validFrames = isPositiveInteger(frames)
    if !validFrames { pushIssue(&issues, .invalidMove, "\(path).frames", "Move frames must be a positive integer") }
    validateNativeMoveDirection(move["direction"], kind, "\(path).direction", &issues)
    validateNativeMoveAmount(move["amount"], kind.rawValue, kind.accepts(amount:), "\(path).amount", &issues)
    validateNativeMoveEase(move["ease"], "\(path).ease", &issues)
    return validFrames ? frames?.numberValue : nil
}

private func validateNativeLoopMove(_ loop: NativeJSONValue?, _ path: String, _ issues: inout MoveIssues) {
    guard let loop else { return }
    guard loop.isRecord else { return pushIssue(&issues, .invalidMove, path, "A loop move must be an object") }
    guard let kindName = moveKindName(loop, path, &issues), let kind = NativeLoopMoveKind(rawValue: kindName) else { return }
    let period = loop["periodFrames"]
    if !isPositiveInteger(period) || (period?.numberValue ?? 0) < 2 || jsRemainder(period?.numberValue ?? 0, 2) != 0 {
        pushIssue(&issues, .invalidMove, "\(path).periodFrames", "Loop period must be an even number of frames, at least 2")
    }
    validateNativeMoveAmount(loop["amount"], kind.rawValue, kind.accepts(amount:), "\(path).amount", &issues)
    validateNativeMoveEase(loop["ease"], "\(path).ease", &issues)
}

private func validateNativeMoveDirection(_ d: NativeJSONValue?, _ kind: NativeEdgeMoveKind, _ path: String, _ issues: inout MoveIssues) {
    guard let d else { return }
    if !kind.takesDirection {
        pushIssue(&issues, .invalidMove, path, "Only a slide move takes a direction")
    } else if d.stringValue.flatMap(NativeMoveDirection.init(rawValue:)) == nil {
        pushIssue(&issues, .invalidMove, path, "Move direction must be left, right, up or down")
    }
}

private func validateNativeMoveAmount(_ a: NativeJSONValue?, _ kind: String, _ accepts: (Double) -> Bool, _ path: String,
                                      _ issues: inout MoveIssues) {
    guard let a else { return }
    if !(a.numberValue.map(accepts) ?? false) { pushIssue(&issues, .invalidMove, path, "Move amount is outside the range of a \(kind) move") }
}

/// The move's kind as a string; a missing or non-string kind is an issue. An unknown string is returned and the
/// caller skips the rest of the move (kept, not drawn).
private func moveKindName(_ move: NativeJSONValue, _ path: String, _ issues: inout MoveIssues) -> String? {
    guard let name = move["kind"]?.stringValue, !name.isEmpty else {
        pushIssue(&issues, .invalidMove, "\(path).kind", "A move needs a kind")
        return nil
    }
    return name
}

/// `ease` is a keyframe interpolation: hold, linear, or cubic-bezier with finite control points and x1, x2 in 0…1.
private func validateNativeMoveEase(_ ease: NativeJSONValue?, _ path: String, _ issues: inout MoveIssues) {
    guard let ease else { return }
    guard ease.isRecord, let parsed = nativeMoveInterpolation(ease) else {
        return pushIssue(&issues, .invalidMove, path, "Move ease must be hold, linear or cubic-bezier with four control points")
    }
    guard case .cubicBezier(let p) = parsed else { return }
    let finite = [p.x1, p.y1, p.x2, p.y2].allSatisfy(\.isFinite)
    if !finite || !(0...1).contains(p.x1) || !(0...1).contains(p.x2) {
        pushIssue(&issues, .invalidMove, "\(path).controlPoints", "Move ease control points must be finite, with x1 and x2 within 0…1")
    }
}

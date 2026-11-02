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
// Validator rules for the camera-moves effect (issue #307): every bad value is one typed issue, nothing is clamped.
import Foundation

private typealias CameraIssues = [NativeProjectDocumentValidationIssue]

func validateNativeCameraMoves(_ parameters: NativeJSONValue, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let v = parameters["v"]?.numberValue, jsIsInteger(v), v >= 1 else {
        return pushIssue(&issues, .invalidEffect, "\(path).v", "Camera moves need a version v, a positive integer")
    }
    guard v == Double(NativeCameraMoves.currentVersion) else { return }   // a newer version: kept, not drawn
    if let a = parameters["allowEdges"], a.boolValue == nil {
        pushIssue(&issues, .invalidEffect, "\(path).allowEdges", "Camera moves allowEdges must be a boolean")
    }
    cameraSection(parameters["shake"], "\(path).shake", &issues) { s, p, i in
        cameraNumber(s["amount"], 0, 200, "\(p).amount", "Shake amount must be from 0 through 200 px", &i)
        cameraNumber(s["frequency"], 0, NativeCameraMoves.maxShakeFrequency, "\(p).frequency", "Shake frequency must be above 0 and at most 5 Hz", &i, lowerOpen: true)
        cameraNumber(s["rotation"], 0, 45, "\(p).rotation", "Shake rotation must be from 0 through 45 degrees", &i)
        if let seed = s["seed"], !(nativeMoveInteger(seed).map { $0 >= 0 && $0 <= 4_294_967_295 } ?? false) {
            pushIssue(&i, .invalidEffect, "\(p).seed", "Shake seed must be an integer from 0 through 4294967295")
        }
    }
    cameraSection(parameters["punch"], "\(path).punch", &issues) { s, p, i in
        cameraNumber(s["scale"], 1, 1.5, "\(p).scale", "Punch-in scale must be from 1 through 1.5", &i)
        cameraInteger(s["lengthFrames"], 1, 3600, "\(p).lengthFrames", "Punch-in length must be a whole number of frames from 1 through 3600", &i)
        cameraInteger(s["everyFrames"], 1, 1_000_000, "\(p).everyFrames", "Punch-in every must be a positive whole number of frames", &i)
        if let at = s["at"] {
            let ok = at.arrayValue.map { $0.allSatisfy { nativeMoveInteger($0).map { $0 >= 0 } ?? false } } ?? false
            if !ok { pushIssue(&i, .invalidEffect, "\(p).at", "Punch-in at must be a list of whole frames, 0 or later") }
        }
        cameraEase(s["ease"], "\(p).ease", &i)
    }
    cameraSection(parameters["push"], "\(path).push", &issues) { s, p, i in
        cameraNumber(s["startScale"], 0.5, 3, "\(p).startScale", "Push start scale must be from 0.5 through 3", &i)
        cameraNumber(s["endScale"], 0.5, 3, "\(p).endScale", "Push end scale must be from 0.5 through 3", &i)
        cameraNumber(s["drift"], 0, 50, "\(p).drift", "Push drift must be from 0 through 50 percent", &i)
        if let d = s["direction"], d.stringValue.flatMap(NativeMoveDirection.init(rawValue:)) == nil {
            pushIssue(&i, .invalidEffect, "\(p).direction", "Push direction must be left, right, up or down")
        }
        cameraEase(s["ease"], "\(p).ease", &i)
    }
}

private func cameraSection(_ s: NativeJSONValue?, _ path: String, _ issues: inout CameraIssues,
                           _ check: (NativeJSONValue, String, inout CameraIssues) -> Void) {
    guard let s else { return }
    guard s.isRecord else { return pushIssue(&issues, .invalidEffect, path, "A camera move section must be an object") }
    guard let v = s["v"]?.numberValue, jsIsInteger(v), v >= 1 else {
        return pushIssue(&issues, .invalidEffect, "\(path).v", "A camera move section needs a version v, a positive integer")
    }
    if v == Double(NativeCameraMoves.currentVersion) { check(s, path, &issues) }
}

private func cameraNumber(_ v: NativeJSONValue?, _ lo: Double, _ hi: Double, _ path: String, _ text: String, _ issues: inout CameraIssues,
                          lowerOpen: Bool = false) {
    guard let v else { return }
    guard let n = v.numberValue, n.isFinite, lowerOpen ? n > lo : n >= lo, n <= hi else { return pushIssue(&issues, .invalidEffect, path, text) }
}

private func cameraInteger(_ v: NativeJSONValue?, _ lo: Int, _ hi: Int, _ path: String, _ text: String, _ issues: inout CameraIssues) {
    guard let v else { return }
    guard let n = nativeMoveInteger(v), n >= lo, n <= hi else { return pushIssue(&issues, .invalidEffect, path, text) }
}

private func cameraEase(_ e: NativeJSONValue?, _ path: String, _ issues: inout CameraIssues) {
    guard let e else { return }
    guard e.isRecord, let parsed = nativeMoveInterpolation(e) else {
        return pushIssue(&issues, .invalidEffect, path, "Camera move ease must be hold, linear or cubic-bezier with four control points")
    }
    if case .cubicBezier(let p) = parsed, !([p.x1, p.y1, p.x2, p.y2].allSatisfy(\.isFinite) && (0...1).contains(p.x1) && (0...1).contains(p.x2)) {
        pushIssue(&issues, .invalidEffect, "\(path).controlPoints", "Camera move ease control points must be finite, with x1 and x2 within 0 to 1")
    }
}

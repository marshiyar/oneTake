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

internal func validateNativeTextStyles(_ raw: NativeJSONValue?, _ issues: inout [NativeProjectDocumentValidationIssue])
    -> Set<String>
{
    guard let raw else {
        return []
    }
    guard let styles = raw.arrayValue else {
        pushIssue(&issues, .invalidRoot, "textStyles", "Text styles must be an array")
        return []
    }
    var ids = Set<String>()
    for (index, style) in styles.enumerated() {
        let path = "textStyles[\(index)]"
        guard validateTextStyleContract(style, path, &issues) else { continue }
        requireId(style["id"], "\(path).id", &issues)
        collectDuplicateId(&ids, style["id"], "\(path).id", &issues)
        guard style["v"] == .number(1), style["kind"] == .string("text-style") else { continue }
        if !isNonEmptyString(style["name"]) {
            pushIssue(&issues, .invalidRoot, "\(path).name", "Style name must not be empty")
        }
        if style["text"] == nil { pushIssue(&issues, .invalidRoot, "\(path).text", "Style text is required") }
        validateNativeClipText(style["text"], "\(path).text", &issues)
    }
    return ids
}

internal func validateNativeTextStyleLink(
    _ clip: NativeJSONValue,
    _ ids: Set<String>,
    _ path: String,
    _ issues: inout [NativeProjectDocumentValidationIssue]
) {
    guard let link = clip["textStyle"] else {
        return
    }
    let path = "\(path).textStyle"
    guard validateTextStyleContract(link, path, &issues), link["v"] == .number(1), link["kind"] == .string("text-style")
    else {
        return
    }
    if clip["text"] == nil { pushIssue(&issues, .invalidClip, path, "Only text layers can link to a text style") }
    if link["styleId"]?.stringValue.map(ids.contains) != true {
        pushIssue(&issues, .invalidClip, "\(path).styleId", "Unknown text style id")
    }
    if let overrides = link["overrides"] {
        guard let fields = overrides.arrayValue else {
            pushIssue(&issues, .invalidClip, "\(path).overrides", "Overrides must be an array")
            return
        }
        var seen = Set<String>()
        for (index, field) in fields.enumerated() {
            guard let name = field.stringValue, NativeTextStyle.fields.contains(name), seen.insert(name).inserted else {
                pushIssue(
                    &issues, .invalidClip, "\(path).overrides[\(index)]", "Unknown or duplicate text style override"
                )
                continue
            }
        }
    }
}

private func validateTextStyleContract(
    _ raw: NativeJSONValue,
    _ path: String,
    _ issues: inout [NativeProjectDocumentValidationIssue]
) -> Bool {
    guard raw.isRecord else {
        pushIssue(&issues, .invalidClip, path, "Text style record must be an object")
        return false
    }
    var valid = true
    if !isPositiveInteger(raw["v"]) {
        pushIssue(&issues, .invalidClip, "\(path).v", "Style version must be a positive integer")
        valid = false
    }
    if !isNonEmptyString(raw["kind"]) {
        pushIssue(&issues, .invalidClip, "\(path).kind", "Style kind must be a nonempty string")
        valid = false
    }
    return valid
}

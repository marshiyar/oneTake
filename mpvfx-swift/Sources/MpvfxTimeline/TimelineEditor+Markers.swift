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
import MpvfxShared

public extension TimelineEditor {
    @discardableResult
    func addMarker(at time: Double, name: String = "Marker", color: String = NativeSequenceMarker.defaultColor, note: String = "") -> String? {
        let id = "marker:" + UUID().uuidString.lowercased()
        var d = document
        var markers = d.sequence.markers ?? []
        markers.append(.init(id: id, time: time, name: name, color: color, note: note))
        markers.sort { $0.time < $1.time }
        d.sequence.markers = markers
        return commitPresets(d, label: "Add marker") ? id : nil
    }

    /// Replaces all editable fields atomically, preserving the stable marker id.
    @discardableResult
    func updateMarker(_ marker: NativeSequenceMarker) -> Bool {
        var d = document
        guard var markers = d.sequence.markers,
              let i = markers.firstIndex(where: { $0.id == marker.id }) else { return false }
        var preserved = marker
        preserved.spread = markers[i].spread
        guard markers[i] != preserved else { return false }
        markers[i] = preserved
        markers.sort { $0.time < $1.time }
        d.sequence.markers = markers
        return commitPresets(d, label: "Edit marker")
    }

    @discardableResult
    func deleteMarker(_ id: String) -> Bool {
        var d = document
        guard d.sequence.markers?.contains(where: { $0.id == id }) == true else { return false }
        d.sequence.markers?.removeAll { $0.id == id }
        return commitPresets(d, label: "Delete marker")
    }
}

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
import MpvfxTimeline

/// The Look section's edits (issue #281): outline and shadow values that can be keyframed. A value is stored in
/// `clip.text.look` until it is animated, then in a parameter track (NativeTextLookParameter). Every call is one
/// undo step and is refused on a locked track.
public extension TimelineEditor {
    static let defaultOutlineWidth = 2.0
    static let defaultOutlineColor = "#000000"
    static let defaultShadow = NativeTextLook.Shadow(x: 2, y: 2, blur: 4, color: "#000000b3")
    static let defaultGlow = NativeTextLook.Glow(color: "#ffffff")
    static let defaultPlate = NativeTextLook.Plate(paddingX: 12, paddingY: 6, radius: 8, color: "#000000b3")
    static let defaultFill = NativeTextLook.Fill(from: "#ffffff", to: "#ff7a00")

    /// The look value at `time`: the keyed value when it is animated, otherwise the stored one.
    func textLookValue(clipId: String, _ id: String, time: Double) -> Double? {
        if isAnimated(clipId: clipId, id) { return numberValue(clipId: clipId, id, time: time) }
        return NativeTextLookParameter.value(of: id, in: clipText(clipId: clipId)?.look)
    }

    /// Sets a look value, held to its range: a keyframe at `time` when the value is animated, otherwise the stored
    /// value. False when the look has no such part or nothing changed.
    @discardableResult
    func setTextLookValue(clipId: String, _ id: String, _ value: Double, time: Double) -> Bool {
        let look = clipText(clipId: clipId)?.look
        guard let range = NativeTextLookParameter.range(of: id), value.isFinite,
              NativeTextLookParameter.value(of: id, in: look) != nil else { return false }
        let held = min(max(value, range.lowerBound), range.upperBound)
        if isAnimated(clipId: clipId, id) { return setParameter(clipId: clipId, id, .number(held), time: time) }
        guard let next = NativeTextLookParameter.setting(held, id: id, in: look) else { return false }
        return setTextLook(clipId: clipId, next)
    }

    /// Stopwatch off: the keys go and the value at `time` stays in the look, as one undo step.
    @discardableResult
    func stopAnimatingTextLook(clipId: String, _ id: String, time: Double) -> Bool {
        guard !isClipLocked(clipId), isAnimated(clipId: clipId, id),
              let held = numberValue(clipId: clipId, id, time: time) else { return false }
        return withHistory("Stop animating property") {
            editTextLook(clipId: clipId, dropping: [id]) { look in
                if let next = NativeTextLookParameter.setting(held, id: id, in: look) { look = next }
                return true
            }
        }
    }

    /// Adds an outline after the existing ones (at most two).
    @discardableResult
    func addTextLookOutline(clipId: String) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            var next = look ?? NativeTextLook()
            guard next.isSupported, (next.outlines ?? []).count < NativeTextLook.maxOutlines else { return false }
            next.outlines = (next.outlines ?? []) + [.init(width: Self.defaultOutlineWidth, color: Self.defaultOutlineColor)]
            look = next
            return true
        }
    }

    /// Removes the last outline together with its keys, so no later outline changes its parameter.
    @discardableResult
    func removeLastTextLookOutline(clipId: String) -> Bool {
        let count = clipText(clipId: clipId)?.look?.outlines?.count ?? 0
        guard count > 0 else { return false }
        return editTextLook(clipId: clipId, dropping: NativeTextLookParameter.ids(ofOutline: count - 1)) { look in
            guard var next = look, next.isSupported, var outlines = next.outlines, !outlines.isEmpty else { return false }
            outlines.removeLast()
            next.outlines = outlines.isEmpty ? nil : outlines
            look = next
            return true
        }
    }

    /// Sets an outline's colour and, when given, its position.
    @discardableResult
    func setTextLookOutline(clipId: String, index: Int, color: String? = nil, position: String? = nil) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            guard var next = look, next.isSupported, var outlines = next.outlines, outlines.indices.contains(index) else { return false }
            if let color { guard isNativeHexColor(color) else { return false }; outlines[index].color = color }
            if let position {
                guard NativeTextLook.positions.contains(position) else { return false }
                outlines[index].position = position == "outside" ? nil : position
            }
            next.outlines = outlines
            look = next
            return true
        }
    }

    @discardableResult
    func addTextLookShadow(clipId: String) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            var next = look ?? NativeTextLook()
            guard next.isSupported, next.shadow == nil else { return false }
            next.shadow = Self.defaultShadow
            look = next
            return true
        }
    }

    /// Removes the shadow together with the keys of its offset and blur.
    @discardableResult
    func removeTextLookShadow(clipId: String) -> Bool {
        editTextLook(clipId: clipId, dropping: NativeTextLookParameter.shadowIds) { look in
            guard var next = look, next.isSupported, next.shadow != nil else { return false }
            next.shadow = nil
            look = next
            return true
        }
    }

    @discardableResult
    func setTextLookShadowColor(clipId: String, _ color: String) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            guard var next = look, next.isSupported, var shadow = next.shadow, isNativeHexColor(color) else { return false }
            shadow.color = color
            next.shadow = shadow
            look = next
            return true
        }
    }

    // MARK: Glow, plate and gradient fill

    @discardableResult
    func addTextLookGlow(clipId: String) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            var next = look ?? NativeTextLook()
            guard next.isSupported, next.glow == nil else { return false }
            next.glow = Self.defaultGlow
            look = next
            return true
        }
    }

    @discardableResult
    func removeTextLookGlow(clipId: String) -> Bool {
        editTextLook(clipId: clipId, dropping: NativeTextLookParameter.glowIds) { look in
            guard var next = look, next.isSupported, next.glow != nil else { return false }
            next.glow = nil
            look = next
            return true
        }
    }

    /// The glow's radius (px) and colour; a default radius is stored as an absent key.
    @discardableResult
    func setTextLookGlow(clipId: String, radius: Double? = nil, color: String? = nil) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            guard var next = look, next.isSupported, var glow = next.glow else { return false }
            if let radius {
                guard radius.isFinite else { return false }
                let held = min(max(radius, NativeTextLook.glowRadiusRange.lowerBound), NativeTextLook.glowRadiusRange.upperBound)
                glow.radius = held == NativeTextLook.defaultGlowRadius ? nil : held
            }
            if let color { guard isNativeHexColor(color) else { return false }; glow.color = color }
            next.glow = glow
            look = next
            return true
        }
    }

    @discardableResult
    func addTextLookPlate(clipId: String) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            var next = look ?? NativeTextLook()
            guard next.isSupported, next.plate == nil else { return false }
            next.plate = Self.defaultPlate
            look = next
            return true
        }
    }

    @discardableResult
    func removeTextLookPlate(clipId: String) -> Bool {
        editTextLook(clipId: clipId, dropping: NativeTextLookParameter.plateIds) { look in
            guard var next = look, next.isSupported, next.plate != nil else { return false }
            next.plate = nil
            look = next
            return true
        }
    }

    /// The plate's mode (`line` or `block`), padding, corner radius (px) and colour. Defaults are stored as absent keys.
    /// A new colour keeps the opacity the plate has now unless it names its own alpha.
    @discardableResult
    func setTextLookPlate(clipId: String, mode: String? = nil, paddingX: Double? = nil, paddingY: Double? = nil,
                          radius: Double? = nil, color: String? = nil) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            guard var next = look, next.isSupported, var plate = next.plate else { return false }
            func held(_ v: Double, _ range: ClosedRange<Double>) -> Double? {
                guard v.isFinite else { return nil }
                let h = min(max(v, range.lowerBound), range.upperBound)
                return h == 0 ? nil : h
            }
            if let mode { guard NativeTextLook.plateModes.contains(mode) else { return false }; plate.mode = mode == "line" ? nil : mode }
            if let paddingX { guard paddingX.isFinite else { return false }; plate.paddingX = held(paddingX, NativeTextLook.platePaddingRange) }
            if let paddingY { guard paddingY.isFinite else { return false }; plate.paddingY = held(paddingY, NativeTextLook.platePaddingRange) }
            if let radius { guard radius.isFinite else { return false }; plate.radius = held(radius, NativeTextLook.plateRadiusRange) }
            if let color { guard isNativeHexColor(color) else { return false }; plate.color = color }
            next.plate = plate
            look = next
            return true
        }
    }

    @discardableResult
    func addTextLookFill(clipId: String) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            var next = look ?? NativeTextLook()
            guard next.isSupported, next.fill == nil else { return false }
            next.fill = Self.defaultFill
            look = next
            return true
        }
    }

    @discardableResult
    func removeTextLookFill(clipId: String) -> Bool {
        editTextLook(clipId: clipId, dropping: NativeTextLookParameter.fillIds) { look in
            guard var next = look, next.isSupported, next.fill != nil else { return false }
            next.fill = nil
            look = next
            return true
        }
    }

    @discardableResult
    func setTextLookFill(clipId: String, from: String? = nil, to: String? = nil) -> Bool {
        editTextLook(clipId: clipId, dropping: []) { look in
            guard var next = look, next.isSupported, var fill = next.fill else { return false }
            if let from { guard isNativeHexColor(from) else { return false }; fill.from = from }
            if let to { guard isNativeHexColor(to) else { return false }; fill.to = to }
            next.fill = fill
            look = next
            return true
        }
    }

    /// One validated edit of the look and of the keys that go with it. `body` returns false when it changes nothing.
    /// A linked text layer keeps the link and overrides only its look, as every other text edit does.
    private func editTextLook(clipId: String, dropping ids: [String], _ body: (inout NativeTextLook?) -> Bool) -> Bool {
        let styles = document.textStyles ?? []
        return editClip(clipId) { c in
            guard let before = resolvedText(c, styles) else { return false }
            var look = before.look
            guard body(&look) else { return false }
            c.parameterTracks.removeAll { ids.contains($0.parameterId) }
            var t = before
            t.look = (look?.isEmpty ?? true) ? nil : look
            if var link = c.textStyle, t != before {
                link.overrides = Set(link.overrides + changedNativeTextStyleFields(before, t)).sorted()
                c.textStyle = link
            }
            c.text = t
            return true
        }
    }
}

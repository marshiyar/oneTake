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
import MpvfxCanvas
import MpvfxTimeline

/// Row descriptors of the flat inspector. Rows are rebuilt from the document
/// on every draw and event; they carry closures that edit through TimelineEditor, never state of their own.
public struct InspectorRow {
    public enum KeyframeState: Equatable { case none, animated, onKey }
    public struct Keyframe {
        public var state: KeyframeState
        /// ◆: add the key at the playhead, or remove the one there.
        public var toggle: () -> Void
        /// Stopwatch: start animating (a key at the playhead), or stop (drop every key, keep the playhead's value).
        public var stopwatch: () -> Void
        public var prev: (() -> Void)?
        public var next: (() -> Void)?
        /// The property's kind and the playhead key's interpolation: the ◆ draws the timeline's mark for them.
        public var kind: TimelineKeyframeKind = .transform
        public var ease: TimelineKeyframeEase = .linear
    }
    public struct Number {
        public var key: String
        public var label: String
        public var text: String
        public var tier: PropertyValueTier
        public var commit: (String) -> Void
        public var reset: (() -> Void)?
        public var keyframe: Keyframe?
        /// Label drag scrubs the value: (current value, units per pixel, apply on release).
        public var scrub: (value: Double, step: Double, apply: (Double) -> Void, format: (Double) -> String)?
        public var disabled = false
        public var icon: PanelIcon? = nil
        /// Shown in the normal ink and focusable, its text selected while focused, but never edited (Media start).
        public var readOnly = false
        /// A colour value's swatch before its text (issue #189): `color` nil draws the checkerboard; a press on its
        /// 24 pt target presses the button `key` (the row's controls carry it).
        public var swatch: Swatch?
    }
    public struct Swatch {
        public var color: String?
        public var key: String
    }
    public struct Slider {
        public var key: String
        public var label: String
        public var position: Double
        public var min: Double, max: Double
        public var display: String
        public var format: (Double) -> String
        public var tier: PropertyValueTier
        public var centerTick = false
        public var commit: (Double) -> Void
        public var reset: (() -> Void)?
        public var keyframe: Keyframe?
        public var disabled = false
        public var icon: PanelIcon? = nil
        /// A trailing 12px settings gear after the slider (`flex items-center gap-1.5`, Finish rows).
        public var settings: (active: Bool, toggle: () -> Void)?
        /// Drags along y, bottom = min (the Tone EQ's faders).
        public var vertical = false
        /// A detent: a drag within `detentReach` of the track's span from it lands on it (Rate's 1x).
        public var detent: Double?
        public static let detentReach = 0.03
    }
    public struct Toggle {
        public var key: String
        public var label: String
        public var on: Bool
        public var tier: PropertyValueTier = .default
        public var set: (Bool) -> Void
        public var reset: (() -> Void)?
    }
    public struct Segmented {
        public var key: String
        public var label: String
        public var options: [(key: String, label: String, active: Bool)]
        public var select: (String) -> Void
        /// Optional vector icons; option labels remain the tooltip and accessible name.
        public var icons: [String: PanelIcon] = [:]
    }
    public struct Button {
        public enum Style { case accent, muted, danger, chip, chipActive }
        public var key: String
        public var label: String
        public var style: Style
        public var action: () -> Void
        public var disabled = false
        public var icon: PanelIcon? = nil
    }
    public struct FxNode {
        public var key: String
        public var label: String
        public var detail: String
        public var enabled: Bool
        public var toggle: () -> Void
        public var remove: () -> Void
    }

    public enum Kind {
        case number(Number)
        /// Two compact fields side by side (Position X/Y, Size W/H, crop T/R/B/L uses `quad`).
        case pair(label: String, Number, Number)
        case quad([Number])
        case slider(Slider)
        case toggle(Toggle)
        case segmented(Segmented)
        /// `text-[10px] font-medium uppercase tracking-wider text-panel-text-2` with an optional trailing note.
        case heading(String, trailing: String?)
        /// A Grade section top: `border-t border-panel-hairline pt-1.5` and its `text-[9px] font-semibold uppercase
        /// tracking-[0.12em] text-panel-text-5` title (1 + 6 + 13.5).
        case section(String)
        /// `text-[11px] font-semibold text-panel-text-1` sub-header with trailing buttons (Crop row).
        case subheader(String, buttons: [Button])
        case note(String)
        case buttons([Button])
        case fxNode(FxNode)
        case spacer(Double)
        /// A bespoke control (color wheels, curve graph, preset grid) drawn and driven by `InspectorCustomRow`.
        case custom(InspectorCustomRow)
    }

    public var kind: Kind
    /// Vertical padding around the row (`py-1` on the Size group).
    public var padY: Double = 0
    /// Inside an effect editor (`border-l-2 border-panel-border-input pl-2.5`): a 2px rail at the left, content 12 in.
    public var rail = false
    /// The controls a bespoke row draws itself (its buttons, sliders and fields, and the picks of a menu it opens),
    /// as plain descriptors: hits on the row resolve through them, and a scripted drive (smoke stress, tests)
    /// reaches them by key like any other row. Never drawn on their own.
    public var controls: [InspectorRow] = []
    public init(_ kind: Kind, padY: Double = 0, rail: Bool = false, controls: [InspectorRow] = []) {
        self.kind = kind; self.padY = padY; self.rail = rail; self.controls = controls
    }

    /// Set by the inspector's layout pass (`InspectorPanel.laidOut`) when a segmented row's options do not fit in the
    /// control column: the label takes its own line and the options the row's full width below it (issue #154).
    public var stacked = false

    public var height: Double { baseHeight + 2 * padY }

    /// The row's slot in the layout: its height rounded up to the 8 pt grid (`PanelGrid`), so the next row starts on
    /// the grid. A spacer keeps its own height.
    public var slotHeight: Double {
        if case .spacer(let h) = kind { return h }
        return PanelGrid.snapUp(height)
    }

    var baseHeight: Double {
        let row = PanelGrid.rowHeight, compact = PanelGrid.compactRowHeight
        switch kind {
        case .toggle, .fxNode, .quad, .buttons, .subheader: return row
        case .pair: return compact + row * (stacked ? 2 : 1)   // the heading line over the fields
        case .number, .slider, .segmented: return stacked ? compact + row : row
        case .heading, .section: return compact
        case .note(let s): return PanelGrid.lineHeight * Double(max(1, (s.count + 47) / 48))
        case .spacer(let h): return h
        case .custom(let c): return c.height
        }
    }
}

/// One accordion group (FlatGroupDescriptor).
public struct InspectorGroup {
    public var id: String
    public var title: String
    public var summary: String
    public var rows: [InspectorRow]
    /// Gap between rows: 0 or a whole number of `PanelGrid.unit` steps, so every row starts on the grid.
    public var spacing: Double
    /// The open header's reset accessory (12px RotateCcw left of the caret, `gap-2.5`), when the group has one.
    public var reset: (() -> Void)?
    /// Optional bypass in the header. The hit target is at least 24 points and is exposed by `accessibilityLabel`.
    public var enabled: Bool?
    public var accessibilityLabel: String?
    public var setEnabled: ((Bool) -> Void)?
    public init(id: String, title: String, summary: String, rows: [InspectorRow], spacing: Double = 0) {
        self.id = id; self.title = title; self.summary = summary; self.rows = rows; self.spacing = spacing
    }
    /// Every row with the controls bespoke rows carry, in order: what a key lookup searches.
    public var addressableRows: [InspectorRow] { rows.flatMap { [$0] + $0.controls } }
}

/// Audio gain fader: unity at the fader midpoint, -60…+12 dB.
public enum AudioGainFader {
    public static let min = -100.0, max = 100.0
    static let minDb = -60.0, maxDb = 12.0
    public static let maxGain = pow(10, maxDb / 20)
    public static func clamp(_ g: Double) -> Double { g.isFinite ? Swift.max(0, Swift.min(maxGain, g)) : 1 }
    public static func gain(position p: Double) -> Double {
        let s = Swift.max(min, Swift.min(max, p))
        if s == min { return 0 }
        let db = s < 0 ? (s / abs(min)) * abs(minDb) : (s / max) * maxDb
        return pow(10, db / 20)
    }
    public static func position(gain g: Double) -> Double {
        let s = clamp(g)
        if s == 0 { return min }
        let db = 20 * log10(s)
        let p = db < 0 ? (db / abs(minDb)) * abs(min) : (db / maxDb) * max
        return Swift.max(min, Swift.min(max, p))
    }
    public static func text(_ g: Double) -> String {
        let s = clamp(g)
        if s == 0 { return "-∞ dB" }
        let db = 20 * log10(s)
        let r = abs(db) < 0.05 ? 0 : db
        return (r > 0 ? "+" : "") + String(format: "%.1f", r) + " dB"
    }
}

/// A custom row: draws itself and records hits as `.custom(id, part)`; pointer events come back with the part.
public struct InspectorCustomRow {
    public var id: String
    public var height: Double
    public var draw: (CanvasContext, CanvasRect, InspectorPanel) -> Void
    /// (part, point, phase) — phase: 0 down, 1 drag, 2 up.
    public var pointer: (Int, CanvasPoint, Int) -> Void
    /// Keys for a focused part (part, key) -> handled. A row with a handler is never "pressed" by Enter or Space:
    /// a press replays a pointer at the part's centre, which on a wheel or graph is an edit (issue #171).
    public var keyPress: ((Int, EditorKey) -> Bool)?
    public init(id: String, height: Double, draw: @escaping (CanvasContext, CanvasRect, InspectorPanel) -> Void,
                pointer: @escaping (Int, CanvasPoint, Int) -> Void = { _, _, _ in }, key: ((Int, EditorKey) -> Bool)? = nil) {
        self.id = id; self.height = height; self.draw = draw; self.pointer = pointer; self.keyPress = key
    }
}

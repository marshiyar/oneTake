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
import MpvfxShared
import MpvfxTimeline

/// The Info panel (dock id `info`): the selected clip's source file facts, read-only. A click on a row copies its
/// value, "Copy all" copies every row as `Label: value` lines. The host resolves the selection and the probe and sets
/// `content`; the panel only shows it.
public final class ClipInfoPanel: DockedPanelView {
    public enum Content: Equatable {
        case none
        case loading(name: String)
        case info(name: String, ClipInfo)
        case failed(name: String, message: String)
    }

    public struct Row: Equatable { public var label: String, value: String }

    public var content: Content = .none
    /// Puts text on the system clipboard.
    public var onCopy: ((String) -> Void)?
    /// What the last copy put there ("Path", "All"), shown in the header until the content changes.
    public private(set) var copiedLabel: String?
    public private(set) var list = PanelRowList(rowHeight: 26)
    static let headerHeight = 34.0
    private var copyAllRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    private var hovered: Int?

    public init() {}

    // MARK: Facts as text

    /// The rows for a file; an offline file shows its path and the offline status only.
    public static func rows(for info: ClipInfo) -> [Row] {
        var out = [Row(label: "Path", value: info.path)]
        if info.offline { out.append(Row(label: "Status", value: "Offline: the file is missing")); return out }
        func add(_ label: String, _ value: String?) { if let value { out.append(Row(label: label, value: value)) } }
        add("Container", info.container)
        add("Video codec", info.videoCodec)
        if let w = info.width, let h = info.height { add("Resolution", "\(w) × \(h)") }
        add("Frame rate", info.frameRate.map { PanelFormat.number($0, decimals: 3) + " fps" })
        add("Duration", info.duration.map(duration))
        add("Audio codec", info.audioCodec)
        add("Audio channels", info.channels.map(channels))
        add("Sample rate", info.sampleRate.map(sampleRate))
        add("Colour space", info.hdr.map { $0 ? "HDR" : "SDR" })
        add("File size", info.fileSize.map(fileSize))
        add("Status", "Online")
        return out
    }

    public var rows: [Row] {
        if case .info(_, let info) = content { return Self.rows(for: info) }
        return []
    }

    /// Every row as `Label: value` lines.
    public var allText: String { rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n") }

    static func duration(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00.000" }
        let ms = Int((s * 1000).rounded()), h = ms / 3_600_000, m = ms / 60_000 % 60, sec = ms / 1000 % 60, frac = ms % 1000
        return h > 0 ? String(format: "%d:%02d:%02d.%03d", h, m, sec, frac) : String(format: "%d:%02d.%03d", m, sec, frac)
    }

    static func channels(_ n: Int) -> String { n == 1 ? "Mono" : n == 2 ? "Stereo" : "\(n) channels" }

    static func sampleRate(_ hz: Int) -> String { PanelFormat.number(Double(hz) / 1000, decimals: 1) + " kHz" }

    /// Decimal units, as the system file managers show them.
    static func fileSize(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(max(0, bytes)), i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(bytes) bytes" : PanelFormat.number(v, decimals: 1) + " " + units[i]
    }

    // MARK: Drawing

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        DockedPanelDraw.background(c, size: size)
        let rows = self.rows
        list.layout(viewport: CanvasRect(x: 0, y: Self.headerHeight, width: size.width, height: max(0, size.height - Self.headerHeight)),
                    count: rows.count)
        copyAllRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
        switch content {
        case .none:
            DockedPanelDraw.empty(c, size: size, title: "No clip selected", detail: "Select a clip to see its source file.")
        case .loading(let name):
            header(c, size, name: name, copy: false)
            PanelDraw.text(c, "Reading the file…", in: CanvasRect(x: 12, y: Self.headerHeight + 6, width: size.width - 24, height: 18),
                           font: PanelTheme.font(12), color: PanelTheme.text3)
        case .failed(let name, let message):
            header(c, size, name: name, copy: false)
            PanelDraw.text(c, message, in: CanvasRect(x: 12, y: Self.headerHeight + 6, width: size.width - 24, height: 18),
                           font: PanelTheme.font(12), color: PanelTheme.danger)
        case .info(let name, let info):
            header(c, size, name: name, copy: true)
            c.save()
            c.clip(list.viewport)
            let labelW = min(110, size.width * 0.38)
            for i in list.visibleRows {
                let r = list.rect(of: i), row = rows[i]
                DockedPanelDraw.rowFill(c, r, selected: false, hovered: i == hovered)
                PanelDraw.text(c, row.label, in: CanvasRect(x: r.x + 12, y: r.y, width: labelW - 12, height: r.height),
                               font: PanelTheme.font(11), color: PanelTheme.text3)
                let bad = info.offline && row.label == "Status"
                PanelDraw.text(c, row.value, in: CanvasRect(x: r.x + labelW + 4, y: r.y, width: max(0, r.width - labelW - 16), height: r.height),
                               font: PanelTheme.font(12), color: bad ? PanelTheme.danger : PanelTheme.text1)
            }
            c.restore()
            PanelScrollbar.draw(c, track: list.viewport, offset: list.scrollY, content: list.contentHeight, hovered: false)
        }
    }

    private func header(_ c: CanvasContext, _ size: CanvasSize, name: String, copy: Bool) {
        let buttonW = copy ? 74.0 : 0
        PanelDraw.text(c, name, in: CanvasRect(x: 12, y: 0, width: max(0, size.width - 24 - buttonW), height: Self.headerHeight),
                       font: PanelTheme.font(12, .medium), color: PanelTheme.text0)
        PanelDraw.hline(c, x0: 0, x1: size.width, y: Self.headerHeight - 1, PanelTheme.panelHairline)
        guard copy else { return }
        copyAllRect = CanvasRect(x: size.width - buttonW - 8, y: 5, width: buttonW, height: 24)
        PanelDraw.smallButton(c, copyAllRect, label: copiedLabel == "All" ? "Copied" : "Copy all", fill: PanelTheme.panelSurface, color: PanelTheme.text1)
    }

    // MARK: Input

    public func pointerDown(_ p: CanvasPoint, shift: Bool) -> Bool {
        if copyAllRect.width > 0, copyAllRect.contains(p) { return copy(allText, label: "All") }
        guard let i = list.row(at: p), rows.indices.contains(i) else { return false }
        return copy(rows[i].value, label: rows[i].label)
    }

    private func copy(_ text: String, label: String) -> Bool {
        guard !text.isEmpty else { return false }
        onCopy?(text)
        copiedLabel = label
        return true
    }

    public func pointerMove(_ p: CanvasPoint) -> Bool {
        let next = list.row(at: p)
        defer { hovered = next }
        return next != hovered
    }

    public func scroll(dy: Double) -> Bool { list.scroll(by: dy) }

    public var hint: String? { "Click a value to copy it" }
}

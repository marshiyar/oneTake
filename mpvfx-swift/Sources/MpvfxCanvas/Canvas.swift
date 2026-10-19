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
/// Backend-neutral 2D drawing layer for the custom-drawn editor views
/// (timeline, canvas, player). Backends: Cairo/Pango (Linux), Core Graphics
/// (macOS), Direct2D/DirectWrite (Windows). Coordinates are in logical points,
/// origin top-left, y down (CSS convention, matching the original renderer).

public struct CanvasPoint: Equatable, Sendable { public var x, y: Double; public init(_ x: Double, _ y: Double) { self.x = x; self.y = y } }
public struct CanvasSize: Equatable, Sendable { public var width, height: Double; public init(_ w: Double, _ h: Double) { width = w; height = h } }
public struct CanvasRect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public func insetBy(_ d: Double) -> CanvasRect { CanvasRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d) }
}

/// Straight (non-premultiplied) sRGB color, components 0...1.
public struct CanvasColor: Equatable, Sendable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    /// Media pixel values (not theme colours: they never follow the appearance). Export pads a MOV with transparency
    /// and an MP4, which has no alpha, with black.
    public static let transparent = CanvasColor(r: 0, g: 0, b: 0, a: 0)
    public static let opaqueBlack = CanvasColor(r: 0, g: 0, b: 0)
    /// CSS-style `rgba(255,255,255,0.5)` from 0-255 channels.
    public static func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> CanvasColor {
        CanvasColor(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255, a: a)
    }
    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA` (CSS order).
    public init?(hex: String) {
        var s = Substring(hex); if s.hasPrefix("#") { s = s.dropFirst() }
        if s.count == 3 { s = Substring(s.map { "\($0)\($0)" }.joined()) }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let n = s.count == 6 ? (v << 8) | 0xFF : v
        self.init(r: Double((n >> 24) & 0xFF) / 255, g: Double((n >> 16) & 0xFF) / 255,
                  b: Double((n >> 8) & 0xFF) / 255, a: Double(n & 0xFF) / 255)
    }
    public func withAlpha(_ a: Double) -> CanvasColor { CanvasColor(r: r, g: g, b: b, a: a) }
    /// A colour stored in the project document (a text layer's CSS hex), opaque black when it does not parse.
    /// Document content, not chrome: it looks the same in both appearance modes.
    public static func documentColor(_ css: String) -> CanvasColor { CanvasColor(hex: css) ?? CanvasColor(r: 0, g: 0, b: 0) }
}

public struct CanvasFont: Equatable, Sendable {
    public enum Weight: Sendable { case regular, medium, semibold, bold }
    public var family: String
    public var size: Double
    public var weight: Weight
    /// Numeric font weight (100…900) when a text layer names one; it wins over `weight`.
    public var numericWeight: Int? = nil
    public var italic = false
    public init(family: String = "Sans", size: Double, weight: Weight = .regular) { self.family = family; self.size = size; self.weight = weight }
    public init(family: String, size: Double, numericWeight: Int, italic: Bool) {
        self.family = family; self.size = size; self.numericWeight = numericWeight; self.italic = italic
        weight = numericWeight >= 700 ? .bold : numericWeight >= 600 ? .semibold : numericWeight >= 500 ? .medium : .regular
    }
    public static func mono(_ size: Double, weight: Weight = .regular) -> CanvasFont { CanvasFont(family: "Monospace", size: size, weight: weight) }
}

public enum PathElement: Equatable, Sendable {
    case move(CanvasPoint), line(CanvasPoint), curve(CanvasPoint, CanvasPoint, CanvasPoint), close
}

public struct CanvasPath: Equatable, Sendable {
    public private(set) var elements: [PathElement] = []
    public init() {}
    public mutating func move(to p: CanvasPoint) { elements.append(.move(p)) }
    public mutating func line(to p: CanvasPoint) { elements.append(.line(p)) }
    public mutating func curve(to p: CanvasPoint, c1: CanvasPoint, c2: CanvasPoint) { elements.append(.curve(c1, c2, p)) }
    public mutating func close() { elements.append(.close) }
    public mutating func addRect(_ r: CanvasRect) {
        move(to: .init(r.x, r.y)); line(to: .init(r.maxX, r.y)); line(to: .init(r.maxX, r.maxY)); line(to: .init(r.x, r.maxY)); close()
    }
    /// Rounded rect; radius clamped to half the shorter side (CSS border-radius behavior).
    public mutating func addRoundedRect(_ r: CanvasRect, radius: Double) {
        let rad = max(0, min(radius, r.width / 2, r.height / 2))
        if rad == 0 { addRect(r); return }
        let k = 0.5522847498 * rad   // cubic approximation of a quarter circle
        move(to: .init(r.x + rad, r.y))
        line(to: .init(r.maxX - rad, r.y))
        curve(to: .init(r.maxX, r.y + rad), c1: .init(r.maxX - rad + k, r.y), c2: .init(r.maxX, r.y + rad - k))
        line(to: .init(r.maxX, r.maxY - rad))
        curve(to: .init(r.maxX - rad, r.maxY), c1: .init(r.maxX, r.maxY - rad + k), c2: .init(r.maxX - rad + k, r.maxY))
        line(to: .init(r.x + rad, r.maxY))
        curve(to: .init(r.x, r.maxY - rad), c1: .init(r.x + rad - k, r.maxY), c2: .init(r.x, r.maxY - rad + k))
        line(to: .init(r.x, r.y + rad))
        curve(to: .init(r.x + rad, r.y), c1: .init(r.x, r.y + rad - k), c2: .init(r.x + rad - k, r.y))
        close()
    }
    public static func rect(_ r: CanvasRect) -> CanvasPath { var p = CanvasPath(); p.addRect(r); return p }
    public static func roundedRect(_ r: CanvasRect, radius: Double) -> CanvasPath { var p = CanvasPath(); p.addRoundedRect(r, radius: radius); return p }
}

/// RGBA8 straight-alpha bitmap, row-major, tightly packed.
public struct CanvasImage: Equatable, Sendable {
    public let width: Int, height: Int
    public var rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "CanvasImage: rgba must be width*height*4 bytes")
        self.width = width; self.height = height; self.rgba = rgba
    }
    /// Copy with every alpha multiplied by `opacity` (clamped to 0...1).
    public func withOpacity(_ opacity: Double) -> CanvasImage {
        let k = UInt32(max(0, min(1, opacity)) * 256)
        var out = rgba
        out.withUnsafeMutableBufferPointer { p in
            var i = 3
            while i < p.count { p[i] = UInt8((UInt32(p[i]) * k) >> 8); i += 4 }
        }
        return CanvasImage(width: width, height: height, rgba: out)
    }
}

public struct StrokeStyle: Equatable, Sendable {
    public var width: Double
    public var dash: [Double]
    public init(width: Double = 1, dash: [Double] = []) { self.width = width; self.dash = dash }
}

/// The drawing protocol every backend implements. Not thread-safe: use on the UI thread.
public protocol CanvasContext: AnyObject {
    func save()
    func restore()
    func translate(_ dx: Double, _ dy: Double)
    func scale(_ sx: Double, _ sy: Double)
    func rotate(_ radians: Double)
    func clip(_ path: CanvasPath)
    func fill(_ path: CanvasPath, _ color: CanvasColor)
    func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle)
    /// Draws `text` with its top-left at `origin` (like an absolutely positioned CSS span with line-height: 1).
    func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor)
    func measureText(_ text: String, font: CanvasFont) -> CanvasSize
    func drawImage(_ image: CanvasImage, in rect: CanvasRect)
    /// Draws `image` at `opacity` (0...1) multiplied into its alpha. Backends composite it natively;
    /// the default bakes the opacity into a copy of the pixels.
    func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double)
    /// Device pixels per user unit at the current transform (2 on a Retina / HiDPI surface). Painters use it
    /// to size bitmaps they produce themselves; the default is 1.
    var deviceScale: Double { get }
}

public extension CanvasContext {
    var deviceScale: Double { 1 }
    func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double) {
        if opacity >= 1 { drawImage(image, in: rect); return }
        guard opacity > 0 else { return }
        drawImage(image.withOpacity(opacity), in: rect)
    }
    func fillRect(_ r: CanvasRect, _ c: CanvasColor) { fill(.rect(r), c) }
    func strokeRect(_ r: CanvasRect, _ c: CanvasColor, width: Double = 1) { stroke(.rect(r), c, StrokeStyle(width: width)) }
    func fillRoundedRect(_ r: CanvasRect, radius: Double, _ c: CanvasColor) { fill(.roundedRect(r, radius: radius), c) }
    func strokeRoundedRect(_ r: CanvasRect, radius: Double, _ c: CanvasColor, width: Double = 1) {
        stroke(.roundedRect(r, radius: radius), c, StrokeStyle(width: width))
    }
    func clip(_ r: CanvasRect) { clip(.rect(r)) }
    /// Multiplies the current transform by the affine map p -> (a x + c y + tx, b x + d y + ty), built from the
    /// backends' translate / rotate / scale (the 2x2 part split into rotate · scale · rotate by its SVD).
    func concat(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        translate(tx, ty)
        let e = (a + d) / 2, f = (a - d) / 2, g = (b + c) / 2, h = (b - c) / 2
        let q = (e * e + h * h).squareRoot(), r = (f * f + g * g).squareRoot()
        let sx = q + r, sy = q - r
        let a1 = atan2(g, f), a2 = atan2(h, e)
        let theta = (a2 - a1) / 2, phi = (a2 + a1) / 2
        if phi != 0 { rotate(phi) }
        if sx != 1 || sy != 1 { scale(sx, sy) }
        if theta != 0 { rotate(theta) }
    }
    /// Scoped save/restore.
    func withState(_ body: () -> Void) { save(); body(); restore() }
}

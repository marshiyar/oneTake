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
// EXIF orientation of still images (TIFF tag 0x0112). The picture must be drawn upright, so the app
// reads the tag itself and applies it to the natural size
// (NativeMediaNaturalSize.oriented); the media engine applies it to every decoded picture.
//
// JPEG only: the tag sits in the APP1 "Exif" segment.
import Foundation

/// 1 (upright) … 8, as EXIF defines them.
public typealias NativeImageOrientation = Int

/// Whether `path` names a JPEG by extension (the files whose EXIF orientation is applied).
public func nativeIsJPEGPath(_ path: String) -> Bool {
    let l = path.lowercased()
    return l.hasSuffix(".jpg") || l.hasSuffix(".jpeg") || l.hasSuffix(".jpe") || l.hasSuffix(".jfif")
}

/// EXIF orientation of a JPEG file; 1 when there is none, the file is no JPEG or cannot be read.
public func nativeImageOrientation(path: String) -> NativeImageOrientation {
    guard nativeIsJPEGPath(path), let h = FileHandle(forReadingAtPath: path) else { return 1 }
    defer { try? h.close() }
    let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
    return nativeJPEGOrientation(data)
}

/// EXIF orientation from the leading bytes of a JPEG (walks the markers to the APP1 Exif segment).
public func nativeJPEGOrientation(_ data: Data) -> NativeImageOrientation {
    let b = [UInt8](data)
    guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return 1 }
    var i = 2
    while i + 4 <= b.count {
        guard b[i] == 0xFF else { return 1 }
        let marker = b[i + 1]
        if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
        if marker == 0xDA || marker == 0xD9 { return 1 }   // image data: no EXIF before it
        let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
        guard len >= 2, i + 2 + len <= b.count else { return 1 }
        if marker == 0xE1, len >= 8, Array(b[(i + 4)..<(i + 10)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
            return tiffOrientation(Array(b[(i + 10)..<(i + 2 + len)])) ?? 1
        }
        i += 2 + len
    }
    return 1
}

/// Orientation tag of IFD0 of a TIFF block.
func tiffOrientation(_ t: [UInt8]) -> Int? {
    guard t.count >= 8 else { return nil }
    let little: Bool
    switch (t[0], t[1]) { case (0x49, 0x49): little = true; case (0x4D, 0x4D): little = false; default: return nil }
    func u16(_ o: Int) -> Int? { o + 2 <= t.count ? (little ? Int(t[o]) | Int(t[o + 1]) << 8 : Int(t[o]) << 8 | Int(t[o + 1])) : nil }
    func u32(_ o: Int) -> Int? {
        guard o + 4 <= t.count else { return nil }
        let v = (0..<4).map { Int(t[o + $0]) }
        return little ? v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
    }
    guard u16(2) == 42, let ifd = u32(4), let count = u16(ifd) else { return nil }
    for k in 0..<count {
        let e = ifd + 2 + 12 * k
        guard let tag = u16(e) else { return nil }
        if tag == 0x0112 {
            guard let v = u16(e + 8), (1...8).contains(v) else { return nil }
            return v
        }
    }
    return nil
}

public extension NativeMediaNaturalSize {
    /// The size once `orientation` is applied (5…8 swap the sides).
    func oriented(_ orientation: NativeImageOrientation) -> NativeMediaNaturalSize {
        (5...8).contains(orientation) ? NativeMediaNaturalSize(width: height, height: width) : self
    }
}

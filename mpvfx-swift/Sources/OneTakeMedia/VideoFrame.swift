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

/// The in-memory representation and colour encoding of a video frame.
public enum VideoPixelFormat: Equatable, Sendable {
    /// Straight-alpha, display-referred sRGB values with one byte per component.
    case rgba8DisplayReferred
    /// Straight-alpha, linear-light values with one IEEE 754 half per component.
    case rgba16FLinear

    /// The number of bytes occupied by one tightly packed pixel.
    public var bytesPerPixel: Int {
        switch self {
        case .rgba8DisplayReferred: 4
        case .rgba16FLinear: 4 * MemoryLayout<Float16>.stride
        }
    }
}

/// Owned, tightly packed pixels for a ``VideoFrame``.
public enum VideoFrameStorage: Equatable, Sendable {
    case rgba8([UInt8])
    case rgba16F([Float16])

    public var pixelFormat: VideoPixelFormat {
        switch self {
        case .rgba8: .rgba8DisplayReferred
        case .rgba16F: .rgba16FLinear
        }
    }

    /// The number of bytes occupied by the stored components.
    public var byteCount: Int {
        switch self {
        case let .rgba8(components): components.count * MemoryLayout<UInt8>.stride
        case let .rgba16F(components): components.count * MemoryLayout<Float16>.stride
        }
    }
}

/// A format-aware, tightly packed, straight-alpha video frame.
public struct VideoFrame: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable {
        case invalidDimensions(width: Int, height: Int)
        case invalidComponentCount(expected: Int, actual: Int)
    }

    public let width: Int
    public let height: Int
    public var storage: VideoFrameStorage

    public var pixelFormat: VideoPixelFormat { storage.pixelFormat }
    public var byteCount: Int { storage.byteCount }
    public var bytesPerRow: Int { width * pixelFormat.bytesPerPixel }

    public init(width: Int, height: Int, storage: VideoFrameStorage) throws {
        guard width > 0, height > 0, width <= Int.max / height / 4 else {
            throw Error.invalidDimensions(width: width, height: height)
        }
        let expected = width * height * 4
        let actual: Int
        switch storage {
        case let .rgba8(components): actual = components.count
        case let .rgba16F(components): actual = components.count
        }
        guard actual == expected else {
            throw Error.invalidComponentCount(expected: expected, actual: actual)
        }
        self.width = width
        self.height = height
        self.storage = storage
    }

    /// Converts display-referred sRGB components to linear-light half floats.
    /// Alpha is normalized but is not transfer-function encoded.
    public func convertedToRGBA16F() throws -> VideoFrame {
        guard case let .rgba8(source) = storage else { return self }
        var destination = [Float16]()
        destination.reserveCapacity(source.count)
        for index in stride(from: 0, to: source.count, by: 4) {
            destination.append(Float16(Self.sRGBToLinear(Float(source[index]) / 255)))
            destination.append(Float16(Self.sRGBToLinear(Float(source[index + 1]) / 255)))
            destination.append(Float16(Self.sRGBToLinear(Float(source[index + 2]) / 255)))
            destination.append(Float16(Float(source[index + 3]) / 255))
        }
        return try VideoFrame(width: width, height: height, storage: .rgba16F(destination))
    }

    /// Converts linear-light half floats to display-referred sRGB bytes.
    /// Components, including straight alpha, are clamped to the display range.
    public func convertedToRGBA8() throws -> VideoFrame {
        guard case let .rgba16F(source) = storage else { return self }
        var destination = [UInt8]()
        destination.reserveCapacity(source.count)
        for index in stride(from: 0, to: source.count, by: 4) {
            destination.append(Self.byte(Self.linearToSRGB(Float(source[index]))))
            destination.append(Self.byte(Self.linearToSRGB(Float(source[index + 1]))))
            destination.append(Self.byte(Self.linearToSRGB(Float(source[index + 2]))))
            destination.append(Self.byte(Float(source[index + 3])))
        }
        return try VideoFrame(width: width, height: height, storage: .rgba8(destination))
    }

    private static func sRGBToLinear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Float) -> Float {
        let value = min(max(value, 0), 1)
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}

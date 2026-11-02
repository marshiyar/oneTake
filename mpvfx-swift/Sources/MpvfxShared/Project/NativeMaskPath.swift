import Foundation

/// A free-form mask outline stored as points in layer-normalised coordinates (0 to 1 across the layer box).
/// Optional handles are offsets from their point; a segment with a handle at either end is a cubic Bezier.
public struct NativeMaskPath: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double, y: Double
        public var inX: Double?, inY: Double?, outX: Double?, outY: Double?
        public init(x: Double, y: Double, inX: Double? = nil, inY: Double? = nil, outX: Double? = nil, outY: Double? = nil) {
            self.x = x; self.y = y; self.inX = inX; self.inY = inY; self.outX = outX; self.outY = outY
        }
        public var hasHandles: Bool { (inX ?? 0) != 0 || (inY ?? 0) != 0 || (outX ?? 0) != 0 || (outY ?? 0) != 0 }
    }
    public static let fillRules = ["nonzero", "evenodd"]
    public var v: Int
    public var closed: Bool
    /// "nonzero" (default, omitted when stored) or "evenodd". Decides what a self-crossing outline fills.
    public var fillRule: String?
    public var points: [Point]

    public init(v: Int = 1, closed: Bool = false, fillRule: String? = nil, points: [Point] = []) {
        self.v = v; self.closed = closed; self.fillRule = fillRule; self.points = points
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        fillRule = try c.decodeIfPresent(String.self, forKey: .fillRule)
        points = try c.decodeIfPresent([Point].self, forKey: .points) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        if closed { try c.encode(closed, forKey: .closed) }
        try c.encodeIfPresent(fillRule == "nonzero" ? nil : fillRule, forKey: .fillRule)
        try c.encode(points, forKey: .points)
    }
    enum CodingKeys: String, CodingKey { case v, closed, fillRule, points }

    public var resolvedFillRule: String { fillRule ?? "nonzero" }
}

/// Why a path cannot be a mask.
public enum NativeMaskPathError: String, Error, Equatable, Sendable {
    case notClosed = "not-closed"
    case tooFewPoints = "too-few-points"
    case nonFiniteValue = "non-finite-value"
    case coordinateOutOfRange = "coordinate-out-of-range"
    case zeroArea = "zero-area"
    case invalidFillRule = "invalid-fill-rule"
    case unsupportedVersion = "unsupported-version"

    public var message: String {
        switch self {
        case .notClosed: "A mask path must be closed"
        case .tooFewPoints: "A mask path needs at least three points"
        case .nonFiniteValue: "Mask path coordinates must be finite numbers"
        case .coordinateOutOfRange: "Mask path coordinates must lie between -4 and 5"
        case .zeroArea: "A mask path must enclose a non-zero area"
        case .invalidFillRule: "Mask path fillRule must be nonzero or evenodd"
        case .unsupportedVersion: "Mask path version must be 1"
        }
    }
}

extension NativeMaskPath {
    /// Flattens to a closed polyline in normalised coordinates; each Bezier segment becomes 16 straight steps.
    public func flattened() -> [(x: Double, y: Double)] {
        var out: [(x: Double, y: Double)] = []
        let n = points.count
        guard n > 0 else { return out }
        for i in 0..<n {
            let a = points[i], b = points[(i + 1) % n]
            out.append((a.x, a.y))
            guard a.hasHandles || b.hasHandles else { continue }
            let c1 = (x: a.x + (a.outX ?? 0), y: a.y + (a.outY ?? 0)), c2 = (x: b.x + (b.inX ?? 0), y: b.y + (b.inY ?? 0))
            let steps = 16
            for s in 1..<steps {
                let t = Double(s) / Double(steps), u = 1 - t
                out.append((u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x,
                            u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y))
            }
        }
        return out
    }

    /// Throws the first reason this path is not a usable mask.
    public func validate() throws {
        guard v == 1 else { throw NativeMaskPathError.unsupportedVersion }
        if let rule = fillRule, !Self.fillRules.contains(rule) { throw NativeMaskPathError.invalidFillRule }
        guard closed else { throw NativeMaskPathError.notClosed }
        guard points.count >= 3 else { throw NativeMaskPathError.tooFewPoints }
        for p in points {
            let values = [p.x, p.y, p.inX, p.inY, p.outX, p.outY].compactMap { $0 }
            guard values.allSatisfy(\.isFinite) else { throw NativeMaskPathError.nonFiniteValue }
            guard [p.x, p.y].allSatisfy({ (-4...5).contains($0) }) else { throw NativeMaskPathError.coordinateOutOfRange }
        }
        // Sum of absolute shoelace terms, so a bow-tie whose signed areas cancel still counts as area.
        let poly = flattened()
        var absolute = 0.0
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            absolute += Swift.abs(a.x * b.y - b.x * a.y)
        }
        // A collinear outline has signed terms that all cancel; test the signed area of triangle fans from point 0.
        var fan = 0.0
        for i in 1..<(poly.count - 1) {
            fan += Swift.abs((poly[i].x - poly[0].x) * (poly[i + 1].y - poly[0].y)
                             - (poly[i + 1].x - poly[0].x) * (poly[i].y - poly[0].y))
        }
        guard fan / 2 > 1e-9, absolute > 0 else { throw NativeMaskPathError.zeroArea }
    }
}

func validateNativeMaskPath(_ value: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let value, value.isRecord else {
        pushIssue(&issues, .invalidMaskPath, path, "A path mask needs a path object"); return
    }
    guard let decoded = try? value.decode(NativeMaskPath.self) else {
        pushIssue(&issues, .invalidMaskPath, path, "Mask path must hold v, closed, fillRule and points"); return
    }
    do { try decoded.validate() } catch let error as NativeMaskPathError {
        pushIssue(&issues, .invalidMaskPath, path, error.message)
    } catch {}
}

/// Pure path-editing steps. Each returns a new mask; commit the resulting document as one undo step.
public enum NativeMaskPathEdit {
    /// Starts a path mask with its first point (click).
    public static func begin(id: String, at x: Double, _ y: Double) -> NativeClipMask {
        var mask = NativeClipMask(id: id, kind: "path")
        mask.path = NativeMaskPath(closed: false, points: [.init(x: x, y: y)])
        return mask
    }
    public static func addPoint(_ mask: NativeClipMask, x: Double, y: Double) -> NativeClipMask {
        edit(mask) { if !$0.closed { $0.points.append(.init(x: x, y: y)) } }
    }
    public static func movePoint(_ mask: NativeClipMask, index: Int, x: Double, y: Double) -> NativeClipMask {
        edit(mask) { guard $0.points.indices.contains(index) else { return }; $0.points[index].x = x; $0.points[index].y = y }
    }
    /// Keyboard nudge of a point by a normalised delta.
    public static func nudge(_ mask: NativeClipMask, index: Int, dx: Double, dy: Double) -> NativeClipMask {
        edit(mask) { guard $0.points.indices.contains(index) else { return }; $0.points[index].x += dx; $0.points[index].y += dy }
    }
    /// Drags a point's out handle; the in handle mirrors it (smooth point).
    public static func dragHandle(_ mask: NativeClipMask, index: Int, dx: Double, dy: Double) -> NativeClipMask {
        edit(mask) {
            guard $0.points.indices.contains(index) else { return }
            $0.points[index].outX = dx; $0.points[index].outY = dy; $0.points[index].inX = -dx; $0.points[index].inY = -dy
        }
    }
    public static func deletePoint(_ mask: NativeClipMask, index: Int) -> NativeClipMask {
        edit(mask) { if $0.points.indices.contains(index) { $0.points.remove(at: index) } }
    }
    /// Closes the outline (click the first point, or Enter).
    public static func close(_ mask: NativeClipMask) -> NativeClipMask { edit(mask) { $0.closed = true } }

    private static func edit(_ mask: NativeClipMask, _ change: (inout NativeMaskPath) -> Void) -> NativeClipMask {
        var next = mask
        var path = mask.path ?? NativeMaskPath()
        change(&path)
        next.path = path
        return next
    }
}

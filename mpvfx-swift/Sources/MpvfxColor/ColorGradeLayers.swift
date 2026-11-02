import Foundation
import MpvfxShared

/// Several grade layers on one clip (issue #457). Each layer is a `color-grading` effect in `clip.effects`: the
/// array order is the layer order and the effect's `enabled` flag is the layer's switch (`NativeGradeLayers`).
/// `clipGrade(_:)` stays the first layer (what the panels edit and an adjustment clip reuses); these entry points
/// give the whole stack, which preview and export both build through `ColorGradeRenderer.forClipLayers`.
extension ColorGradeParams {
    /// The grade of each layer that draws, in order. The first layer is `clipGrade(_:animated:)` (it carries the
    /// colour key and the keyframed values); later layers are their effect's JSON as stored.
    public static func clipGradeLayers(_ clip: NativeProjectClip, animated: [String: Double] = [:]) -> [ColorGradeParams] {
        var out: [ColorGradeParams] = []
        if let first = clipGrade(clip, animated: animated) { out.append(first) }
        for layer in NativeGradeLayers.layers(clip).dropFirst() where layer.enabled {
            if let g = ColorGradeParams(json: layer.parameters ?? NativeJSONObject()) { out.append(g) }
        }
        return out
    }
}

extension ColorGradeRenderer {
    /// The renderer for a clip's whole stack of grade layers: the first active layer, followed by the others in
    /// order; nil when no layer changes a pixel. A single grade gives exactly `forClip`'s renderer.
    public static func forClipLayers(_ clip: NativeProjectClip, animated: [String: Double] = [:], projectDir: String?,
                                     luts: CubeLUTCache = .shared) -> ColorGradeRenderer? {
        var grades: [(ColorGradeParams, String)] = []
        if let first = ColorGradeParams.clipGrade(clip, animated: animated) { grades.append((first, clip.id)) }
        for layer in NativeGradeLayers.layers(clip).dropFirst() where layer.enabled {
            if let g = ColorGradeParams(json: layer.parameters ?? NativeJSONObject()) { grades.append((g, "\(clip.id)|\(layer.id)")) }
        }
        let active = grades.filter { $0.0.isActive }
        guard let head = active.first else { return nil }
        let rest = active.dropFirst().compactMap { forClip($0.0, clipId: $0.1, projectDir: projectDir, luts: luts) }
        return forClip(head.0, clipId: head.1, projectDir: projectDir, luts: luts, following: rest)
    }
}

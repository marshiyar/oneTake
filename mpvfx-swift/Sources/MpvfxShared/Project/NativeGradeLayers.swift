import Foundation

/// Several grade layers on one clip (issue #457).
///
/// Storage decision: a layer is one `color-grading` effect in `clip.effects`, in the form a single grade has always
/// been stored in. The array order is the layer order (the first is drawn first), the effect's `enabled` flag is the
/// layer's switch, and its `id` names the layer. A project with one grade is therefore already a project with one
/// layer: there is no `grades` key, no `schemaVersion` bump and nothing to migrate, so opening and saving a
/// document that has one grade, or none, writes the same bytes as before (`NativeGradeLayerTests`). The state is
/// validated with the rest of the effects (unique ids, an enabled flag, an object of parameters) plus the limit below.
///
/// `NativeGradeParameter.gradeEffect` stays the first layer: it is what the panels edit, what the keyframed grade
/// values (`grade.*` tracks) write into, and what an adjustment clip reuses.
public enum NativeGradeLayers {
    public static let effectId = "color-grading"
    /// Most grade layers a clip may hold.
    public static let maxLayers = 8

    /// The clip's grade layers in drawing order, enabled or not.
    public static func layers(_ clip: NativeProjectClip) -> [NativeClipEffect] {
        clip.effects.filter { $0.effectId == effectId }
    }

    /// The layers that draw.
    public static func enabledLayers(_ clip: NativeProjectClip) -> [NativeClipEffect] {
        layers(clip).filter(\.enabled)
    }

    /// Appends a layer with `parameters` after the last one; false (clip unchanged) at the limit.
    @discardableResult
    public static func add(to clip: inout NativeProjectClip, parameters: NativeJSONObject = NativeJSONObject(), enabled: Bool = true) -> Bool {
        guard layers(clip).count < maxLayers else { return false }
        var n = 1; let ids = Set(clip.effects.map(\.id))
        while ids.contains("effect:grade-\(n)") { n += 1 }
        clip.effects.append(NativeClipEffect(id: "effect:grade-\(n)", effectId: effectId, enabled: enabled, parameters: parameters))
        return true
    }

    /// Switches layer `layerId` on or off; false when there is no such layer or it already is so.
    @discardableResult
    public static func setEnabled(_ enabled: Bool, layerId: String, in clip: inout NativeProjectClip) -> Bool {
        guard let i = clip.effects.firstIndex(where: { $0.id == layerId && $0.effectId == effectId }), clip.effects[i].enabled != enabled else { return false }
        clip.effects[i].enabled = enabled
        return true
    }

    /// Removes layer `layerId`; false when there is no such layer.
    @discardableResult
    public static func remove(layerId: String, from clip: inout NativeProjectClip) -> Bool {
        guard let i = clip.effects.firstIndex(where: { $0.id == layerId && $0.effectId == effectId }) else { return false }
        clip.effects.remove(at: i)
        return true
    }

    /// Moves layer `layerId` to position `index` among the grade layers (0 = drawn first); the other effects keep their
    /// places. False when there is no such layer or it is already there.
    @discardableResult
    public static func move(layerId: String, to index: Int, in clip: inout NativeProjectClip) -> Bool {
        let slots = clip.effects.indices.filter { clip.effects[$0].effectId == effectId }
        guard let from = slots.firstIndex(where: { clip.effects[$0].id == layerId }) else { return false }
        let to = Swift.max(0, Swift.min(slots.count - 1, index))
        guard from != to else { return false }
        var order = slots.map { clip.effects[$0] }
        order.insert(order.remove(at: from), at: to)
        for (slot, layer) in zip(slots, order) { clip.effects[slot] = layer }
        return true
    }
}

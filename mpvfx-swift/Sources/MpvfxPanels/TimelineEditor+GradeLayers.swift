import Foundation
import MpvfxShared
import MpvfxTimeline

/// Edits of a clip's grade layers (issue #457). Each is one undo step, through the same `editClip` every grade edit uses.
public extension TimelineEditor {
    /// The clip's grade layers in drawing order.
    func gradeLayers(clipId: String) -> [NativeClipEffect] {
        clip(clipId).map { NativeGradeLayers.layers($0.clip) } ?? []
    }

    @discardableResult
    func addGradeLayer(clipId: String, parameters: NativeJSONObject = NativeJSONObject()) -> Bool {
        editClip(clipId) { NativeGradeLayers.add(to: &$0, parameters: parameters) }
    }

    @discardableResult
    func setGradeLayerEnabled(clipId: String, layerId: String, _ enabled: Bool) -> Bool {
        editClip(clipId) { NativeGradeLayers.setEnabled(enabled, layerId: layerId, in: &$0) }
    }

    @discardableResult
    func removeGradeLayer(clipId: String, layerId: String) -> Bool {
        editClip(clipId) { NativeGradeLayers.remove(layerId: layerId, from: &$0) }
    }

    @discardableResult
    func moveGradeLayer(clipId: String, layerId: String, to index: Int) -> Bool {
        editClip(clipId) { NativeGradeLayers.move(layerId: layerId, to: index, in: &$0) }
    }
}

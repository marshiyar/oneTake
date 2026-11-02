// Play backwards on a clip (`clip.reversed`, `clip.reverseAudio`): how the fields map frames and how they are validated.
import Foundation

public extension NativeProjectClip {
    /// The clip plays its content from its out point to its in point.
    var playsBackwards: Bool { reversed == true }

    /// A reversed clip's sound is played backwards (the default); false means the user chose to mute it.
    var reversesAudio: Bool { reverseAudio != false }

    /// Source frame offset (from the clip's source start, in source frames) shown at clip frame `frame` of a clip
    /// `durationFrames` long at speed `rate`: forward `frame * rate`, backwards `(durationFrames - 1 - frame) * rate`,
    /// so frame k of an unretimed reversed clip shows source frame `in + out - 1 - k`.
    static func sourceOffset(frame: Double, durationFrames: Double, rate: Double, reversed: Bool) -> Double {
        (reversed ? durationFrames - 1 - frame : frame) * rate
    }
}

/// Every bad value of `clip.reversed` / `clip.reverseAudio` as a typed issue; nothing is clamped.
func validateNativeClipReverse(_ clip: NativeJSONValue, assetKind: String?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    for key in ["reversed", "reverseAudio"] where clip[key] != nil && clip[key]?.boolValue == nil {
        pushIssue(&issues, .invalidClip, "\(path).\(key)", "\(key == "reversed" ? "Reversed" : "Reverse audio") must be a boolean")
    }
    if clip["reversed"]?.boolValue == true, let assetKind, assetKind != "video" && assetKind != "audio" {
        pushIssue(&issues, .invalidClip, "\(path).reversed", "Only a video or audio clip can play backwards")
    }
    if clip["reverseAudio"] != nil, clip["reversed"]?.boolValue != true {
        pushIssue(&issues, .invalidClip, "\(path).reverseAudio", "Reverse audio only applies to a reversed clip")
    }
}

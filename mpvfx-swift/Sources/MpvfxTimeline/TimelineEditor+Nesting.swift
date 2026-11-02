import Foundation
import MpvfxShared

/// Nest, Un-nest and Make unique: each is one undo step (`planNativeTimelineNest`, `planNativeTimelineUnnest`,
/// `planNativeTimelineMakeUnique`). Nothing here draws or opens a nested clip (preview, export and the breadcrumb are
/// later slices).
public extension TimelineEditor {
    /// Nests the clips `clipIds` into one clip that holds them as its own sequence. Returns the nested clip's id; nil
    /// when refused, with `lastFailure` saying why.
    @discardableResult
    func nestClips(_ clipIds: [String]) -> String? {
        var addresses: [NativeProjectClipAddress] = []
        for id in clipIds {
            guard let a = address(clipId: id) else {
                lastFailure = .init(code: .missingClip, message: "Clip \(id) is not in the project"); return nil
            }
            addresses.append(a)
        }
        return runNesting("Nest clips") { try planNativeTimelineNest($0, .init(clips: addresses), engine: engine).map { ($0.document, $0.nestedClipId) } }
    }

    /// Puts the clips of nested clip `clipId` back on the timeline. `dropOuterLook` drops a look the nested clip has
    /// itself (grade, effects, animation); without it such a clip is refused. Returns the restored clip ids.
    @discardableResult
    func unnestClip(_ clipId: String, dropOuterLook: Bool = false) -> [String]? {
        guard let a = address(clipId: clipId) else {
            lastFailure = .init(code: .missingClip, message: "Clip \(clipId) is not in the project"); return nil
        }
        let request = NativeTimelineUnnestRequest(address: a, outerLook: dropOuterLook ? .drop : .refuse)
        return runNesting("Un-nest clip") { try planNativeTimelineUnnest($0, request, engine: engine).map { ($0.document, $0.restoredClipIds) } }
    }

    /// Gives nested clip `clipId` its own copy of the sequence it shares with other clips. Returns the new sequence id.
    @discardableResult
    func makeNestedSequenceUnique(_ clipId: String) -> String? {
        guard let a = address(clipId: clipId) else {
            lastFailure = .init(code: .missingClip, message: "Clip \(clipId) is not in the project"); return nil
        }
        return runNesting("Make unique") { try planNativeTimelineMakeUnique($0, address: a, engine: engine).map { ($0.document, $0.sequenceId) } }
    }

    private func runNesting<T>(_ label: String, _ plan: (NativeProjectDocument) throws -> Result<(NativeProjectDocument, T), NativeTimelineNestFailure>) -> T? {
        let before = document
        do {
            switch try plan(before) {
            case .failure(let f):
                lastFailure = .init(code: .documentMismatch, message: f.message); return nil
            case .success(let (next, value)):
                withHistory(label) { replaceDocument(next, inverse: .restoreDocument(before)) }
                lastFailure = nil
                return value
            }
        } catch {
            lastFailure = .init(code: .documentMismatch, message: "\(label) could not be applied."); return nil
        }
    }
}

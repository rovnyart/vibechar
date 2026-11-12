import CVibechar
import Foundation

enum TextEditKind: UInt32 {
    case isolated = 0, typing = 1, backspace = 2, deleteForward = 3
}

@MainActor
final class RustDocument {
    private let ownedHandle: OpaquePointer?
    private let session: RustSession?
    var handle: OpaquePointer {
        if let ownedHandle { return ownedHandle }
        guard let session, let active = vc_session_document(session.handle) else {
            preconditionFailure("The editing session must have an active document")
        }
        return active
    }

    init(_ text: String = "") {
        let bytes = Array(text.utf8)
        guard let document = bytes.withUnsafeBufferPointer({ vc_document_new($0.baseAddress, $0.count) }) else {
            preconditionFailure("Unable to allocate the text document")
        }
        ownedHandle = document
        session = nil
    }

    init(session: RustSession) {
        ownedHandle = nil
        self.session = session
    }

    deinit { if let ownedHandle { vc_document_free(ownedHandle) } }

    var isDirty: Bool { vc_document_dirty(handle) }
    var revision: UInt64 { vc_document_revision(handle) }

    var text: String {
        let count = vc_document_length(handle)
        return String(unsafeUninitializedCapacity: count) { buffer in
            precondition(vc_document_copy(handle, buffer.baseAddress, buffer.count),
                         "Document snapshot must match its measured size")
            return count
        }
    }

    func replace(_ range: NSRange, with text: String, kind: TextEditKind = .isolated) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer {
            vc_document_edit(handle, range.location, range.length, $0.baseAddress, $0.count, kind.rawValue)
        }
    }

    func breakUndoGroup() { vc_document_break_undo_group(handle) }

    func history(redo: Bool) -> Int? {
        var cursor = 0
        let changed = redo ? vc_document_redo(handle, &cursor) : vc_document_undo(handle, &cursor)
        return changed ? cursor : nil
    }

    func markSaved() { vc_document_mark_saved(handle) }
}

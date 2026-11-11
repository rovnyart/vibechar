import CVibechar
import Foundation

@MainActor
final class RustDocument {
    private let ownedHandle: OpaquePointer?
    private let session: RustSession?
    private var handle: OpaquePointer {
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

    var text: String {
        var bytes = [UInt8](repeating: 0, count: vc_document_length(handle))
        let copied = bytes.withUnsafeMutableBufferPointer { vc_document_copy(handle, $0.baseAddress, $0.count) }
        precondition(copied, "Document snapshot must match its measured size")
        return String(decoding: bytes, as: UTF8.self)
    }

    func replace(_ range: NSRange, with text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer {
            vc_document_replace(handle, range.location, range.length, $0.baseAddress, $0.count)
        }
    }

    func history(redo: Bool) -> Int? {
        var cursor = 0
        let changed = redo ? vc_document_redo(handle, &cursor) : vc_document_undo(handle, &cursor)
        return changed ? cursor : nil
    }

    func markSaved() { vc_document_mark_saved(handle) }
}

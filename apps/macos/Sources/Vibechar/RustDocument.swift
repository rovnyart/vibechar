import CVibechar
import Foundation

@MainActor
final class RustDocument {
    private let handle: OpaquePointer

    init(_ text: String = "") {
        let bytes = Array(text.utf8)
        guard let document = bytes.withUnsafeBufferPointer({ vc_document_new($0.baseAddress, $0.count) }) else {
            preconditionFailure("Unable to allocate the text document")
        }
        handle = document
    }

    deinit { vc_document_free(handle) }

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

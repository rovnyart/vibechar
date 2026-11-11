import CVibechar
import Foundation

@MainActor
final class RustSession {
    let handle: OpaquePointer

    init() {
        guard let handle = vc_session_new() else { preconditionFailure("Unable to allocate the editing session") }
        self.handle = handle
    }

    deinit { vc_session_free(handle) }

    var count: Int { vc_session_count(handle) }
    var active: Int { vc_session_active(handle) }
    var hasUnsaved: Bool { vc_session_has_unsaved(handle) }
    var fileURL: URL? {
        let path = metadata { vc_session_path(handle, $0, $1) }
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    var selection: NSRange {
        var start = 0
        var length = 0
        guard vc_session_selection(handle, &start, &length) else { return NSRange(location: 0, length: 0) }
        return NSRange(location: start, length: length)
    }

    func rememberSelection(_ range: NSRange) {
        precondition(vc_session_set_selection(handle, range.location, range.length), "Native selection must fit the active document")
    }

    func label(_ index: Int) -> String {
        let name = metadata { vc_session_label(handle, index, $0, $1) }
        return name
    }

    func isModifiedFile(_ index: Int) -> Bool {
        vc_session_buffer_is_file(handle, index) && vc_session_buffer_dirty(handle, index)
    }

    func select(_ index: Int) { precondition(vc_session_select(handle, index)) }

    func open(_ text: String = "", url: URL? = nil) {
        let bytes = Array(text.utf8)
        let path = Array((url?.path ?? "").utf8)
        let opened = bytes.withUnsafeBufferPointer { text in
            path.withUnsafeBufferPointer { path in
                vc_session_open(handle, text.baseAddress, text.count, path.baseAddress, path.count)
            }
        }
        precondition(opened)
    }

    func close(discard: Bool) -> Bool { vc_session_close(handle, discard) }

    func setFileURL(_ url: URL) {
        let bytes = Array(url.path.utf8)
        precondition(bytes.withUnsafeBufferPointer { vc_session_set_path(handle, $0.baseAddress, $0.count) })
    }

    func checkpoint() -> RustCheckpoint {
        guard let snapshot = vc_session_checkpoint(handle) else { preconditionFailure("Unable to snapshot the editing session") }
        return RustCheckpoint(handle: snapshot)
    }

    func restore(from url: URL) throws -> Bool {
        let path = Array(url.path.utf8)
        let result = path.withUnsafeBufferPointer { vc_session_restore(handle, $0.baseAddress, $0.count) }
        if result == 0 { throw RecoveryError.invalidSnapshot }
        return result == 1
    }

    private func metadata(_ copy: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
        let length = copy(nil, 0)
        var bytes = [UInt8](repeating: 0, count: length)
        let copied = bytes.withUnsafeMutableBufferPointer { copy($0.baseAddress, $0.count) }
        precondition(copied == length)
        return String(decoding: bytes, as: UTF8.self)
    }
}

// The Rust checkpoint owns immutable ropes; it never borrows the live session.
final class RustCheckpoint: @unchecked Sendable {
    private let handle: OpaquePointer
    init(handle: OpaquePointer) { self.handle = handle }
    deinit { vc_checkpoint_free(handle) }

    func save(to url: URL) -> Bool {
        let path = Array(url.path.utf8)
        return path.withUnsafeBufferPointer { vc_checkpoint_save(handle, $0.baseAddress, $0.count) }
    }
}

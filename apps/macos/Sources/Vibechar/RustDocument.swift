import CVibechar
import Foundation

enum TextEditKind: UInt32 {
    case isolated = 0, typing = 1, backspace = 2, deleteForward = 3
}

struct HistoryUpdate: Decodable {
    struct Edit: Decodable {let start:Int;let length:Int;let text:String}
    let cursor:Int;let source_length:Int;let target_length:Int;let edits:[Edit]?
}
struct EditingUpdate:Decodable {
    let changed:Bool;let start:Int;let length:Int;let history:HistoryUpdate
    var selection:NSRange {NSRange(location:start,length:length)}
}

@MainActor
final class RustDocument {
    var isLarge:Bool {vc_document_large(handle)}
    static var paragraphBudget:Int {vc_native_paragraph_budget()}
    var nativeParagraphBudget:Int {vc_document_native_budget(handle)}
    func wordRange(at offset:Int)->NSRange? {
        var start=0,length=0
        return vc_document_word_range(handle,offset,&start,&length) ? NSRange(location:start,length:length) : nil
    }
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
    func lineLength(at offset:Int)->Int {vc_document_line_length(handle,offset)}
    var lineCount:Int {vc_document_line_count(handle)}
    func lineIndex(at offset:Int)->Int {vc_document_line_index(handle,offset)}
    func lineRange(_ line:Int)->NSRange? {
        var start=0,length=0
        return vc_document_line_range(handle,line,&start,&length) ? NSRange(location:start,length:length) : nil
    }
    func position(at offset:Int)->(Int,Int)? {
        var line=0,column=0
        return vc_document_position(handle,offset,&line,&column) ? (line,column) : nil
    }
    func editing(_ action:UInt32,range:NSRange)->EditingUpdate? {
        guard let frame=vc_document_editing(handle,range.location,range.length,action) else {return nil}
        defer {vc_history_free(frame)}
        let count=vc_history_json(frame,nil,0);var bytes=[UInt8](repeating:0,count:count)
        precondition(bytes.withUnsafeMutableBufferPointer {vc_history_json(frame,$0.baseAddress,$0.count)}==count)
        return try! JSONDecoder().decode(EditingUpdate.self,from:Data(bytes))
    }

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

    func historyUpdate(redo:Bool)->HistoryUpdate? {
        guard let update=vc_document_history(handle,redo) else {return nil}
        defer {vc_history_free(update)}
        let count=vc_history_json(update,nil,0)
        var bytes=[UInt8](repeating:0,count:count)
        precondition(bytes.withUnsafeMutableBufferPointer {vc_history_json(update,$0.baseAddress,$0.count)}==count)
        return try! JSONDecoder().decode(HistoryUpdate.self,from:Data(bytes))
    }

    func markSaved() { vc_document_mark_saved(handle) }
}

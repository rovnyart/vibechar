import AppKit
import CVibechar

struct MultiSelection: Decodable {
    let start: Int; let length: Int; let anchor: Int; let head: Int
    var range: NSRange { NSRange(location:start,length:length) }
}
struct MultiState: Decodable {
    let serial: UInt64; let selections: [MultiSelection]; let primary: Int; let busy: Bool; let queued: Bool; let message: String?
    var active: Bool { !selections.isEmpty }
    var current: MultiSelection? { selections.indices.contains(primary) ? selections[primary] : nil }
}
@MainActor final class RustMulti {
    let handle: OpaquePointer
    init() { guard let handle=vc_multi_new() else {preconditionFailure("Unable to allocate multiple selections")}; self.handle=handle }
    deinit { vc_multi_free(handle) }
    func clear() { vc_multi_clear(handle) }
    func adopt(_ document:RustDocument,frame:FindFrame,primary:Int) {
        let starts=frame.matches.map(\.utf16_start),lengths=frame.matches.map(\.utf16_length)
        _=starts.withUnsafeBufferPointer {s in lengths.withUnsafeBufferPointer {l in vc_multi_adopt(handle,document.handle,frame.document,frame.revision,s.baseAddress,l.baseAddress,s.count,primary)}}
    }
    func request(_ document:RustDocument, range:NSRange, all:Bool) { _=vc_multi_request(handle,document.handle,range.location,range.length,all) }
    func poll(_ document:RustDocument)->Bool {vc_multi_poll(handle,document.handle)}
    func state(_ document:RustDocument)->MultiState {
        let length=vc_multi_state(handle,document.handle,nil,0)
        var bytes=[UInt8](repeating:0,count:length)
        precondition(bytes.withUnsafeMutableBufferPointer {vc_multi_state(handle,document.handle,$0.baseAddress,$0.count)} == length)
        return try! JSONDecoder().decode(MultiState.self,from:Data(bytes))
    }
    func edit(_ document:RustDocument, text:String, kind:UInt32)->Int32 {
        let bytes=Array(text.utf8)
        return bytes.withUnsafeBufferPointer {vc_multi_edit(handle,document.handle,$0.baseAddress,$0.count,kind)}
    }
    func move(_ document:RustDocument, direction:UInt32, extend:Bool) { _=vc_multi_move(handle,document.handle,direction,extend) }
    func copy(_ document:RustDocument)->String? {
        let length=vc_multi_copy(handle,document.handle,nil,0); guard length>0 else {return nil}
        var bytes=[UInt8](repeating:0,count:length)
        guard bytes.withUnsafeMutableBufferPointer({vc_multi_copy(handle,document.handle,$0.baseAddress,$0.count)})==length else {return nil}
        return String(decoding:bytes,as:UTF8.self)
    }
}

@MainActor final class MultiController {
    let engine=RustMulti()
    private let document:RustDocument
    private let textView:PocketTextView
    private let clipboard:NSPasteboard
    private(set) var state:MultiState
    private(set) var syncing=false
    private var painted:[NSRange]=[]
    private var timer:Timer?
    var didEdit:(()->Void)?
    var didUpdate:((MultiState)->Void)?
    init(document:RustDocument,textView:PocketTextView,clipboard:NSPasteboard) {
        self.document=document; self.textView=textView; self.clipboard=clipboard; state=engine.state(document)
        textView.onMultiInsert={ [weak self] text,kind in self?.insert(text,kind:kind) ?? false }
        textView.onMultiPaste={ [weak self] text in self?.insert(text,kind:5) ?? false }
        textView.onMultiClipboard={ [weak self] action in self?.clipboardAction(action) ?? false }
        textView.onMultiMove={ [weak self] direction,extend in self?.move(direction,extend:extend) ?? false }
        textView.onMultiCancel={ [weak self] in self?.cancel() ?? true }
        textView.onMultiReady={ [weak self] in self?.ready() ?? true }
        textView.onMultiCanCopy={ [weak self] in self?.state.selections.contains(where:{$0.length>0}) ?? false }
    }
    var active:Bool {state.active}
    func request(all:Bool) {
        if textView.hasMarkedText() {return}
        document.breakUndoGroup()
        engine.request(document,range:textView.selectedRange(),all:all)
        sync(changed:false)
        if state.busy && timer==nil {
            timer=Timer.scheduledTimer(withTimeInterval:0.025,repeats:true) { [weak self] timer in
                MainActor.assumeIsolated {guard let self else {timer.invalidate();return};self.poll()}
            }
        }
    }
    func adopt(frame:FindFrame,primary:Int) {
        document.breakUndoGroup();engine.adopt(document,frame:frame,primary:primary);sync(changed:false)
    }
    func poll() {let revision=document.revision;if engine.poll(document) {sync(changed:document.revision != revision)}; if !state.busy {timer?.invalidate();timer=nil} }
    func ready()->Bool {if state.busy {poll()};return !state.queued}
    @discardableResult func cancel()->Bool {
        guard ready() else {return false}
        timer?.invalidate();timer=nil;engine.clear();state=engine.state(document)
        textView.secondaryCarets=[];paint();didUpdate?(state);return true
    }
    func sourceChanged() {if !syncing {cancel()}}
    func selectionChanged() {
        if !syncing && active && textView.selectedRange() != state.current?.range {cancel()}
    }
    func insert(_ text:String,kind:UInt32)->Bool {
        if state.busy {poll()}
        guard active else {return false}
        let result=engine.edit(document,text:text,kind:kind)
        sync(changed:result==1)
        return true
    }
    private func move(_ direction:UInt32,extend:Bool)->Bool {
        if state.busy {poll()}
        guard active else {return false}
        engine.move(document,direction:direction,extend:extend);sync(changed:false);return true
    }
    private func clipboardAction(_ action:Int)->Bool {
        if state.busy {poll()}
        guard active else {return false}
        if action==2 {
            guard let text=clipboard.string(forType:.string),text.utf8.count<=8*1024*1024 else {NSSound.beep();return true}
            document.breakUndoGroup();return insert(text,kind:5)
        }
        guard let text=engine.copy(document) else {NSSound.beep();return true}
        clipboard.clearContents()
        guard clipboard.setString(text,forType:.string) else {NSSound.beep();return true}
        if action==1 {document.breakUndoGroup();_=insert("",kind:0)}
        return true
    }
    private func sync(changed:Bool) {
        syncing=true;defer {syncing=false}
        state=engine.state(document)
        if changed {textView.string=document.text;didEdit?()}
        if let current=state.current {
            textView.setSelectedRange(current.range)
            textView.scrollRangeToVisible(NSRange(location:current.head,length:0))
        }
        textView.secondaryCarets=state.selections.enumerated().filter {$0.offset != state.primary && $0.element.length==0}.map {NSRange(location:$0.element.head,length:0)}
        paint();didUpdate?(state)
    }
    func paint() {
        guard let layout=textView.layoutManager,let container=textView.textContainer else {return}
        let length=(textView.string as NSString).length
        for range in painted {
            let valid=NSIntersectionRange(range,NSRange(location:0,length:length))
            if valid.length>0 {layout.removeTemporaryAttribute(.backgroundColor,forCharacterRange:valid)}
        }
        painted=[]
        guard active else {textView.needsDisplay=true;return}
        let glyphs=layout.glyphRange(forBoundingRect:textView.visibleRect,in:container)
        let visible=layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
        let window=NSRange(location:max(0,visible.location-2048),length:min(length,NSMaxRange(visible)+2048)-max(0,visible.location-2048))
        for (index,selection) in state.selections.enumerated() where index != state.primary && selection.length>0 {
            let range=NSIntersectionRange(selection.range,window)
            if range.length>0 {layout.addTemporaryAttribute(.backgroundColor,value:PocketPalette.selection,forCharacterRange:range);painted.append(range)}
        }
        textView.needsDisplay=true
    }
}

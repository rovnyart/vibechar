import AppKit
import CVibechar

struct ToolChoice: Decodable { let id: UInt32; let title: String; let detail: String }
func toolChoices(_ query: String) -> [ToolChoice] {
    let query=Array(query.utf8)
    guard query.count <= 256 else { return [] }
    return query.withUnsafeBufferPointer { input in
        let length=vc_tool_choices(input.baseAddress,input.count,nil,0)
        var bytes=[UInt8](repeating:0,count:length)
        guard bytes.withUnsafeMutableBufferPointer({ vc_tool_choices(input.baseAddress,input.count,$0.baseAddress,$0.count) }) == length else { return [] }
        return (try? JSONDecoder().decode([ToolChoice].self,from:Data(bytes))) ?? []
    }
}
@MainActor final class RustTool {
    let handle: OpaquePointer
    init?(_ document: RustDocument, range: NSRange, command: UInt32) {
        guard let handle=vc_tool_start(document.handle,range.location,range.length,command) else { return nil }
        self.handle=handle
    }
    deinit { vc_tool_free(handle) }
    func poll() -> Int32 { vc_tool_poll(handle) }
    var error: String {
        let length=vc_tool_error(handle,nil,0)
        var bytes=[UInt8](repeating:0,count:length)
        _=bytes.withUnsafeMutableBufferPointer { vc_tool_error(handle,$0.baseAddress,$0.count) }
        return String(decoding:bytes,as:UTF8.self)
    }
    func apply(_ document: RustDocument) -> (changed: Bool, range: NSRange)? {
        var start=0,length=0
        let result=vc_tool_apply(handle,document.handle,&start,&length)
        return result==0 ? nil : (result==1,NSRange(location:start,length:length))
    }
}

private final class ToolRow: NSButton {
    override var isFlipped: Bool { true }
    var choice: ToolChoice? { didSet { title=choice?.title ?? ""; setAccessibilityLabel(title); needsDisplay=true } }
    var chosen=false { didSet { needsDisplay=true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let choice else { return }
        if chosen || isHighlighted {
            PocketPalette.hover.setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:0,dy:2),xRadius:8,yRadius:8).fill()
        }
        let title=NSAttributedString(string:choice.title,attributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:PocketPalette.ink])
        let detail=NSAttributedString(string:choice.detail,attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:PocketPalette.secondary])
        title.draw(at:NSPoint(x:14,y:8)); detail.draw(at:NSPoint(x:14,y:29))
        if chosen { ("↵" as NSString).draw(at:NSPoint(x:bounds.width-26,y:12),withAttributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:PocketPalette.accent]) }
    }
}

@MainActor final class ToolPalette: NSViewController, NSSearchFieldDelegate, NSPopoverDelegate {
    let search=NSSearchField()
    private let document: RustDocument
    private let target: NSRange
    private let selectedText: Bool
    private let scope: String
    private let didApply: (NSRange, Bool) -> Void
    private let didDismiss: () -> Void
    private var rows: [ToolRow]=[]
    private let list=PocketSurface()
    private let scroll=NSScrollView()
    private(set) var choices: [ToolChoice]=[]
    private var selected=0
    private let notice=NSTextField(labelWithString:"")
    private var message: String?
    private var popover: NSPopover?
    private var job: RustTool?
    private var timer: Timer?
    init(document: RustDocument, target: NSRange, selectedText: Bool, scope: String, didDismiss: @escaping () -> Void, didApply: @escaping (NSRange,Bool) -> Void) {
        self.document=document; self.target=target; self.selectedText=selectedText; self.scope=scope
        self.didApply=didApply; self.didDismiss=didDismiss
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view=PocketSurface(frame:NSRect(x:0,y:0,width:376,height:424))
        view.wantsLayer=true; view.layer?.masksToBounds=true
        let brand=NSTextField(labelWithString:"V_  TEXT TOOLS")
        brand.font = .monospacedSystemFont(ofSize:11,weight:.semibold); brand.textColor=PocketPalette.accent
        brand.frame=NSRect(x:20,y:18,width:190,height:18); view.addSubview(brand)
        let local=NSTextField(labelWithString:"ON DEVICE")
        local.font = .systemFont(ofSize:9,weight:.medium); local.textColor=PocketPalette.secondary
        local.alignment = .right; local.frame=NSRect(x:240,y:19,width:114,height:16); view.addSubview(local)
        search.frame=NSRect(x:16,y:48,width:344,height:30); search.placeholderString="What needs tidying?"
        search.delegate=self; search.maximumRecents=0; search.recentsAutosaveName=nil; search.sendsWholeSearchString=true
        search.setAccessibilityLabel("Find a text tool"); view.addSubview(search)
        let caption=NSTextField(labelWithString:scope)
        caption.font = .systemFont(ofSize:11); caption.textColor=PocketPalette.secondary
        caption.frame=NSRect(x:20,y:88,width:336,height:18); caption.lineBreakMode = .byTruncatingTail; view.addSubview(caption)
        scroll.frame=NSRect(x:12,y:116,width:352,height:250)
        scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground=false; scroll.contentView.drawsBackground=false
        list.frame=NSRect(x:0,y:0,width:352,height:250); list.clipsToBounds=true
        scroll.documentView=list; view.addSubview(scroll)
        for index in 0..<toolChoices("").count {
            let row=ToolRow(title:"",target:self,action:#selector(choose(_:)))
            row.tag=index; row.isBordered=false; row.frame=NSRect(x:0,y:index*50,width:352,height:50)
            rows.append(row); list.addSubview(row)
        }
        notice.font = .systemFont(ofSize:11); notice.textColor=PocketPalette.accent
        notice.frame=NSRect(x:20,y:376,width:336,height:18); notice.lineBreakMode = .byTruncatingTail; view.addSubview(notice)
        let hint=NSTextField(labelWithString:"↑↓ choose     ↵ apply     esc close     ·     one Undo")
        hint.font = .systemFont(ofSize:10); hint.textColor=PocketPalette.secondary
        hint.frame=NSRect(x:20,y:399,width:336,height:16); view.addSubview(hint)
        refresh()
    }
    func open(relativeTo anchor: NSView) {
        let popover=NSPopover(); popover.behavior = .transient; popover.animates=false; popover.delegate=self
        popover.contentViewController=self; self.popover=popover
        popover.show(relativeTo:NSRect(x:anchor.bounds.midX,y:anchor.bounds.maxY-1,width:1,height:1),of:anchor,preferredEdge:.maxY)
        view.window?.makeFirstResponder(search)
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(search) }
    func close() {
        timer?.invalidate(); timer=nil; job=nil
        let editor=view.window?.fieldEditor(false,for:search) as? NSTextView
        editor?.undoManager?.removeAllActions()
        search.stringValue=""; search.recentSearches=[]
        let popover=self.popover; self.popover=nil; popover?.delegate=nil; popover?.performClose(nil)
    }
    func popoverDidClose(_ notification: Notification) { close(); didDismiss() }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    private func refresh() {
        guard job==nil else { return }
        choices=toolChoices(search.stringValue); selected=0
        message=nil
        updateRows()
    }
    private func updateRows() {
        for (index,row) in rows.enumerated() {
            row.isHidden=index>=choices.count; row.choice=index<choices.count ? choices[index] : nil
            row.chosen=index==selected; row.isEnabled=job==nil
        }
        list.setFrameSize(NSSize(width:352,height:max(250,choices.count*50)))
        if selected<choices.count { list.scrollToVisible(rows[selected].frame) }
        else { list.scroll(NSPoint.zero) }
        notice.stringValue=message ?? (choices.isEmpty ? "No tools found · try json, case or url" : choices.count>5 ? "\(choices.count) tools · scroll or ↑↓ · type to filter" : "")
        notice.textColor=message == nil ? PocketPalette.secondary : PocketPalette.accent
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(); didDismiss(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { runSelected(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            if !choices.isEmpty && job==nil { selected=(selected+(selector == #selector(NSResponder.moveDown(_:)) ? 1 : choices.count-1))%choices.count; message=nil; updateRows() }
            return true
        }
        return false
    }
    @objc private func choose(_ sender: NSButton) { selected=sender.tag; runSelected() }
    func runSelected() {
        guard job==nil,selected<choices.count else { return }
        document.breakUndoGroup()
        guard let job=RustTool(document,range:target,command:choices[selected].id) else { message="Text range is no longer available"; updateRows(); return }
        self.job=job; search.isEnabled=false; message="Working locally…"; updateRows()
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] timer in
            MainActor.assumeIsolated { guard let self else { timer.invalidate(); return }; self.poll() }
        }
    }
    func poll() {
        guard let job else { return }
        let state=job.poll(); guard state != 0 else { return }
        timer?.invalidate(); timer=nil
        if state==1,let result=job.apply(document) {
            let range=selectedText ? result.range : NSRange(location:result.range.location,length:0)
            close(); didApply(range,result.changed)
        } else {
            message=job.error.isEmpty ? "Text changed · run the command again" : job.error
            self.job=nil; search.isEnabled=true; updateRows(); view.window?.makeFirstResponder(search)
        }
    }

    static func smokeTest() {
        let document=RustDocument("👩‍💻 %C3%9F tail")
        let target=NSRange(location:6,length:6)
        var applied: (NSRange,Bool)?
        func palette() -> ToolPalette {
            applied=nil
            let picker=ToolPalette(document:document,target:target,selectedText:true,scope:"Selection · local text tools",didDismiss:{},didApply:{ applied=($0,$1) })
            _=picker.view
            return picker
        }
        func wait(_ picker:ToolPalette) {
            let deadline=Date(timeIntervalSinceNow:3)
            while applied==nil { RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01)); picker.poll(); precondition(Date()<deadline) }
        }
        let picker=palette()
        precondition(picker.choices.count==9 && picker.rows.count==9)
        for _ in 0..<8 { _=picker.control(picker.search,textView:NSTextView(),doCommandBy:#selector(NSResponder.moveDown(_:))) }
        precondition(picker.choices[picker.selected].id==9)
        precondition(picker.scroll.documentVisibleRect.contains(picker.rows[8].frame),"Arrow navigation reveals the chosen tool")
        picker.rows[8].performClick(nil); wait(picker)
        precondition(document.text=="👩‍💻 ß tail" && applied!.0==NSRange(location:6,length:1) && applied!.1)
        precondition(document.history(redo:false) != nil && document.text=="👩‍💻 %C3%9F tail" && !document.isDirty)
        precondition(document.replace(target,with:"straße")); document.markSaved()
        let upper=palette()
        upper.search.stringValue="upper"; upper.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        precondition(upper.choices.count==1 && upper.rows[1].isHidden)
        precondition(upper.control(upper.search,textView:NSTextView(),doCommandBy:#selector(NSResponder.insertNewline(_:))))
        wait(upper)
        precondition(document.text=="👩‍💻 STRASSE tail" && applied!.0==NSRange(location:6,length:7))
        precondition(document.history(redo:false) != nil && !document.isDirty)
        let last=palette()
        _=last.control(last.search,textView:NSTextView(),doCommandBy:#selector(NSResponder.moveUp(_:)))
        precondition(last.selected==8 && last.scroll.documentVisibleRect.contains(last.rows[8].frame))
        last.search.stringValue="url"; last.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        precondition(last.choices.map(\.id)==[8,9] && last.selected==0)
        precondition(last.scroll.documentVisibleRect.minY==0,"Filtering resets the list scroll")
        last.close()
        print("Extended tools native smoke passed: nine-tool scrolling, arrow wrap, tail-row click, URL decoding, expanding Unicode selection, search reset and Undo")
    }
}

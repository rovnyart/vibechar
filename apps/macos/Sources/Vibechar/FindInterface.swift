import AppKit
import CVibechar

struct FindHit: Decodable { let start: Int; let end: Int; let utf16_start: Int; let utf16_length: Int
    var range: NSRange { NSRange(location: utf16_start, length: utf16_length) }
}
struct FindExample: Decodable { let before: String; let after: String }
struct FindFrame: Decodable {
    let serial: UInt64; let document: UInt64; let revision: UInt64
    let matches: [FindHit]; let changed: Int; let limited: Bool; let error: String?; let examples: [FindExample]
}
@MainActor final class RustSearch {
    let handle: OpaquePointer
    init?() { guard let handle = vc_search_new() else { return nil }; self.handle = handle }
    deinit { vc_search_free(handle) }
    var busy: Bool { vc_search_busy(handle) }
    func submit(_ document: RustDocument, needle: String, replacement: String?, regex: Bool, sensitive: Bool) -> Bool {
        let find = Array(needle.utf8), replace = Array((replacement ?? "").utf8)
        let flags: UInt32 = (regex ? 1 : 0) | (sensitive ? 2 : 0) | (replacement == nil ? 0 : 4)
        return find.withUnsafeBufferPointer { f in replace.withUnsafeBufferPointer { r in vc_search_submit(handle,document.handle,f.baseAddress,f.count,r.baseAddress,r.count,flags) } }
    }
    func frame(_ document: RustDocument, after: UInt64) -> FindFrame? {
        guard let frame = vc_search_frame(handle,document.handle,after) else { return nil }
        defer { vc_search_frame_free(frame) }
        let length = vc_search_frame_json(frame,nil,0)
        var bytes = [UInt8](repeating: 0, count: length)
        guard bytes.withUnsafeMutableBufferPointer({ vc_search_frame_json(frame,$0.baseAddress,$0.count) }) == length else { return nil }
        return try? JSONDecoder().decode(FindFrame.self, from: Data(bytes))
    }
    func apply(_ document: RustDocument, serial: UInt64, index: Int?) -> (selection: NSRange, changed: Bool)? {
        var start = 0, length = 0
        let result=vc_search_apply(handle,document.handle,serial,index ?? -1,&start,&length)
        guard result != 0 else { return nil }
        return (NSRange(location:start,length:length),result==1)
    }
}

@MainActor final class FindBar: NSView {
    let find = NSSearchField(), replacement = NSTextField(string: "")
    let count = NSTextField(labelWithString: "Find in this tab")
    let previous = NSButton(), next = NSButton(), close = NSButton(), toggle = NSButton()
    let regex = NSButton(title: ".*",target: nil,action: nil), sensitive = NSButton(title: "Aa",target: nil,action: nil)
    let replace = NSButton(title: "Replace",target: nil,action: nil), all = NSButton(title: "All…",target: nil,action: nil)
    lazy var height = heightAnchor.constraint(equalToConstant: 0)
    var replacing = false { didSet { needsLayout = true } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isHidden = true
        find.placeholderString = "Find in this tab…"; find.maximumRecents = 0; find.recentsAutosaveName = nil
        find.sendsWholeSearchString = true
        find.setAccessibilityLabel("Find text")
        replacement.placeholderString = "Replace with…"; replacement.bezelStyle = .roundedBezel
        replacement.setAccessibilityLabel("Replacement text")
        count.font = .systemFont(ofSize: 11); count.textColor = PocketPalette.secondary; count.lineBreakMode = .byTruncatingTail
        for control in [find,replacement,count,previous,next,close,toggle,regex,sensitive,replace,all] { addSubview(control) }
        for (button,symbol,label) in [(previous,"chevron.up","Previous match · ⇧⌘G"),(next,"chevron.down","Next match · ⌘G"),(close,"xmark","Close find · Esc"),(toggle,"arrow.left.arrow.right","Show replacement · ⌥⌘F")] {
            button.image = NSImage(systemSymbolName: symbol,accessibilityDescription: nil); button.toolTip = label; button.setAccessibilityLabel(label)
        }
        for button in [previous,next,close,toggle,regex,sensitive,replace,all] {
            button.isBordered = false; button.font = .systemFont(ofSize: 11, weight: .medium); button.contentTintColor = PocketPalette.secondary
        }
        for button in [regex,sensitive] { button.setButtonType(.pushOnPushOff) }
        regex.toolTip = "Regular expression · $1 and ${name} in replacement"; regex.setAccessibilityLabel("Regular expression")
        sensitive.toolTip = "Match case"; sensitive.setAccessibilityLabel("Match case")
        all.setAccessibilityLabel("Preview all replacements"); all.contentTintColor = PocketPalette.accent
        replace.setAccessibilityLabel("Replace current match")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let compact = bounds.width < 650
        let controlsY: CGFloat = compact ? 42 : 10
        let wanted: CGFloat = isHidden ? 0 : (compact ? 72 : 48) + (replacing ? 36 : 0)
        if height.constant != wanted { height.constant = wanted }
        close.frame = NSRect(x: bounds.width-40,y: 10,width: 24,height: 28)
        find.frame = NSRect(x:16,y:10,width:max(80,bounds.width-(compact ? 64 : 306)),height:28)
        let start: CGFloat = compact ? 16 : bounds.width-280
        count.frame = NSRect(x:start,y:controlsY+6,width:compact ? 108 : 82,height:18)
        previous.frame = NSRect(x:start+(compact ? 116 : 86),y:controlsY,width:24,height:28)
        next.frame = previous.frame.offsetBy(dx:28,dy:0)
        sensitive.frame = next.frame.offsetBy(dx:32,dy:0)
        regex.frame = sensitive.frame.offsetBy(dx:32,dy:0)
        toggle.frame = regex.frame.offsetBy(dx:32,dy:0)
        sensitive.contentTintColor = sensitive.state == .on ? PocketPalette.accent : PocketPalette.secondary
        regex.contentTintColor = regex.state == .on ? PocketPalette.accent : PocketPalette.secondary
        toggle.contentTintColor = replacing ? PocketPalette.accent : PocketPalette.secondary
        for control in [replacement,replace,all] { control.isHidden = !replacing }
        let y: CGFloat = compact ? 74 : 46
        replacement.frame = NSRect(x:16,y:y,width:max(80,bounds.width-180),height:26)
        replace.frame = NSRect(x:bounds.width-154,y:y,width:70,height:26)
        all.frame = NSRect(x:bounds.width-78,y:y,width:62,height:26)
    }
    override func draw(_ dirtyRect: NSRect) {
        PocketPalette.chrome.setFill(); dirtyRect.intersection(bounds).fill()
        PocketPalette.rule.setFill(); NSRect(x:0,y:bounds.height-0.5,width:bounds.width,height:0.5).fill()
    }
}

@MainActor private final class ReplacePreview: NSViewController {
    let frame: FindFrame; let apply: () -> Void
    init(frame: FindFrame, apply: @escaping () -> Void) { self.frame = frame; self.apply = apply; super.init(nibName:nil,bundle:nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame:NSRect(x:0,y:0,width:340,height:228))
        let title = NSTextField(labelWithString:"Replace \(frame.changed) matches?")
        title.font = .systemFont(ofSize:15,weight:.semibold); title.frame = NSRect(x:18,y:190,width:304,height:22); view.addSubview(title)
        for (index,example) in frame.examples.enumerated() {
            let text = NSTextField(wrappingLabelWithString:"\(example.before)  →  \(example.after)")
            text.font = .monospacedSystemFont(ofSize:11,weight:.regular); text.maximumNumberOfLines = 2
            text.frame = NSRect(x:18,y:144-index*40,width:304,height:36); view.addSubview(text)
        }
        let hint = NSTextField(labelWithString:"One Undo restores the original text.")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor; hint.frame = NSRect(x:18,y:20,width:210,height:18); view.addSubview(hint)
        let button = NSButton(title:"Replace all",target:self,action:#selector(confirm))
        button.bezelStyle = .rounded; button.frame = NSRect(x:226,y:12,width:100,height:30); button.keyEquivalent = "\r"; view.addSubview(button)
    }
    @objc private func confirm() { apply() }
}

@MainActor final class FindController: NSObject, NSSearchFieldDelegate {
    let bar: FindBar; let document: RustDocument; let textView: NSTextView
    var didReplace: ((NSRange) -> Void)?
    var didSelectAll: ((FindFrame,Int)->Void)?
    private var selectingAll=false
    private(set) var frame: FindFrame?
    private(set) var current: Int?
    private var engine: RustSearch?
    private var timer: Timer?
    private var popover: NSPopover?
    init(bar: FindBar, document: RustDocument, textView: NSTextView) {
        self.bar=bar; self.document=document; self.textView=textView; super.init()
        bar.find.delegate=self; bar.replacement.delegate=self
        for button in [bar.previous,bar.next,bar.close,bar.toggle,bar.regex,bar.sensitive,bar.replace,bar.all] { button.target=self }
        bar.previous.action=#selector(previous); bar.next.action=#selector(next); bar.close.action=#selector(close)
        bar.toggle.action=#selector(toggle); bar.regex.action=#selector(options); bar.sensitive.action=#selector(options)
        bar.replace.action=#selector(replaceOne); bar.all.action=#selector(previewAll)
    }
    var visible: Bool { !bar.isHidden }
    func open(replacing: Bool) {
        document.breakUndoGroup()
        if !visible {
            let range = textView.selectedRange()
            if range.length > 0 && range.length <= 512 { bar.find.stringValue = (textView.string as NSString).substring(with:range) }
            engine=RustSearch()
        }
        bar.replacing = replacing; bar.isHidden=false; bar.needsLayout=true; bar.layoutSubtreeIfNeeded()
        submit(); bar.window?.makeFirstResponder(bar.find); bar.find.selectText(nil)
    }
    @objc func close() {
        selectingAll=false
        timer?.invalidate(); timer=nil; popover?.performClose(nil); popover=nil
        engine=nil; frame=nil; current=nil
        let field=bar.window?.fieldEditor(false,for:bar.find) as? NSTextView
        textView.window?.makeFirstResponder(textView)
        field?.undoManager?.removeAllActions()
        bar.find.stringValue=""; bar.replacement.stringValue=""; bar.regex.state = .off; bar.sensitive.state = .off
        bar.find.recentSearches=[]
        bar.isHidden=true; bar.height.constant=0
        paint()
    }
    func controlTextDidChange(_ notification: Notification) { submit() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if control === bar.replacement { replaceOne() } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previous() } else { next() }; return true
        }
        return false
    }
    func sourceChanged() { if visible { submit() } }
    private func submit() {
        selectingAll=false
        popover?.performClose(nil); popover=nil; frame=nil; current=nil; paint()
        guard let engine, engine.submit(document,needle:bar.find.stringValue,replacement:bar.replacing ? bar.replacement.stringValue : nil,regex:bar.regex.state == .on,sensitive:bar.sensitive.state == .on) else { bar.count.stringValue="Find text too long"; updateButtons(); return }
        bar.count.stringValue = bar.find.stringValue.isEmpty ? "Find in this tab" : "Searching…"; updateButtons()
        if poll() && timer == nil { timer=Timer.scheduledTimer(withTimeInterval:0.04,repeats:true) { [weak self] timer in MainActor.assumeIsolated { guard let self else { timer.invalidate(); return }; self.poll() } } }
    }
    @discardableResult func poll() -> Bool {
        let busy=engine?.busy ?? false
        if let found=engine?.frame(document,after:frame?.serial ?? 0) {
            frame=found
            current=found.matches.firstIndex { $0.utf16_start >= textView.selectedRange().location } ?? (found.matches.isEmpty ? nil : 0)
            if let current { select(current) }
            updateButtons(); paint()
            if selectingAll {finishSelectAll()}
        }
        if !busy { timer?.invalidate(); timer=nil }
        return busy && visible
    }
    func selectAllForEditing() {selectingAll=true;if frame != nil {finishSelectAll()}}
    private func finishSelectAll() {
        selectingAll=false
        guard let frame,frame.revision==document.revision,frame.error==nil,!frame.limited,!frame.matches.isEmpty else {bar.count.stringValue="Refine Find";return}
        didSelectAll?(frame,current ?? 0)
    }
    private func updateButtons() {
        let valid=frame?.error == nil && frame?.limited == false
        bar.previous.isEnabled = !(frame?.matches.isEmpty ?? true); bar.next.isEnabled=bar.previous.isEnabled
        bar.replace.isEnabled = valid && bar.replacing && current != nil
        bar.all.isEnabled = valid && (frame?.changed ?? 0)>0
        if let frame {
            bar.count.stringValue = frame.error ?? (frame.limited ? "10,000+ · refine" : frame.matches.isEmpty ? "No matches" : "\((current ?? 0)+1) / \(frame.matches.count)")
            if bar.find.stringValue.isEmpty { bar.count.stringValue="Find in this tab" }
            bar.count.toolTip=frame.error ?? "\(frame.matches.count) matches in this tab"
        }
    }
    private func select(_ index: Int) { guard let frame, frame.revision==document.revision, index<frame.matches.count else { return }; textView.setSelectedRange(frame.matches[index].range); textView.scrollRangeToVisible(frame.matches[index].range) }
    func move(_ direction: Int) {
        guard let frame,!frame.matches.isEmpty,frame.revision==document.revision else { return }
        current=((current ?? (direction>0 ? -1 : 0))+direction+frame.matches.count)%frame.matches.count
        select(current!); updateButtons(); paint()
    }
    @objc private func next() { move(1) }
    @objc private func previous() { move(-1) }
    @objc private func options() { bar.needsLayout=true; submit() }
    @objc private func toggle() { bar.replacing.toggle(); bar.needsLayout=true; bar.layoutSubtreeIfNeeded(); submit() }
    @objc func replaceOne() { guard let current else { return }; apply(index:current) }
    @objc func previewAll() {
        guard let frame,frame.revision==document.revision,frame.error==nil,!frame.limited,frame.changed>0 else { return }
        let popover=NSPopover(); popover.behavior = .transient; popover.animates=false
        popover.contentViewController=ReplacePreview(frame:frame) { [weak self] in self?.apply(index:nil,serial:frame.serial) }
        self.popover=popover; popover.show(relativeTo:bar.all.bounds,of:bar.all,preferredEdge:.maxY)
    }
    func apply(index: Int?, serial: UInt64? = nil) {
        guard let engine, let serial=serial ?? frame?.serial, let result=engine.apply(document,serial:serial,index:index) else { popover?.performClose(nil); submit(); return }
        popover?.performClose(nil)
        popover=nil
        if result.changed { didReplace?(result.selection) } else { textView.setSelectedRange(result.selection) }; submit()
    }
    func paint() {
        guard let layout=textView.layoutManager, let container=textView.textContainer else { return }
        let length=(textView.string as NSString).length
        layout.removeTemporaryAttribute(.backgroundColor,forCharacterRange:NSRange(location:0,length:length))
        guard visible, let frame,frame.revision==document.revision else { return }
        let glyphs=layout.glyphRange(forBoundingRect:textView.visibleRect,in:container)
        let visible=layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
        let start=max(0,visible.location-2048), end=min(length,NSMaxRange(visible)+2048)
        for (index,hit) in frame.matches.enumerated() {
            if hit.utf16_start>=end { break }
            var range=hit.range
            if range.length==0 && range.location<length { range=(textView.string as NSString).rangeOfComposedCharacterSequence(at:range.location) }
            range=NSIntersectionRange(range,NSRange(location:start,length:max(0,end-start)))
            if range.length>0 { layout.addTemporaryAttribute(.backgroundColor,value:index==current ? PocketPalette.selection : PocketPalette.hover,forCharacterRange:range) }
        }
    }
}

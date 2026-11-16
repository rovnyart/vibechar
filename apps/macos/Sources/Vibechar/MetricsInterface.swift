import AppKit
import CVibechar

struct TextExtent:Decodable {
    let bytes:Int;let lines:Int;let characters:Int?;let words:Int?
}
struct TextMetrics:Decodable {
    let document:UInt64;let revision:UInt64;let serial:UInt64
    let total:TextExtent;let selected:TextExtent
    let targets:Int;let selections:Int;let carets:Int;let busy:Bool;let limited:Bool
    private func number(_ n:Int?)->String {n.map { $0.formatted(.number.locale(Locale(identifier:"en_US"))) } ?? (busy ? "…" : "—")}
    private func short(_ n:Int?)->String {
        guard let n else {return busy ? "…" : "—"}
        if n>=1_000_000 {return String(format:"%.1fM",Double(n)/1_000_000)}
        if n>=1_000 {return String(format:"%.1fK",Double(n)/1_000)}
        return String(n)
    }
    func summary(compact:Bool)->String {
        if selections>0 {
            if compact {return "\(short(selected.characters)) sel"}
            return targets>1 ? "\(targets) selections · \(number(selected.characters)) chars" : "\(number(selected.characters)) selected · \(selected.lines) \(selected.lines==1 ? "line" : "lines")"
        }
        if targets>1 {return "\(carets) carets"}
        return compact ? "\(short(total.characters)) ch" : "\(number(total.characters)) \(total.characters==1 ? "char" : "chars") · \(number(total.words)) \(total.words==1 ? "word" : "words")"
    }
    var details:String {
        func extent(_ e:TextExtent)->String {"\(number(e.characters)) characters · \(number(e.words)) words\n\(number(e.lines)) logical \(e.lines==1 ? "line" : "lines") · \(number(e.bytes)) UTF-8 bytes"}
        return "DOCUMENT\n"+extent(total)+"\n\nSELECTION\n"+extent(selected)+"\n\(selections) selections · \(carets) carets\n\nCharacters count graphemes: 👩‍💻 and é each count as one; CRLF counts as one. Words are runs of letters, numbers or underscores."+(limited ? "\nDetailed counts unavailable for this text (64 MiB / time budget)." : "")
    }
}
@MainActor final class RustMetrics {
    private let handle:OpaquePointer
    init() {guard let handle=vc_metrics_new() else {preconditionFailure("Unable to allocate statistics")};self.handle=handle}
    deinit {vc_metrics_free(handle)}
    func submit(_ document:RustDocument,ranges:[NSRange]) {
        let starts=ranges.map(\.location),lengths=ranges.map(\.length)
        _=starts.withUnsafeBufferPointer {s in lengths.withUnsafeBufferPointer {l in vc_metrics_submit(handle,document.handle,s.baseAddress,l.baseAddress,s.count)}}
    }
    func frame(_ document:RustDocument)->TextMetrics? {
        let count=vc_metrics_state(handle,document.handle,nil,0);guard count>0 else {return nil}
        var bytes=[UInt8](repeating:0,count:count)
        let copied=bytes.withUnsafeMutableBufferPointer {vc_metrics_state(handle,document.handle,$0.baseAddress,$0.count)}
        // A worker can finish between measuring and copying. Retry the new size.
        if copied != count {return frame(document)}
        return try? JSONDecoder().decode(TextMetrics.self,from:Data(bytes))
    }
}

@MainActor final class MetricsPopover:NSViewController {
    private var value:TextMetrics?
    private var values:[NSTextField]=[]
    private var state:NSTextField?
    init(_ value:TextMetrics?) {self.value=value;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    func update(_ value:TextMetrics?) {
        self.value=value
        let n:(Int?)->String={v in v.map {$0.formatted(.number.locale(Locale(identifier:"en_US")))} ?? (value?.busy==true ? "…" : "—")}
        let numbers=[value?.total.characters,value?.selected.characters,value?.total.words,value?.selected.words,value?.total.lines,value?.selected.lines,value?.total.bytes,value?.selected.bytes]
        for (label,number) in zip(values,numbers) {label.stringValue=n(number)}
        state?.stringValue=value.map {"\($0.selections) selections · \($0.carets) carets"+($0.limited ? " · Count limit reached" : $0.busy ? " · Counting…" : "")} ?? "Counting…"
    }
    override func loadView() {
        let root=PocketSurface(frame:NSRect(x:0,y:0,width:380,height:306))
        func label(_ title:String,_ rect:NSRect,_ font:NSFont,_ color:NSColor)->NSTextField {
            let field=NSTextField(labelWithString:title);field.frame=rect;field.font=font;field.textColor=color;root.addSubview(field);return field
        }
        _=label("V_  TEXT STATISTICS",NSRect(x:20,y:18,width:340,height:20),.monospacedSystemFont(ofSize:13,weight:.semibold),PocketPalette.accent)
        for (x,title) in [(126,"DOCUMENT"),(242,"SELECTED")] {
            let field=label(title,NSRect(x:CGFloat(x),y:58,width:112,height:16),.monospacedSystemFont(ofSize:10,weight:.medium),PocketPalette.secondary);field.alignment = .right
        }
        for (row,title) in ["Characters","Words","Lines","UTF-8 bytes"].enumerated() {
            let y=CGFloat(87+row*27)
            _=label(title,NSRect(x:20,y:y,width:106,height:18),.systemFont(ofSize:12),PocketPalette.secondary)
            for x in [126,242] {
                let field=label("—",NSRect(x:CGFloat(x),y:y,width:112,height:18),.monospacedDigitSystemFont(ofSize:12,weight:.medium),PocketPalette.ink);field.alignment = .right;values.append(field)
            }
        }
        state=label("",NSRect(x:20,y:206,width:340,height:18),.systemFont(ofSize:11),PocketPalette.accent)
        let note=NSTextField(wrappingLabelWithString:"Characters count graphemes: 👩‍💻 and é each count once. CRLF counts once. Words use letters, numbers and underscores.")
        note.frame=NSRect(x:20,y:242,width:340,height:52);note.font = .systemFont(ofSize:11);note.textColor=PocketPalette.secondary;root.addSubview(note)
        view=root;update(value)
    }
}

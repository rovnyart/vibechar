import AppKit

@MainActor final class PocketLineNumbers:NSRulerView {
    private let editor:PocketTextView
    private let document:RustDocument
    private var rows:[(Int,NSRect)]=[]
    var activeLine=0
    var onSelect:((Int)->Void)?
    override var isFlipped:Bool {true}
    init(scroll:NSScrollView,editor:PocketTextView,document:RustDocument) {
        self.editor=editor;self.document=document
        super.init(scrollView:scroll,orientation:.verticalRuler)
        clientView=editor;ruleThickness=44;clipsToBounds=true
        setAccessibilityLabel("Line numbers")
        toolTip="Click a number to select the logical line · View → Line Numbers"
    }
    required init(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    private var numberFont:NSFont {.monospacedDigitSystemFont(ofSize:max(10,min(13,(editor.font?.pointSize ?? 15)-3)),weight:.regular)}
    func refresh() {
        setAccessibilityValue("Current line \(activeLine+1)")
        let digits=max(2,String(document.lineCount).count)
        let width=max(44,ceil((String(repeating:"8",count:digits) as NSString).size(withAttributes:[.font:numberFont]).width)+22)
        if ruleThickness != width {ruleThickness=width}
        needsDisplay=true
    }
    override func drawHashMarksAndLabels(in rect:NSRect) {
        NSGraphicsContext.saveGraphicsState();defer {NSGraphicsContext.restoreGraphicsState()}
        bounds.clip()
        PocketPalette.canvas.setFill();rect.fill();rows=[]
        guard let layout=editor.layoutManager,let container=editor.textContainer else {return}
        let origin=editor.textContainerOrigin
        let visible=editor.visibleRect.offsetBy(dx:-origin.x,dy:-origin.y)
        let glyphs=layout.glyphRange(forBoundingRect:visible,in:container)
        var previous:Int?
        func draw(_ line:Int,_ fragment:NSRect) {
            let p=convert(NSPoint(x:0,y:fragment.minY+origin.y),from:editor)
            let row=NSRect(x:0,y:p.y,width:ruleThickness,height:fragment.height)
            rows.append((line,row))
            guard row.intersects(bounds) else {return}
            let repeated=previous==line;previous=line
            let text=repeated ? "·" : String(line+1)
            let font=numberFont
            let size=(text as NSString).size(withAttributes:[.font:font])
            let y=row.midY-size.height/2
            if line==activeLine && !repeated {
                PocketPalette.accent.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect:NSRect(x:5,y:row.minY+2,width:ruleThickness-10,height:max(0,row.height-4)),xRadius:4,yRadius:4).fill()
            }
            (text as NSString).draw(at:NSPoint(x:ruleThickness-11-size.width,y:y),withAttributes:[.font:font,.foregroundColor:line==activeLine ? PocketPalette.accent : PocketPalette.secondary.withAlphaComponent(repeated ? 0.35 : 0.65)])
        }
        if glyphs.length>0 {
            layout.enumerateLineFragments(forGlyphRange:glyphs) { fragment,_,_,range,_ in
                let at=layout.characterIndexForGlyph(at:range.location)
                let line=self.document.lineIndex(at:at)
                if line>=0 {draw(line,fragment)}
            }
        }
        let last=max(0,document.lineCount-1)
        if let range=document.lineRange(last),range.length==0 {
            var fragment=layout.extraLineFragmentRect
            if (editor.textStorage?.length ?? 0)==0 {fragment=NSRect(x:0,y:0,width:1,height:layout.defaultLineHeight(for:editor.font ?? .monospacedSystemFont(ofSize:15,weight:.regular))+6)}
            if fragment.height>0 {draw(last,fragment)}
        }
        PocketPalette.rule.withAlphaComponent(0.55).setFill()
        NSRect(x:ruleThickness-0.5,y:bounds.minY,width:0.5,height:bounds.height).fill()
    }
    override func mouseDown(with event:NSEvent) {
        displayIfNeeded()
        let point=convert(event.locationInWindow,from:nil)
        if let row=rows.first(where:{$0.1.contains(point)}) {onSelect?(row.0)}
    }
}

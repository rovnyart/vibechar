import AppKit

struct RewriteDiff {
    static let displayLimit = 4096
    struct Line {
        let kind: Int; let text: String
        var hasEnding: Bool { text.utf8.last == 10 }
        var displayText: String {
            if hasEnding && text.utf8.dropLast().last == 13 { return String(decoding: text.utf8.dropLast(2),as: UTF8.self)+"\n" }
            return text + (hasEnding ? "" : "\n")
        }
    }
    let lines: [Line]
    let coarse: Bool
    var added: Int { lines.reduce(0) { $0 + ($1.kind == 1 ? 1 : 0) } }
    var removed: Int { lines.reduce(0) { $0 + ($1.kind == -1 ? 1 : 0) } }
    var displayStart: Int { max(0,(lines.firstIndex { $0.kind != 0 } ?? 0)-3) }
    var partial: Bool { lines.count-displayStart > Self.displayLimit }

    init(before: String, after: String) {
        func split(_ text: String) -> [String] {
            let bytes = Array(text.utf8)
            var result: [String] = [], from = 0
            for at in bytes.indices where bytes[at] == 10 {
                result.append(String(decoding: bytes[from...at],as: UTF8.self)); from = at + 1
            }
            if from < bytes.count { result.append(String(decoding: bytes[from...],as: UTF8.self)) }
            return result
        }
        let a = split(before), b = split(after)
        var prefix = 0, suffix = 0
        while prefix < min(a.count,b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count,b.count) - prefix, a[a.count-1-suffix] == b[b.count-1-suffix] { suffix += 1 }
        let old = Array(a[prefix..<(a.count-suffix)]), new = Array(b[prefix..<(b.count-suffix)])
        var lines = a.prefix(prefix).map { Line(kind: 0, text: $0) }
        coarse = (old.count + 1) * (new.count + 1) > 262_144
        if coarse {
            lines += old.map { Line(kind: -1, text: $0) } + new.map { Line(kind: 1, text: $0) }
        } else {
            let width = new.count + 1
            var lcs = [Int32](repeating: 0, count: (old.count + 1) * width)
            for i in old.indices.reversed() {
                for j in new.indices.reversed() {
                    lcs[i*width+j] = old[i] == new[j] ? 1+lcs[(i+1)*width+j+1] : max(lcs[(i+1)*width+j],lcs[i*width+j+1])
                }
            }
            var i = 0, j = 0
            while i < old.count || j < new.count {
                if i < old.count, j < new.count, old[i] == new[j] { lines.append(Line(kind: 0,text: old[i])); i += 1; j += 1 }
                else if i < old.count, j == new.count || lcs[(i+1)*width+j] >= lcs[i*width+j+1] { lines.append(Line(kind: -1,text: old[i])); i += 1 }
                else { lines.append(Line(kind: 1,text: new[j])); j += 1 }
            }
        }
        lines += a.suffix(suffix).map { Line(kind: 0,text: $0) }
        self.lines = lines
    }
}

final class RewriteSurface: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func draw(_ dirtyRect: NSRect) { PocketPalette.canvas.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class RewriteInstruction: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("Make it clearer, shorter, friendlier…" as NSString).draw(at: NSPoint(x: textContainerInset.width+5,y: textContainerInset.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: PocketPalette.secondary])
        }
    }
}

@MainActor
final class RewriteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let model: RewriteModel
    let instruction: NSTextView = RewriteInstruction()
    let preview = NSTextView()
    let tabs = NSSegmentedControl(labels: ["Source", "Changes", "Result"], trackingMode: .selectOne, target: nil, action: nil)
    let generateButton = NSButton(title: "Preview changes", target: nil, action: nil)
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    let protectButton = NSButton(title: "Keep exact", target: nil, action: nil)
    let clearButton = NSButton(title: "Clear kept", target: nil, action: nil)
    let settingsButton = NSButton(title: "AI Settings…", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private let heading = NSTextField(labelWithString: "Shape this selection.")
    private let brand = NSTextField(labelWithString: "V_")
    private let scope = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let privacy = NSTextField(labelWithString: "Only selection + instruction. Kept fragments stay local. API billing applies.")
    private let spinner = NSProgressIndicator()
    private let instructionScroll = NSScrollView()
    private let previewScroll = NSScrollView()
    private var rendering = false
    private var lastPhase: RewriteModel.Phase?
    private var diff: RewriteDiff?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?

    init(model: RewriteModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 760,height: 720),
                              styleMask: [.titled,.closable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Rewrite Selection"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.minSize = NSSize(width: 640,height: 600)
        let root = RewriteSurface(frame: NSRect(x: 0,y: 0,width: 760,height: 720)); window.contentView = root
        super.init(window: window); window.delegate = self; window.center()
        heading.font = .systemFont(ofSize: 27,weight: .semibold); heading.textColor = PocketPalette.ink
        brand.font = .monospacedSystemFont(ofSize: 18,weight: .bold); brand.textColor = PocketPalette.accent
        scope.font = .systemFont(ofSize: 12); scope.textColor = PocketPalette.secondary
        privacy.font = .systemFont(ofSize: 10); privacy.textColor = PocketPalette.secondary
        privacy.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 3
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        [heading,brand,scope,tabs,instructionScroll,previewScroll,protectButton,clearButton,status,privacy,spinner,
         settingsButton,discardButton,generateButton,applyButton].forEach { root.addSubview($0) }
        for (scroll,text,editable) in [(instructionScroll,instruction,true),(previewScroll,preview,false)] {
            scroll.borderType = .lineBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = true; scroll.backgroundColor = PocketPalette.canvas
            text.isRichText = false; text.isEditable = editable; text.isSelectable = true
            text.allowsUndo = editable; text.drawsBackground = true; text.backgroundColor = PocketPalette.canvas
            text.textColor = PocketPalette.ink; text.font = editable ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 12,weight: .regular)
            text.textContainerInset = NSSize(width: 9,height: 9)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            text.textContainer?.heightTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: 712,height: CGFloat.greatestFiniteMagnitude)
            text.minSize = .zero
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,height: CGFloat.greatestFiniteMagnitude)
            text.layoutManager?.allowsNonContiguousLayout = true
            text.layoutManager?.backgroundLayoutEnabled = false
            text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
            text.delegate = self; scroll.documentView = text
        }
        instruction.setAccessibilityLabel("Rewrite instruction")
        preview.setAccessibilityLabel("Source selection")
        for button in [generateButton,applyButton,protectButton,clearButton,settingsButton,discardButton] { button.bezelStyle = .rounded; button.target = self }
        generateButton.action = #selector(generate); generateButton.keyEquivalent = "\r"; generateButton.keyEquivalentModifierMask = [.command]
        applyButton.action = #selector(apply); applyButton.keyEquivalent = "\r"; applyButton.keyEquivalentModifierMask = [.command,.shift]
        applyButton.contentTintColor = PocketPalette.accent
        protectButton.action = #selector(protect); clearButton.action = #selector(clearProtection)
        protectButton.toolTip = "Select a fragment in Source to keep it local and unchanged"
        settingsButton.action = #selector(settings); discardButton.action = #selector(discard)
        discardButton.keyEquivalent = "\u{1b}"
        tabs.target = self; tabs.action = #selector(changeTab); tabs.selectedSegment = 0
        model.onChange = { [weak self] in self?.render() }
        root.onLayout = { [weak self] in self?.layout() }
        window.initialFirstResponder = instruction
        render(); layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(instruction) }
    func shutdown() { model.close(); clearText(); close() }
    func windowWillClose(_ notification: Notification) { model.close(); clearText(); onClose?() }
    private func clearText() { instruction.string = ""; instruction.undoManager?.removeAllActions(); preview.string = ""; diff = nil }
    @objc private func generate() { if model.busy { model.cancel() } else { model.generate() } }
    @objc private func apply() { model.apply() }
    @objc private func protect() { model.protect(preview.selectedRange()) }
    @objc private func clearProtection() { model.clearProtection() }
    @objc private func discard() { close() }
    @objc private func settings() { onSettings?() }
    @objc private func changeTab() { displayPreview(); updateProtectionButtons() }
    func textDidChange(_ notification: Notification) {
        if notification.object as? NSTextView === instruction { instruction.needsDisplay = true; model.editInstruction(instruction.string) }
    }
    func textViewDidChangeSelection(_ notification: Notification) { if !rendering { updateProtectionButtons() } }
    private func updateProtectionButtons() {
        protectButton.isEnabled = tabs.selectedSegment == 0 && preview.selectedRange().length > 0 && !model.busy && model.phase != .stale && model.phase != .closed
        clearButton.isEnabled = !model.protected.isEmpty && !model.busy && model.phase != .stale && model.phase != .closed
    }
    private func layout() {
        guard let root = window?.contentView else { return }
        let w = root.bounds.width, h = root.bounds.height
        brand.frame = NSRect(x: w-62,y: 20,width: 40,height: 24)
        heading.frame = NSRect(x: 24,y: 53,width: w-48,height: 36)
        scope.frame = NSRect(x: 25,y: 96,width: w-50,height: 20)
        instructionScroll.frame = NSRect(x: 24,y: 128,width: w-48,height: 58)
        instruction.setFrameSize(NSSize(width: instructionScroll.contentSize.width,height: max(instructionScroll.contentSize.height,instruction.frame.height)))
        tabs.frame = NSRect(x: 24,y: 201,width: 260,height: 25)
        protectButton.frame = NSRect(x: w-224,y: 199,width: 100,height: 28)
        clearButton.frame = NSRect(x: w-120,y: 199,width: 100,height: 28)
        previewScroll.frame = NSRect(x: 24,y: 238,width: w-48,height: h-382)
        preview.setFrameSize(NSSize(width: previewScroll.contentSize.width,height: max(previewScroll.contentSize.height,preview.frame.height)))
        privacy.frame = NSRect(x: 25,y: h-133,width: w-50,height: 18)
        spinner.frame = NSRect(x: 25,y: h-99,width: 14,height: 14)
        status.frame = NSRect(x: 48,y: h-102,width: w-72,height: 42)
        settingsButton.frame = NSRect(x: 18,y: h-44,width: 112,height: 28)
        discardButton.frame = NSRect(x: 134,y: h-44,width: 86,height: 28)
        generateButton.frame = NSRect(x: w-286,y: h-44,width: 150,height: 28)
        applyButton.frame = NSRect(x: w-130,y: h-44,width: 112,height: 28)
    }
    private func render() {
        rendering = true; defer { rendering = false }
        if instruction.string != model.instruction { instruction.string = model.instruction }
        instruction.isEditable = model.phase != .closed
        if model.phase == .preview, lastPhase != .preview { diff = RewriteDiff(before: model.source,after: model.result ?? ""); tabs.selectedSegment = 1 }
        if model.result == nil { diff = nil; tabs.selectedSegment = 0 }
        lastPhase = model.phase
        tabs.setEnabled(model.result != nil,forSegment: 1); tabs.setEnabled(model.result != nil,forSegment: 2)
        scope.stringValue = "\(model.usedModel.title) · \(model.source.count) characters selected · \(model.protected.count) kept exact"
        status.stringValue = model.status
        if model.phase == .preview, diff?.partial == true { status.stringValue += " Diff preview is partial; inspect the full Result." }
        status.textColor = model.phase == .error || model.phase == .stale ? PocketPalette.accent : PocketPalette.secondary
        generateButton.title = model.busy ? "Cancel request" : "Preview changes"
        generateButton.isEnabled = model.busy || model.canGenerate
        applyButton.isEnabled = model.phase == .preview
        if model.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        displayPreview(); updateProtectionButtons()
    }
    private func displayPreview() {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12,weight: .regular), .foregroundColor: PocketPalette.ink]
        preview.setAccessibilityLabel(["Source selection","Proposed changes","Proposed replacement"][max(0,tabs.selectedSegment)])
        if tabs.selectedSegment == 1, let diff {
            let content = NSMutableAttributedString()
            if diff.displayStart > 0 {
                content.append(NSAttributedString(string: "⋯ \(diff.displayStart) unchanged lines above\n",attributes: base))
            }
            let showEnding = (model.source.utf8.last == 10) != (model.result?.utf8.last == 10)
            for line in diff.lines.dropFirst(diff.displayStart).prefix(RewriteDiff.displayLimit) {
                var attributes = base
                let prefix = line.kind < 0 ? "− " : line.kind > 0 ? "+ " : "  "
                if line.kind != 0 { attributes[.backgroundColor] = (line.kind < 0 ? NSColor.systemRed : NSColor.systemGreen).withAlphaComponent(0.12) }
                content.append(NSAttributedString(string: prefix + line.displayText,attributes: attributes))
                if showEnding, line.kind != 0, !line.hasEnding {
                    content.append(NSAttributedString(string: "  ↳ no final newline\n",attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10,weight: .regular), .foregroundColor: PocketPalette.secondary]))
                }
            }
            if diff.partial {
                content.append(NSAttributedString(string: "⋯ Diff preview limited to 4,096 lines. Source and Result contain the full text.\n",attributes: base))
            }
            preview.textStorage?.setAttributedString(content)
            tabs.setLabel("Changes +\(diff.added) −\(diff.removed)\(diff.partial ? " · part" : diff.coarse ? " · block" : "")",forSegment: 1)
        } else {
            let text = tabs.selectedSegment == 2 ? model.result ?? "" : model.source
            if preview.string != text { preview.string = text }
            preview.textStorage?.setAttributes(base,range: NSRange(location: 0,length: (text as NSString).length))
            if tabs.selectedSegment == 0 {
                for kept in model.protected { preview.textStorage?.addAttribute(.backgroundColor,value: PocketPalette.selection,range: kept.range) }
            }
        }
        preview.needsDisplay = true
    }
}

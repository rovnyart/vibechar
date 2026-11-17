import AppKit

@MainActor
final class ExampleWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let model: ExampleModel
    let beforeText = NSTextView()
    let afterText = NSTextView()
    let preview = NSTextView()
    let tabs = NSSegmentedControl(labels: ["Source","Changes","Result","Rule","Skipped"],trackingMode: .selectOne,target: nil,action: nil)
    let learnButton = NSButton(title: "Do the rest",target: nil,action: nil)
    let applyButton = NSButton(title: "Apply",target: nil,action: nil)
    private let settingsButton = NSButton(title: "AI Settings…",target: nil,action: nil)
    private let discardButton = NSButton(title: "Discard",target: nil,action: nil)
    private let brand = NSTextField(labelWithString: "V_")
    private let heading = NSTextField(labelWithString: "Show me once.")
    private let scope = NSTextField(labelWithString: "")
    private let beforeLabel = NSTextField(labelWithString: "BEFORE")
    private let afterLabel = NSTextField(labelWithString: "AFTER · EDIT THIS ROW")
    private let arrow = NSTextField(labelWithString: "→")
    private let summary = NSTextField(labelWithString: "Change the example on the right. The first nonblank selected row is your example.")
    private let privacy = NSTextField(labelWithString: "Only this example pair goes to OpenAI. Remaining rows run locally. API billing applies.")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let beforeScroll = NSScrollView(), afterScroll = NSScrollView(), previewScroll = NSScrollView()
    private var diff: RewriteDiff?
    private var lastPhase: ExampleModel.Phase?
    private var showingSource = false
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?

    init(model: ExampleModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 820,height: 760),
                              styleMask: [.titled,.closable,.resizable,.fullSizeContentView],backing: .buffered,defer: false)
        window.title = "Do the Rest"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.minSize = NSSize(width: 700,height: 640)
        let root = RewriteSurface(frame: NSRect(x: 0,y: 0,width: 820,height: 760)); window.contentView = root
        super.init(window: window); window.delegate = self; window.center()
        heading.font = .systemFont(ofSize: 27,weight: .semibold); heading.textColor = PocketPalette.ink
        brand.font = .monospacedSystemFont(ofSize: 18,weight: .bold); brand.textColor = PocketPalette.accent
        scope.font = .systemFont(ofSize: 12); scope.textColor = PocketPalette.secondary
        for label in [beforeLabel,afterLabel] { label.font = .monospacedSystemFont(ofSize: 10,weight: .semibold); label.textColor = PocketPalette.secondary }
        afterLabel.textColor = PocketPalette.accent
        arrow.font = .systemFont(ofSize: 18,weight: .medium); arrow.textColor = PocketPalette.accent
        summary.font = .systemFont(ofSize: 11); summary.textColor = PocketPalette.secondary; summary.lineBreakMode = .byTruncatingTail
        privacy.font = .systemFont(ofSize: 10); privacy.textColor = PocketPalette.secondary; privacy.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 3
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        [brand,heading,scope,beforeLabel,afterLabel,arrow,summary,privacy,status,spinner,beforeScroll,afterScroll,previewScroll,
         tabs,settingsButton,discardButton,learnButton,applyButton].forEach { root.addSubview($0) }
        for (scroll,text,editable) in [(beforeScroll,beforeText,false),(afterScroll,afterText,true),(previewScroll,preview,false)] {
            scroll.borderType = .lineBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = true; scroll.backgroundColor = PocketPalette.canvas
            text.isRichText = false; text.isEditable = editable; text.isSelectable = true; text.allowsUndo = editable
            text.drawsBackground = true; text.backgroundColor = PocketPalette.canvas; text.textColor = PocketPalette.ink
            text.font = .monospacedSystemFont(ofSize: 12,weight: .regular); text.textContainerInset = NSSize(width: 9,height: 9)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
            text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true; text.textContainer?.heightTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: 760,height: CGFloat.greatestFiniteMagnitude)
            text.layoutManager?.allowsNonContiguousLayout = true; text.layoutManager?.backgroundLayoutEnabled = false
            text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
            text.delegate = self; scroll.documentView = text
        }
        beforeText.setAccessibilityLabel("Original example row"); afterText.setAccessibilityLabel("Edit the desired example row")
        preview.setAccessibilityLabel("Selected rows")
        for button in [settingsButton,discardButton,learnButton,applyButton] { button.bezelStyle = .rounded; button.target = self }
        settingsButton.action = #selector(settings); discardButton.action = #selector(discard); discardButton.keyEquivalent = "\u{1b}"
        learnButton.action = #selector(learn); learnButton.keyEquivalent = "\r"; learnButton.keyEquivalentModifierMask = [.command]
        applyButton.action = #selector(apply); applyButton.keyEquivalent = "\r"; applyButton.keyEquivalentModifierMask = [.command,.shift]
        applyButton.contentTintColor = PocketPalette.accent
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab)
        model.onChange = { [weak self] in self?.render() }; root.onLayout = { [weak self] in self?.layout() }
        window.initialFirstResponder = afterText
        render(); layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(afterText) }
    func shutdown() { model.close(); clearText(); close() }
    func windowWillClose(_ notification: Notification) { model.close(); clearText(); onClose?() }
    private func clearText() { beforeText.string = ""; afterText.string = ""; afterText.undoManager?.removeAllActions(); preview.string = ""; diff = nil }
    @objc private func learn() { if model.busy { model.cancel() } else { model.learn() } }
    @objc private func apply() { model.apply() }
    @objc private func discard() { close() }
    @objc private func settings() { onSettings?() }
    @objc private func changeTab() { displayPreview() }
    func textDidChange(_ notification: Notification) { if notification.object as? NSTextView === afterText { model.editAfter(afterText.string) } }
    private func layout() {
        guard let root = window?.contentView else { return }
        let w = root.bounds.width, h = root.bounds.height, half = (w-72)/2
        brand.frame = NSRect(x: w-62,y: 20,width: 40,height: 24)
        heading.frame = NSRect(x: 24,y: 53,width: w-48,height: 36)
        scope.frame = NSRect(x: 25,y: 96,width: w-50,height: 20)
        beforeLabel.frame = NSRect(x: 25,y: 128,width: half,height: 16)
        afterLabel.frame = NSRect(x: w/2+13,y: 128,width: half,height: 16)
        beforeScroll.frame = NSRect(x: 24,y: 151,width: half,height: 80)
        afterScroll.frame = NSRect(x: w/2+12,y: 151,width: half,height: 80)
        arrow.frame = NSRect(x: w/2-8,y: 180,width: 20,height: 24)
        summary.frame = NSRect(x: 25,y: 242,width: w-50,height: 18)
        tabs.frame = NSRect(x: 24,y: 270,width: w-48,height: 25)
        previewScroll.frame = NSRect(x: 24,y: 307,width: w-48,height: h-451)
        for (scroll,text) in [(beforeScroll,beforeText),(afterScroll,afterText),(previewScroll,preview)] {
            text.setFrameSize(NSSize(width: scroll.contentSize.width,height: max(scroll.contentSize.height,text.frame.height)))
        }
        privacy.frame = NSRect(x: 25,y: h-133,width: w-50,height: 18)
        spinner.frame = NSRect(x: 25,y: h-99,width: 14,height: 14)
        status.frame = NSRect(x: 48,y: h-102,width: w-72,height: 42)
        settingsButton.frame = NSRect(x: 18,y: h-44,width: 112,height: 28)
        discardButton.frame = NSRect(x: 134,y: h-44,width: 86,height: 28)
        learnButton.frame = NSRect(x: w-286,y: h-44,width: 150,height: 28)
        applyButton.frame = NSRect(x: w-130,y: h-44,width: 112,height: 28)
    }
    private func render() {
        let frame = model.frame
        if beforeText.string != frame?.before ?? "" { beforeText.string = frame?.before ?? "" }
        if afterText.string != model.after { afterText.string = model.after }
        afterText.isEditable = model.phase != .closed
        if model.phase == .preview, lastPhase != .preview { diff = RewriteDiff(before: frame?.source ?? "",after: frame?.result ?? ""); tabs.selectedSegment = 1 }
        if frame?.result == nil { diff = nil; tabs.selectedSegment = 0 }
        lastPhase = model.phase
        for index in 1...3 { tabs.setEnabled(frame?.result != nil,forSegment: index) }
        tabs.setEnabled((frame?.stats?.skipped ?? 0) > 0,forSegment: 4)
        scope.stringValue = "\(model.usedModel.title) · \(frame?.records ?? 0) rows · example is selection row \(frame?.example_line ?? 0)"
        summary.stringValue = frame?.summary ?? "Edit the example on the right. Only the example pair is shared."
        summary.toolTip = summary.stringValue
        status.stringValue = model.status
        if model.phase == .preview, diff?.partial == true { status.stringValue += " Partial diff; inspect the full Result." }
        status.textColor = model.phase == .error || model.phase == .stale ? PocketPalette.accent : PocketPalette.secondary
        learnButton.title = model.busy ? "Cancel" : "Do the rest"
        learnButton.isEnabled = model.busy || model.canLearn; applyButton.isEnabled = model.canApply
        if model.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        displayPreview()
    }
    private func displayPreview() {
        if tabs.selectedSegment == 0 && showingSource && model.phase != .closed { return }
        showingSource = tabs.selectedSegment == 0 && model.phase != .closed
        let frame = model.frame
        let attributes: [NSAttributedString.Key:Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12,weight: .regular),.foregroundColor: PocketPalette.ink]
        if tabs.selectedSegment == 1, let diff {
            let text = NSMutableAttributedString()
            if diff.displayStart > 0 { text.append(NSAttributedString(string: "⋯ \(diff.displayStart) unchanged lines above\n",attributes: attributes)) }
            for line in diff.lines.dropFirst(diff.displayStart).prefix(RewriteDiff.displayLimit) {
                var style = attributes
                if line.kind != 0 { style[.backgroundColor] = (line.kind < 0 ? NSColor.systemRed : .systemGreen).withAlphaComponent(0.12) }
                text.append(NSAttributedString(string: (line.kind < 0 ? "− " : line.kind > 0 ? "+ " : "  ")+line.displayText,attributes: style))
            }
            if diff.partial { text.append(NSAttributedString(string: "⋯ First 4,096 diff lines. Source and Result contain the complete text.\n",attributes: attributes)) }
            preview.textStorage?.setAttributedString(text)
        } else {
            let text: String
            switch tabs.selectedSegment {
            case 2: text = frame?.result ?? ""
            case 3: text = frame?.explanation ?? ""
            case 4:
                let issues = frame?.stats?.issues ?? []
                text = issues.map { "Selection row \($0.line): \($0.reason)" }.joined(separator: "\n") + "\n\nShowing up to 8 examples. All skipped rows keep their original bytes."
            default: text = frame?.source ?? ""
            }
            if preview.string != text { preview.string = text }
            preview.textStorage?.setAttributes(attributes,range: NSRange(location: 0,length: (text as NSString).length))
        }
        preview.setAccessibilityLabel(["Selected rows","Proposed changes","Complete result","Validated rule","Skipped rows"][max(0,tabs.selectedSegment)])
    }
}

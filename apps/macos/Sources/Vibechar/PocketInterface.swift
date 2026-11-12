import AppKit

private final class PocketTitlebarSpacer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
func preparePocketTitlebar(for window: NSWindow) {
    // Let AppKit grow the real titlebar container before positioning its buttons.
    // System padding varies by macOS version; measure it instead of assuming it.
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .bottom
    accessory.view = PocketTitlebarSpacer(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    // A fixed autoresizing width becomes a titlebar minimum and blocks shrinking.
    accessory.view.translatesAutoresizingMaskIntoConstraints = false
    let height = accessory.view.heightAnchor.constraint(equalToConstant: 1)
    height.isActive = true
    window.addTitlebarAccessoryViewController(accessory)
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    let nativeHeight = window.standardWindowButton(.closeButton)?.superview?.bounds.height ?? 54
    height.constant = max(1, 1 + 54 - nativeHeight)
    window.contentView?.superview?.layoutSubtreeIfNeeded()
}

// Keep the text surface opaque. These colors resolve with the window's appearance.
enum PocketPalette {
    static let canvas = color(0xFCFBF8, 0x20211F)
    static let chrome = color(0xF0EFEB, 0x292A27)
    static let ink = color(0x282B29, 0xE3E5DF)
    static let secondary = color(0x666B64, 0xA2A79C)
    static let rule = color(0xDEDFD8, 0x3B3E36)
    static let accent = color(0xBD4C2B, 0xF49A6B)
    static let selection = color(0xF3DCCD, 0x59402E)
    static let hover = color(0xE6E5DF, 0x353730)
    static let active = color(0xFCFBF8, 0x3A3C36)

    private static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

final class PocketSurface: NSView {
    var appearanceChanged: (() -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        PocketPalette.canvas.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
        invalidateAppearance(in: self)
    }
    func invalidateAppearance(in view: NSView) {
        view.needsDisplay = true
        view.needsLayout = true
        view.subviews.forEach { invalidateAppearance(in: $0) }
    }
}

final class PocketTextView: NSTextView {
    private(set) var editKind: TextEditKind = .isolated
    private var editDepth = 0
    var isPerformingEdit: Bool { editDepth > 0 }
    var onBreakUndoGroup: (() -> Void)?
    var onEscape: (() -> Bool)?
    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true { super.cancelOperation(sender) }
    }

    // The outer action wins: a paste may internally call insertText.
    private func performEdit<T>(_ kind: TextEditKind, _ operation: () -> T) -> T {
        let previous = editKind
        if editDepth == 0 {
            editKind = kind
            if kind == .isolated { onBreakUndoGroup?() }
        }
        editDepth += 1
        defer { editDepth -= 1; editKind = previous }
        return operation()
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        performEdit(.typing) { super.insertText(insertString, replacementRange: replacementRange) }
    }
    override func deleteBackward(_ sender: Any?) {
        performEdit(selectedRange().length == 0 ? .backspace : .isolated) { super.deleteBackward(sender) }
    }
    override func deleteForward(_ sender: Any?) {
        performEdit(selectedRange().length == 0 ? .deleteForward : .isolated) { super.deleteForward(sender) }
    }
    override func paste(_ sender: Any?) {
        performEdit(.isolated) { super.paste(sender) }
    }
    override func pasteAsPlainText(_ sender: Any?) {
        performEdit(.isolated) { super.pasteAsPlainText(sender) }
    }
    override func pasteAsRichText(_ sender: Any?) {
        performEdit(.isolated) { super.pasteAsRichText(sender) }
    }
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        performEdit(.isolated) { super.readSelection(from: pboard) }
    }
    override func cut(_ sender: Any?) {
        performEdit(.isolated) { super.cut(sender) }
    }
    override func insertNewline(_ sender: Any?) {
        performEdit(.isolated) { super.insertNewline(sender) }
    }
    override func insertTab(_ sender: Any?) {
        performEdit(.isolated) { super.insertTab(sender) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        ("A little room for anything." as NSString).draw(at: NSPoint(x: x, y: 65), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: PocketPalette.secondary,
        ])
        ("⌘V  Paste     ⌘O  Open a file" as NSString).draw(at: NSPoint(x: x, y: 89), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: PocketPalette.secondary,
        ])
    }
}

private final class PocketButton: NSButton {
    private var hovered = false
    override var mouseDownCanMoveWindow: Bool { false }

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        contentTintColor = PocketPalette.secondary
        setAccessibilityLabel(label)
        toolTip = label
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            (isHighlighted ? PocketPalette.selection : PocketPalette.hover).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

struct PocketTab: Equatable {
    let title: String
    let modifiedFile: Bool
    var isPrivate = false
}

private final class PocketTabView: NSView {
    let select = NSButton(title: "", target: nil, action: nil)
    let close = PocketButton(symbol: "xmark", label: "Close tab")
    let indexLabel = NSTextField(labelWithString: "")
    var isActive = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        select.isBordered = false
        select.setButtonType(.momentaryChange)
        select.alignment = .left
        select.font = .systemFont(ofSize: 12, weight: .medium)
        select.cell?.lineBreakMode = .byTruncatingTail
        select.target = self
        select.action = #selector(selectTab)
        close.target = self
        close.action = #selector(closeTab)
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        indexLabel.setAccessibilityElement(false)
        addSubview(select)
        addSubview(close)
        addSubview(indexLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ tab: PocketTab, index: Int, active: Bool) {
        isActive = active
        indexLabel.stringValue = String(format: "%02d", index + 1)
        indexLabel.textColor = active ? PocketPalette.accent : PocketPalette.secondary
        select.title = tab.title + (tab.modifiedFile ? " •" : "")
        select.image = tab.isPrivate ? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Private") : nil
        select.imagePosition = tab.isPrivate ? .imageLeading : .noImage
        select.contentTintColor = active ? PocketPalette.ink : PocketPalette.secondary
        select.setAccessibilityLabel(tab.title)
        select.setAccessibilityValue(active ? "Selected" : "")
        select.setAccessibilityHelp(tab.isPrivate ? "Private tab. Excluded from session recovery." : tab.modifiedFile ? "Modified file. Save with Command-S." : "Switch to this text.")
        select.toolTip = tab.title + (tab.isPrivate ? " — Not recovered after quitting" : tab.modifiedFile ? " — Modified file" : "")
        close.setAccessibilityLabel("Close \(tab.title)")
        close.toolTip = "Close \(tab.title) · ⌘W when active"
        needsLayout = true
    }
    override func layout() {
        super.layout()
        indexLabel.frame = NSRect(x: 10, y: 10, width: 20, height: 14)
        close.frame = NSRect(x: bounds.width - 28, y: 4, width: 25, height: 26)
        select.frame = NSRect(x: 34, y: 2, width: max(0, bounds.width - 63), height: 30)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === indexLabel ? select : hit
    }
    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            PocketPalette.active.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                PocketPalette.secondary.setStroke()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
            }
        }
    }
    @objc private func selectTab() { onSelect?() }
    @objc private func closeTab() { onClose?() }
}

final class PocketHeader: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    private var models: [PocketTab] = []
    private var active = 0
    private var tabViews: [PocketTabView] = []
    private let newButton = PocketButton(symbol: "plus", label: "New scratch · ⌘N")
    private let overflow = PocketButton(symbol: "chevron.down", label: "All tabs")
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel("vibechar scratch buffers")
        newButton.target = self
        newButton.action = #selector(newScratch)
        overflow.target = self
        overflow.action = #selector(showAllTabs)
        addSubview(newButton)
        addSubview(overflow)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(tabs: [PocketTab], active: Int) {
        guard models != tabs || self.active != active else { return }
        models = tabs
        self.active = active
        while tabViews.count < tabs.count {
            let view = PocketTabView()
            tabViews.append(view)
            addSubview(view)
        }
        while tabViews.count > tabs.count { tabViews.removeLast().removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            tabViews[index].update(tab, index: index, active: index == active)
            tabViews[index].onSelect = { [weak self] in self?.onSelect?(index) }
            tabViews[index].onClose = { [weak self] in self?.onClose?(index) }
        }
        needsLayout = true
    }

    // Keep a contiguous neighborhood around the active tab, including on resize.
    static func visibleRange(count: Int, active: Int, capacity: Int) -> Range<Int> {
        let visible = min(count, max(1, capacity))
        let start = max(0, min(active - visible / 2, count - visible))
        return start..<(start + visible)
    }

    override func layout() {
        super.layout()
        let rtl = window?.windowTitlebarLayoutDirection == .rightToLeft
        let lightsInset: CGFloat = 98
        let leading: CGFloat = rtl ? 16 : lightsInset
        let trailing: CGFloat = rtl ? lightsInset : 16
        let available = max(0, bounds.width - leading - trailing - 45 - 36)
        let allFit = CGFloat(models.count) * 126 <= available
        let tabsWidth = available - (allFit ? 0 : 34)
        let capacity = max(1, Int(tabsWidth / 126))
        let visible = Self.visibleRange(count: models.count, active: active, capacity: capacity)
        let width = min(184, max(90, tabsWidth / CGFloat(max(1, visible.count))))
        var x = leading
        for (index, view) in tabViews.enumerated() {
            view.isHidden = !visible.contains(index)
            if !view.isHidden {
                view.frame = NSRect(x: x, y: 10, width: width - 4, height: 34)
                x += width
            }
        }
        overflow.isHidden = allFit
        overflow.frame = NSRect(x: x, y: 10, width: 30, height: 34)
        if !allFit { x += 34 }
        newButton.frame = NSRect(x: x, y: 10, width: 32, height: 34)
        needsDisplay = true
        layoutTrafficLights()
    }

    private func layoutTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let container = close.superview, let parent = container.superview else { return }
        let rtl = window.windowTitlebarLayoutDirection == .rightToLeft
        let desired = parent.convert(NSPoint(x: rtl ? bounds.width - 22 : 22, y: 27), from: self)
        let current = parent.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), from: close)
        container.setFrameOrigin(NSPoint(x: container.frame.minX + desired.x - current.x,
                                         y: container.frame.minY + desired.y - current.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        PocketPalette.chrome.setFill()
        dirtyRect.fill()
        let trailing: CGFloat = window?.windowTitlebarLayoutDirection == .rightToLeft ? 98 : 16
        let mark = NSMutableAttributedString(string: "V_", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .medium),
            .foregroundColor: PocketPalette.ink,
        ])
        mark.addAttribute(.foregroundColor, value: PocketPalette.accent, range: NSRange(location: 1, length: 1))
        mark.draw(at: NSPoint(x: bounds.width - trailing - 27, y: 15))
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            if action == "Minimize" { window?.miniaturize(nil) }
            else if action != "None" { window?.zoom(nil) }
        } else { window?.performDrag(with: event) }
    }
    @objc private func newScratch() { onNew?() }
    @objc private func showAllTabs() {
        let menu = NSMenu(title: "All tabs")
        for (index, tab) in models.enumerated() {
            let item = NSMenuItem(title: "\(index + 1)   \(tab.title)\(tab.isPrivate ? " — Private" : "")\(tab.modifiedFile ? " •" : "")", action: #selector(selectFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == active ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: overflow.frame.minX, y: bounds.maxY - 4), in: self)
    }
    @objc private func selectFromMenu(_ sender: NSMenuItem) { onSelect?(sender.tag) }
}

final class PocketFooter: NSView {
    let status = NSTextField(labelWithString: "Saved locally")
    let detail = NSTextField(labelWithString: "15 pt  ·  UTF-8")
    let languageButton = NSButton(title: "Auto · Text", target: nil, action: nil)
    var onLanguage: (() -> Void)?
    private var syntaxName = "Text"
    private var syntaxAuto = true
    private let give = NSButton(title: "Give to Agent", target: nil, action: nil)
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    var onGive: (() -> Void)?
    var onStop: (() -> Void)?
    var operationError: String? { didSet { renderStatus() } }
    var agentUses: UInt64? { didSet { renderStatus(); needsLayout = true } }
    private(set) var failed = false
    private var recoveryMessage = "Saved locally"
    var privateTab = false { didSet { renderStatus() } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [status, detail] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = PocketPalette.secondary
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        status.setAccessibilityLabel("Session recovery")
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.alignment = .right
        for button in [give, stop, languageButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = PocketPalette.accent
            button.target = self
            addSubview(button)
        }
        give.action = #selector(giveToAgent)
        give.toolTip = "Copy instructions and open temporary access to this private text · ⇧⌘C"
        give.setAccessibilityLabel("Copy for Agent")
        stop.action = #selector(stopAgent)
        stop.setAccessibilityLabel("Close this tab's agent access")
        languageButton.action = #selector(chooseLanguage)
        languageButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        languageButton.imagePosition = .imageTrailing
        languageButton.cell?.lineBreakMode = .byTruncatingTail
        showSyntax("Text", automatic: true, reason: "Detects file names and pasted text locally", limited: false)
        renderStatus()
        status.toolTip = "Ordinary tabs are saved locally, separately from your files. Private tabs are excluded. ⌘S saves a file."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func showSyntax(_ name: String, automatic: Bool, reason: String, limited: Bool) {
        syntaxName = name; syntaxAuto = automatic
        languageButton.toolTip = "\(automatic ? "Automatic" : "Pinned") · \(reason)\(limited ? " · Color preview limited for this text" : "") · Click to search languages"
        languageButton.setAccessibilityLabel("Language: \(automatic ? "Auto · " : "")\(name)")
        languageButton.image = NSImage(systemSymbolName: automatic ? "chevron.down" : "pin.fill", accessibilityDescription: nil)
        needsLayout = true
    }
    func showStatus(_ message: String, failed: Bool = false) {
        recoveryMessage = message
        self.failed = failed
        renderStatus()
    }
    private func renderStatus() {
        let mode = agentUses.map { "Private · Agent access open · \($0) uses" } ?? "Private · not recovered"
        status.stringValue = privateTab ? (failed ? "\(mode) · \(recoveryMessage)" : mode) : recoveryMessage
        give.isHidden = !privateTab
        stop.isHidden = !privateTab || agentUses == nil
        give.title = agentUses == nil ? "Give to Agent" : "Copy Again"
        needsLayout = true
        if let operationError { status.stringValue = privateTab ? "\(mode) · \(operationError)" : operationError }
        status.textColor = failed || operationError != nil ? PocketPalette.accent : PocketPalette.secondary
        status.toolTip = privateTab
            ? "This tab is excluded from recovery. Saving a file ends private mode and closes its agent access.\(agentUses == nil ? "" : " Agent access is open; Stop closes future requests. Edits revoke access; 30 minutes without use expires it.")\(failed ? " Other tabs: " + recoveryMessage : "")"
            : failed ? recoveryMessage : "Ordinary tabs are saved locally, separately from your files. Private tabs are excluded. ⌘S saves a file."
        if let operationError { status.toolTip = "\(status.toolTip ?? "") \(operationError)" }
    }
    override func layout() {
        super.layout()
        let compact = privateTab && bounds.width < 650
        let languageWidth: CGFloat = compact ? 92 : 142
        let details: CGFloat = bounds.width >= 800 ? 94 : 0
        let actions: CGFloat = privateTab ? (agentUses == nil ? 104 : 144) : 0
        languageButton.title = syntaxAuto && !compact ? "Auto · \(syntaxName)" : syntaxName
        languageButton.frame = NSRect(x: bounds.width - 16 - languageWidth, y: 4, width: languageWidth, height: 24)
        detail.isHidden = details == 0
        detail.frame = NSRect(x: languageButton.frame.minX - details - 8, y: 8, width: max(0, details - 8), height: 16)
        let actionX = languageButton.frame.minX - details - (actions == 0 ? 0 : 8) - actions
        give.frame = NSRect(x: actionX, y: 4, width: 104, height: 24)
        stop.frame = NSRect(x: actionX + 104, y: 4, width: 40, height: 24)
        status.frame = NSRect(x: 26, y: 8, width: max(0, actionX - 38), height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? PocketPalette.secondary : PocketPalette.rule).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }
    @objc private func giveToAgent() { onGive?() }
    @objc private func stopAgent() { onStop?() }
    @objc private func chooseLanguage() { onLanguage?() }
}

@MainActor
func pocketInterfaceSmokeTest() {
    _ = NSApplication.shared
    let header = PocketHeader()
    for width in [420, 560, 880, 1600] {
        header.frame = NSRect(x: 0, y: 0, width: width, height: 54)
        for count in [1, 3, 14] {
            for active in 0..<count {
                let models = (0..<count).map { PocketTab(title: "Русский 👩‍💻 \($0) with a very long name", modifiedFile: $0 == 0) }
                header.update(tabs: models, active: active)
                header.layoutSubtreeIfNeeded()
                let tabs = header.subviews.compactMap { $0 as? PocketTabView }
                precondition(!tabs[active].isHidden, "Active tab must remain visible")
                let visible = tabs.filter { !$0.isHidden }
                for tab in visible {
                    precondition(tab.frame.minX >= 98 && tab.frame.maxX <= header.bounds.maxX - 75)
                    precondition(tab.select.frame.width > 0)
                }
                for pair in zip(visible, visible.dropFirst()) {
                    precondition(!pair.0.frame.intersects(pair.1.frame), "Tabs must not overlap")
                }
                var closed: Int?
                header.onClose = { closed = $0 }
                tabs[active].close.performClick(nil)
                precondition(closed == active, "Each close button must target its own buffer")
            }
        }
    }
    print("Pocket chrome smoke test passed: narrow/wide windows, active overflow, close targets")
}

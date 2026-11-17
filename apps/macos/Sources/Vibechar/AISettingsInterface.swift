import AppKit

private final class AIModelRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.clip()
        PocketPalette.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
}

private final class AIModelCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let availability = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13, weight: .semibold); name.textColor = PocketPalette.ink
        detail.font = .systemFont(ofSize: 10); detail.textColor = PocketPalette.secondary
        availability.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        availability.textColor = PocketPalette.secondary; availability.alignment = .right
        [name, detail, availability].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        name.frame = NSRect(x: 12, y: 25, width: bounds.width - 120, height: 18)
        detail.frame = NSRect(x: 12, y: 7, width: bounds.width - 24, height: 15)
        availability.frame = NSRect(x: bounds.width - 108, y: 27, width: 94, height: 14)
    }
}

@MainActor
final class AISettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let model: AISettingsModel
    let keyField = NSSecureTextField()
    let savedKeyField = NSTextField()
    let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    let searchField = NSSearchField()
    let table = NSTableView()
    let testButton = NSButton(title: "Test & Save", target: nil, action: nil)
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let keyHint = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No matching models")
    private let spinner = NSProgressIndicator()
    private var visibleModels = AIModel.catalog
    private var rendering = false
    private var replacingKey = false

    init(model: AISettingsModel? = nil) {
        self.model = model ?? AISettingsModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "AI Settings"; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.isRestorable = false
        let root = PocketSurface(frame: NSRect(x: 0, y: 0, width: 560, height: 680))
        window.contentView = root
        super.init(window: window)
        window.delegate = self
        window.center()

        func label(_ text: String, _ frame: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = PocketPalette.ink, mono: Bool = false) {
            let field = NSTextField(labelWithString: text)
            field.frame = frame; field.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
            field.textColor = color; root.addSubview(field)
        }
        label("V_", NSRect(x: 492, y: 22, width: 40, height: 24), size: 18, weight: .bold, color: PocketPalette.accent, mono: true)
        label("A little intelligence.", NSRect(x: 28, y: 60, width: 504, height: 38), size: 28, weight: .semibold)
        label("Your key. Your model. Ready when you are.", NSRect(x: 29, y: 103, width: 500, height: 22), size: 13, color: PocketPalette.secondary)
        label("OPENAI API KEY", NSRect(x: 28, y: 147, width: 300, height: 18), size: 10, weight: .semibold, color: PocketPalette.secondary, mono: true)
        keyField.frame = NSRect(x: 28, y: 172, width: 418, height: 30)
        keyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        keyField.bezelStyle = .roundedBezel
        keyField.placeholderString = "Paste your API key"
        keyField.delegate = self; keyField.setAccessibilityLabel("OpenAI API key")
        root.addSubview(keyField)
        savedKeyField.frame = NSRect(x: 28, y: 172, width: 316, height: 30)
        savedKeyField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        savedKeyField.textColor = PocketPalette.ink; savedKeyField.backgroundColor = PocketPalette.chrome
        savedKeyField.isEditable = false; savedKeyField.isSelectable = false
        savedKeyField.bezelStyle = .roundedBezel
        savedKeyField.setAccessibilityLabel("Saved OpenAI API key")
        root.addSubview(savedKeyField)
        replaceButton.frame = NSRect(x: 352, y: 173, width: 94, height: 28)
        replaceButton.bezelStyle = .rounded; replaceButton.target = self; replaceButton.action = #selector(replaceKey)
        root.addSubview(replaceButton)
        removeButton.frame = NSRect(x: 454, y: 173, width: 82, height: 28)
        removeButton.bezelStyle = .rounded; removeButton.target = self; removeButton.action = #selector(remove)
        root.addSubview(removeButton)
        keyHint.frame = NSRect(x: 29, y: 210, width: 500, height: 18)
        keyHint.font = .systemFont(ofSize: 11); keyHint.textColor = PocketPalette.secondary; root.addSubview(keyHint)

        label("MODEL", NSRect(x: 28, y: 257, width: 200, height: 18), size: 10, weight: .semibold, color: PocketPalette.secondary, mono: true)
        refreshButton.frame = NSRect(x: 446, y: 249, width: 90, height: 28)
        refreshButton.bezelStyle = .rounded; refreshButton.target = self; refreshButton.action = #selector(refresh)
        root.addSubview(refreshButton)
        searchField.frame = NSRect(x: 28, y: 286, width: 504, height: 28)
        searchField.placeholderString = "Find a model"
        searchField.delegate = self; searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Find a supported text model"); root.addSubview(searchField)

        let scroll = NSScrollView(frame: NSRect(x: 26, y: 324, width: 508, height: 200))
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("model")); column.width = 506
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 48
        table.intercellSpacing = NSSize(width: 0, height: 2); table.backgroundColor = .clear
        table.focusRingType = .none; table.selectionHighlightStyle = .regular
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Supported OpenAI models")
        scroll.documentView = table; root.addSubview(scroll)
        emptyLabel.frame = NSRect(x: 38, y: 342, width: 470, height: 22)
        emptyLabel.font = .systemFont(ofSize: 13); emptyLabel.textColor = PocketPalette.secondary
        root.addSubview(emptyLabel)

        spinner.frame = NSRect(x: 29, y: 540, width: 14, height: 14)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        root.addSubview(spinner)
        statusLabel.frame = NSRect(x: 53, y: 537, width: 477, height: 44)
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.maximumNumberOfLines = 3
        statusLabel.setAccessibilityLabel("Connection status"); root.addSubview(statusLabel)
        label("Checks send a tiny fixed prompt, never your tabs.", NSRect(x: 29, y: 588, width: 500, height: 17), size: 11, color: PocketPalette.secondary)
        label("Model tests use your OpenAI API billing.", NSRect(x: 29, y: 605, width: 500, height: 17), size: 11, color: PocketPalette.secondary)
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.frame = NSRect(x: 22, y: 635, width: 78, height: 30); done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"; root.addSubview(done)
        cancelButton.frame = NSRect(x: 312, y: 635, width: 84, height: 30)
        cancelButton.bezelStyle = .rounded; cancelButton.target = self; cancelButton.action = #selector(cancelRequest)
        root.addSubview(cancelButton)
        testButton.frame = NSRect(x: 402, y: 635, width: 136, height: 30)
        testButton.bezelStyle = .rounded; testButton.target = self; testButton.action = #selector(testConnection)
        testButton.contentTintColor = PocketPalette.accent
        // Plain Return while searching must never send a billed request.
        testButton.keyEquivalent = "\r"; testButton.keyEquivalentModifierMask = [.command]
        root.addSubview(testButton)
        window.initialFirstResponder = keyField
        keyField.nextKeyView = searchField; replaceButton.nextKeyView = searchField; searchField.nextKeyView = table
        table.nextKeyView = refreshButton; refreshButton.nextKeyView = testButton
        self.model.onChange = { [weak self] in self?.render() }
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        model.open()
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        clearKeyEntry(); model.close()
    }
    func shutdown() { clearKeyEntry(); model.close(); close() }
    private func clearKeyEntry() {
        if let editor = window?.fieldEditor(false, for: keyField) {
            editor.string = ""; editor.undoManager?.removeAllActions()
        }
        keyField.stringValue = ""
        window?.makeFirstResponder(nil)
    }
    @objc private func done() { close() }
    @objc private func testConnection() { model.testAndSave() }
    @objc private func refresh() { model.refresh() }
    @objc private func remove() { model.removeKey() }
    @objc private func cancelRequest() { model.cancel() }
    @objc private func replaceKey() {
        guard model.hasSavedKey, model.editable else { return }
        clearKeyEntry()
        replacingKey.toggle()
        model.editKey("")
        window?.makeFirstResponder(replacingKey ? keyField : replaceButton)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !rendering else { return }
        if notification.object as? NSTextField === keyField { model.editKey(keyField.stringValue) }
        else if notification.object as? NSTextField === searchField { render() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === searchField, commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if !visibleModels.isEmpty {
                if table.selectedRow < 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                model.select(visibleModels[max(0, table.selectedRow)])
                window?.makeFirstResponder(table)
            }
            return true
        }
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleModels.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AIModelRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = AIModelCell(frame: .zero), entry = visibleModels[row]
        cell.name.stringValue = entry.title
        cell.detail.stringValue = "\(entry.id) · \(entry.detail)"
        cell.availability.stringValue = model.availableModels.map { $0.contains(entry.id) ? "AVAILABLE" : "NOT LISTED" } ?? ""
        cell.setAccessibilityLabel("\(entry.title), \(entry.id), \(entry.detail), \(cell.availability.stringValue)")
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rendering, visibleModels.indices.contains(table.selectedRow) else { return }
        model.select(visibleModels[table.selectedRow])
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { model.editable }

    private func render() {
        rendering = true; defer { rendering = false }
        if !model.hasSavedKey || (model.tone == .success && model.draftKey.isEmpty) { replacingKey = false }
        else if !model.draftKey.isEmpty { replacingKey = true }
        let showSavedKey = model.hasSavedKey && !replacingKey
        if showSavedKey, keyField.currentEditor() != nil { clearKeyEntry() }
        if keyField.stringValue != model.draftKey {
            keyField.stringValue = model.draftKey
            if model.draftKey.isEmpty { keyField.currentEditor()?.undoManager?.removeAllActions() }
        }
        keyField.isEnabled = model.editable; searchField.isEnabled = model.editable
        keyField.isHidden = showSavedKey
        keyField.frame.size.width = model.hasSavedKey ? 316 : 418
        keyField.placeholderString = model.hasSavedKey ? "Paste a new API key" : "Paste your API key"
        savedKeyField.stringValue = model.savedKeyPreview ?? ""
        savedKeyField.isHidden = !showSavedKey
        replaceButton.isHidden = !model.hasSavedKey
        replaceButton.isEnabled = model.editable
        replaceButton.title = replacingKey ? "Cancel" : "Replace"
        replaceButton.toolTip = replacingKey ? "Discard the replacement and keep your saved key" : "Replace the saved key after a successful test"
        window?.initialFirstResponder = showSavedKey ? replaceButton : keyField
        keyField.nextKeyView = model.hasSavedKey ? replaceButton : searchField
        keyHint.stringValue = replacingKey ? "Your saved key stays until the new key passes its test" : model.hasSavedKey ? "Stored in Keychain · never included in your saved tabs" : "Stored only after a successful model test"
        removeButton.isEnabled = model.hasSavedKey && model.editable
        let hasCandidate = model.canConnect && (!replacingKey || !model.draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        refreshButton.isEnabled = hasCandidate && !model.requesting
        testButton.isEnabled = hasCandidate && !model.requesting
        cancelButton.isHidden = !model.requesting
        statusLabel.stringValue = model.status
        statusLabel.textColor = model.tone == .error ? PocketPalette.accent : model.tone == .success ? PocketPalette.ink : PocketPalette.secondary
        if model.phase != .idle { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleModels = AIModel.catalog.filter { query.isEmpty || "\($0.title) \($0.id) \($0.detail)".localizedCaseInsensitiveContains(query) }
        emptyLabel.isHidden = !visibleModels.isEmpty
        table.reloadData()
        if let index = visibleModels.firstIndex(of: model.selectedModel) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
    }
}

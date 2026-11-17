import AppKit

@MainActor
final class RecipeWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let store: RecipeStore
    let search = NSSearchField()
    let table = NSTableView()
    let runButton = NSButton(title: "Preview on Selection",target: nil,action: nil)
    let renameButton = NSButton(title: "Rename…",target: nil,action: nil)
    let deleteButton = NSButton(title: "Delete…",target: nil,action: nil)
    private let brand = NSTextField(labelWithString: "V_")
    private let heading = NSTextField(labelWithString: "Your recipes.")
    private let subtitle = NSTextField(labelWithString: "Show once. Keep the rule. Run it locally.")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private var recipes: [SavedRecipe] = []
    private(set) var visible: [SavedRecipe] = []
    var onRun: ((SavedRecipe) throws -> Void)?
    var onClose: (() -> Void)?
    var selected: SavedRecipe? { visible.indices.contains(table.selectedRow) ? visible[table.selectedRow] : nil }

    init(store: RecipeStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 660,height: 580),
                              styleMask: [.titled,.closable,.resizable,.fullSizeContentView],backing: .buffered,defer: false)
        window.title = "Saved Recipes"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.minSize = NSSize(width: 560,height: 460)
        let root = RewriteSurface(frame: NSRect(x: 0,y: 0,width: 660,height: 580)); window.contentView = root
        super.init(window: window); window.delegate = self; window.center()
        heading.font = .systemFont(ofSize: 27,weight: .semibold); heading.textColor = PocketPalette.ink
        brand.font = .monospacedSystemFont(ofSize: 18,weight: .bold); brand.textColor = PocketPalette.accent
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = PocketPalette.secondary
        detail.font = .monospacedSystemFont(ofSize: 11,weight: .regular); detail.textColor = PocketPalette.secondary
        detail.maximumNumberOfLines = 2; detail.lineBreakMode = .byTruncatingTail
        empty.font = .systemFont(ofSize: 13); empty.textColor = PocketPalette.secondary; empty.alignment = .center
        status.font = .systemFont(ofSize: 11); status.textColor = PocketPalette.secondary; status.maximumNumberOfLines = 2
        search.placeholderString = "Find a recipe"; search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search saved recipes")
        table.addTableColumn(NSTableColumn(identifier: .init("recipe"))); table.headerView = nil
        table.rowHeight = 52; table.intercellSpacing = NSSize(width: 0,height: 4)
        table.style = .fullWidth; table.backgroundColor = PocketPalette.canvas
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(run)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Saved recipes")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .lineBorder
        for button in [runButton,renameButton,deleteButton] { button.bezelStyle = .rounded; button.target = self }
        runButton.action = #selector(run); runButton.keyEquivalent = "\r"; runButton.keyEquivalentModifierMask = [.command]
        runButton.contentTintColor = PocketPalette.accent
        renameButton.action = #selector(rename); deleteButton.action = #selector(remove)
        [brand,heading,subtitle,search,scroll,empty,detail,status,runButton,renameButton,deleteButton].forEach { root.addSubview($0) }
        root.onLayout = { [weak self] in self?.layout() }
        window.initialFirstResponder = search; layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { reload(); showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(search) }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func reload(select id: UUID? = nil) {
        do {
            recipes = try store.load(); status.stringValue = "On device · no AI request · preview before applying · one Undo"
            status.textColor = PocketPalette.secondary; filter(select: id)
        } catch {
            recipes = []; filter(); empty.stringValue = "Your recipe library is unavailable."
            show(error)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let recipe = visible[row], cell = NSTableCellView()
        let name = NSTextField(labelWithString: recipe.name), summary = NSTextField(labelWithString: recipe.info.summary ?? "Local recipe")
        name.font = .systemFont(ofSize: 14,weight: .semibold); name.textColor = PocketPalette.ink
        summary.font = .systemFont(ofSize: 11); summary.textColor = PocketPalette.secondary
        for label in [name,summary] { label.lineBreakMode = .byTruncatingTail; label.autoresizingMask = [.width]; cell.addSubview(label) }
        name.frame = NSRect(x: 12,y: 26,width: max(100,tableView.bounds.width-32),height: 19)
        summary.frame = NSRect(x: 12,y: 7,width: max(100,tableView.bounds.width-32),height: 16)
        cell.textField = name; cell.setAccessibilityLabel(recipe.name); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func controlTextDidChange(_ obj: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !visible.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(visible.count-1,max(0,table.selectedRow+step))
            table.selectRowIndexes(IndexSet(integer: row),byExtendingSelection: false); table.scrollRowToVisible(row); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) { run(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
    private func filter(select id: UUID? = nil) {
        let previous = id ?? selected?.id, query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = recipes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.info.summary ?? "").localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if !visible.isEmpty { table.selectRowIndexes(IndexSet(integer: visible.firstIndex { $0.id == previous } ?? 0),byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        empty.isHidden = !visible.isEmpty
        empty.stringValue = recipes.isEmpty ? "No recipes yet.\nSave a validated rule from Do the Rest to keep it here." : "No recipes match this search."
        updateSelection()
    }
    private func updateSelection() {
        let recipe = selected
        runButton.isEnabled = recipe != nil; renameButton.isEnabled = recipe != nil; deleteButton.isEnabled = recipe != nil
        detail.stringValue = recipe?.info.summary ?? "Select complete lines in your editor, then preview a saved recipe here."
        detail.toolTip = recipe?.info.explanation
    }
    @objc private func run() {
        guard let recipe = selected else { return }
        do { try onRun?(recipe) } catch { show(error) }
    }
    @objc private func rename() {
        guard let recipe = selected, let window else { return }
        let alert = NSAlert(); alert.messageText = "Rename recipe"
        let name = NSTextField(frame: NSRect(x: 0,y: 0,width: 320,height: 24)); name.stringValue = recipe.name
        alert.accessoryView = name; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.rename(recipe.id,to: name.stringValue); self.reload(select: recipe.id) }
            catch { self.show(error) }
        }
    }
    @objc private func remove() {
        guard let recipe = selected, let window else { return }
        let alert = NSAlert(); alert.messageText = "Delete “\(recipe.name)”?"; alert.informativeText = "This removes the saved rule. Your text stays unchanged."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.delete(recipe.id); self.reload() } catch { self.show(error) }
        }
    }
    private func show(_ error: Error) { status.stringValue = (error as? RewriteFailure)?.message ?? "Couldn't access the recipe library."; status.textColor = PocketPalette.accent }
    private func layout() {
        guard let root = window?.contentView else { return }
        let w = root.bounds.width, h = root.bounds.height
        brand.frame = NSRect(x: w-62,y: 20,width: 40,height: 24)
        heading.frame = NSRect(x: 24,y: 53,width: w-48,height: 36)
        subtitle.frame = NSRect(x: 25,y: 99,width: w-50,height: 20)
        search.frame = NSRect(x: 24,y: 134,width: w-48,height: 28)
        scroll.frame = NSRect(x: 24,y: 177,width: w-48,height: h-337)
        empty.frame = NSRect(x: 48,y: 192+(h-337)/2-25,width: w-96,height: 58)
        detail.frame = NSRect(x: 25,y: h-148,width: w-50,height: 38)
        status.frame = NSRect(x: 25,y: h-96,width: w-50,height: 36)
        renameButton.frame = NSRect(x: 18,y: h-44,width: 92,height: 28)
        deleteButton.frame = NSRect(x: 112,y: h-44,width: 88,height: 28)
        runButton.frame = NSRect(x: w-208,y: h-44,width: 190,height: 28)
    }
}

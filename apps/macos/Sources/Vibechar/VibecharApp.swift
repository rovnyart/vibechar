import AppKit

@main
struct VibecharApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            let document = RustDocument("я🦀\0")
            precondition(!document.replace(NSRange(location: 2, length: 1), with: "x"))
            precondition(document.replace(NSRange(location: 1, length: 2), with: "👩‍💻"))
            precondition(document.text == "я👩‍💻\0")
            precondition(document.history(redo: false) == 3)
            precondition(document.text == "я🦀\0")
            precondition(!document.isDirty)
            precondition(document.history(redo: true) == 6)
            document.markSaved()
            precondition(!document.isDirty)

            let session = RustSession()
            let activeDocument = RustDocument(session: session)
            precondition(activeDocument.replace(NSRange(location: 0, length: 0), with: "я🦀"))
            session.rememberSelection(NSRange(location: 1, length: 2))
            session.open("second", url: URL(fileURLWithPath: "/tmp/vibechar-smoke.txt"))
            precondition(activeDocument.text == "second" && !activeDocument.isDirty)
            precondition(session.hasUnsaved)
            session.select(0)
            precondition(activeDocument.text == "я🦀")
            precondition(session.selection == NSRange(location: 1, length: 2))
            precondition(!session.close(discard: false))
            precondition(activeDocument.history(redo: false) == 0)
            precondition(session.close(discard: false))
            precondition(activeDocument.text == "second")
            precondition(session.fileURL?.lastPathComponent == "vibechar-smoke.txt")
            recoverySmokeTest()
            print("Swift ↔ Rust smoke test passed")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor
    private static func recoverySmokeTest() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-recovery-\(UUID().uuidString)")
        defer { try! FileManager.default.removeItem(at: directory) }
        do {
            var store: SessionRecovery? = try SessionRecovery(directory: directory)
            let original = RustSession()
            let text = RustDocument(session: original)
            precondition(text.replace(NSRange(location: 0, length: 0), with: "Привет 👩‍💻\r\n"))
            original.rememberSelection(NSRange(location: 7, length: 5))
            original.open("second", url: URL(fileURLWithPath: "/tmp/recovery-original.txt"))
            precondition(store!.flush(original.checkpoint()))
            var locked = false
            do { _ = try SessionRecovery(directory: directory) }
            catch RecoveryError.alreadyOpen { locked = true }
            precondition(locked)
            let file = store!.fileURL
            store = nil
            let reopened = try SessionRecovery(directory: directory)
            let restored = RustSession()
            let didRestore = try restored.restore(from: reopened.fileURL)
            precondition(didRestore)
            precondition(restored.count == 2 && restored.active == 1)
            precondition(RustDocument(session: restored).text == "second")
            restored.select(0)
            precondition(RustDocument(session: restored).text == "Привет 👩‍💻\r\n")
            precondition(restored.selection == NSRange(location: 7, length: 5))
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        } catch { preconditionFailure("Recovery smoke test failed: \(error)") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private let session: RustSession
    private let document: RustDocument
    private var fileURL: URL? { session.fileURL }
    private var window: NSWindow!
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "Saved locally")
    private let tabs = NSSegmentedControl()
    private let tabScroll = NSScrollView()
    private var closingWindow = false
    private var recovery: SessionRecovery?
    private var pendingSave: DispatchWorkItem?
    private var saveGeneration: UInt64 = 0

    override init() {
        let session = RustSession()
        self.session = session
        document = RustDocument(session: session)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var recoveryError: Error?
        do {
            let store = try SessionRecovery()
            _ = try session.restore(from: store.fileURL)
            recovery = store
        } catch { recoveryError = error }
        makeMenus()
        makeWindow()
        showActiveBuffer()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        if let recoveryError {
            status.stringValue = "Recovery unavailable · Save important text with ⌘S"
            NSApp.presentError(recoveryError)
        }
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.delegate = self
        window.minSize = NSSize(width: 400, height: 260)
        window.center()
        let content = NSView()
        window.contentView = content

        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .systemOrange
        textView.textContainerInset = NSSize(width: 22, height: 22)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 880, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self
        textView.setAccessibilityLabel("Text editor")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        tabs.trackingMode = .selectOne
        tabs.segmentStyle = .rounded
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.setAccessibilityLabel("Scratch buffers")
        tabScroll.documentView = tabs
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.drawsBackground = false
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabScroll)
        content.addSubview(scroll)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            tabScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tabScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabScroll.heightAnchor.constraint(equalToConstant: 36),
            scroll.topAnchor.constraint(equalTo: tabScroll.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            status.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        refreshTitle()
    }

    private func makeMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About vibechar", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit vibechar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu("vibechar", submenu: appMenu, to: menu)
        let file = NSMenu(title: "File")
        addItem("New Scratch", action: #selector(newScratch), key: "n", to: file)
        addItem("Open…", action: #selector(openFile), key: "o", to: file)
        addItem("Save", action: #selector(saveFile), key: "s", to: file)
        addItem("Close Scratch", action: #selector(closeScratch), key: "w", to: file)
        addMenu("File", submenu: file, to: menu)
        let buffers = NSMenu(title: "Buffers")
        let previous = NSMenuItem(title: "Previous Buffer", action: #selector(previousBuffer), keyEquivalent: "\u{f702}")
        previous.keyEquivalentModifierMask = [.command, .option]
        previous.target = self
        buffers.addItem(previous)
        let next = NSMenuItem(title: "Next Buffer", action: #selector(nextBuffer), keyEquivalent: "\u{f703}")
        next.keyEquivalentModifierMask = [.command, .option]
        next.target = self
        buffers.addItem(next)
        addMenu("Buffers", submenu: buffers, to: menu)
        let edit = NSMenu(title: "Edit")
        addItem("Undo", action: #selector(undoEdit), key: "z", to: edit)
        let redo = NSMenuItem(title: "Redo", action: #selector(redoEdit), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = self
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addMenu("Edit", submenu: edit, to: menu)
        NSApp.mainMenu = menu
    }

    private func addMenu(_ title: String, submenu: NSMenu, to parent: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        parent.addItem(item)
    }

    private func addItem(_ title: String, action: Selector, key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let accepted = document.replace(affectedCharRange, with: replacementString)
        if !accepted { NSSound.beep() }
        return accepted
    }

    func textDidChange(_ notification: Notification) {
        refreshTitle()
        scheduleSessionSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) { scheduleSessionSave() }

    private func refreshTitle() {
        window.title = "\(session.label(session.active)) — vibechar"
        window.isDocumentEdited = document.isDirty
        tabs.segmentCount = session.count
        for index in 0..<session.count {
            tabs.setLabel(session.label(index), forSegment: index)
            tabs.setWidth(min(180, max(100, CGFloat(session.label(index).count) * 8 + 24)), forSegment: index)
        }
        tabs.selectedSegment = session.active
        tabs.sizeToFit()
    }

    @objc private func undoEdit() { applyHistory(redo: false) }
    @objc private func redoEdit() { applyHistory(redo: true) }

    private func applyHistory(redo: Bool) {
        guard let cursor = document.history(redo: redo) else { return }
        textView.string = document.text
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        refreshTitle()
        scheduleSessionSave()
    }

    @objc private func newScratch() {
        session.rememberSelection(textView.selectedRange())
        session.open()
        showActiveBuffer()
    }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            session.rememberSelection(textView.selectedRange())
            session.open(text, url: url)
            showActiveBuffer()
        }
        catch { NSApp.presentError(error) }
    }

    private func showActiveBuffer() {
        textView.string = document.text
        textView.setSelectedRange(session.selection)
        textView.scrollRangeToVisible(textView.selectedRange())
        window.makeFirstResponder(textView)
        refreshTitle()
        scheduleSessionSave()
    }

    @objc private func selectTab() { switchBuffer(to: tabs.selectedSegment) }
    @objc private func previousBuffer() { switchBuffer(to: (session.active + session.count - 1) % session.count) }
    @objc private func nextBuffer() { switchBuffer(to: (session.active + 1) % session.count) }

    private func switchBuffer(to index: Int) {
        guard index >= 0, index < session.count, index != session.active else { return }
        session.rememberSelection(textView.selectedRange())
        session.select(index)
        showActiveBuffer()
    }

    @objc private func closeScratch() {
        guard confirmDiscard() else { return }
        guard session.close(discard: true) else { return }
        showActiveBuffer()
    }

    @objc private func saveFile() {
        var destination = fileURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Untitled.txt"
            guard panel.runModal() == .OK else { return }
            destination = panel.url
        }
        guard let destination else { return }
        do {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw CocoaError(.fileWriteNoPermission) }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // A new destination is expected not to exist before the first save.
        } catch { NSApp.presentError(error); return }
        do {
            try document.text.write(to: destination, atomically: true, encoding: .utf8)
            document.markSaved()
            session.setFileURL(destination)
            refreshTitle()
            scheduleSessionSave()
        } catch { NSApp.presentError(error) }
    }

    private func confirmDiscard() -> Bool {
        guard document.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this scratch?"
        alert.informativeText = "Closing removes this tab from your saved session. Save it as a file if you want to keep a separate copy."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closingWindow = saveBeforeQuitting()
        return closingWindow
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (closingWindow || saveBeforeQuitting()) ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func scheduleSessionSave() {
        guard recovery != nil else { return }
        saveGeneration &+= 1
        let generation = saveGeneration
        pendingSave?.cancel()
        status.stringValue = "Saving locally…"
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.saveGeneration == generation, let recovery = self.recovery else { return }
            self.session.rememberSelection(self.textView.selectedRange())
            recovery.save(self.session.checkpoint()) { [weak self] saved in
                guard let self, self.saveGeneration == generation else { return }
                self.status.stringValue = saved ? "Saved locally" : "Couldn't save tabs · Use ⌘S to keep your text"
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveBeforeQuitting() -> Bool {
        pendingSave?.cancel()
        saveGeneration &+= 1
        session.rememberSelection(textView.selectedRange())
        if let recovery, recovery.flush(session.checkpoint()) { return true }
        status.stringValue = "Couldn't save tabs · Use ⌘S to keep your text"
        let alert = NSAlert()
        alert.messageText = "Your latest tabs could not be saved."
        alert.informativeText = "Keep editing and save important text with ⌘S. Quitting now may lose changes since the last successful local save."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "vibechar", .applicationVersion: "0.1.0 · Preview"])
    }
}

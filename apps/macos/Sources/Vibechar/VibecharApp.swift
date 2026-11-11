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
            pocketInterfaceSmokeTest()
            AppDelegate.interfaceSmokeTest()
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    private let session: RustSession
    private let document: RustDocument
    private var fileURL: URL? { session.fileURL }
    private var window: NSWindow!
    private let textView = PocketTextView()
    private let header = PocketHeader()
    private let footer = PocketFooter()
    private var fontSize: CGFloat = 15
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
        let appearance = UserDefaults.standard.string(forKey: "PocketAppearance")
        NSApp.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
        makeMenus()
        makeWindow()
        showActiveBuffer()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        if let recoveryError {
            footer.showStatus("Recovery unavailable · Save important text with ⌘S", failed: true)
            NSApp.presentError(recoveryError)
        }
    }

    private func makeWindow(restoreFrame: Bool = true) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.delegate = self
        window.minSize = NSSize(width: 420, height: 280)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = PocketPalette.canvas
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        preparePocketTitlebar(for: window)
        if restoreFrame {
            if !window.setFrameUsingName("PocketWindow") { window.center() }
            window.setFrameAutosaveName("PocketWindow")
        }
        let content = PocketSurface()
        window.contentView = content

        textView.isRichText = false
        textView.backgroundColor = PocketPalette.canvas
        textView.textColor = PocketPalette.ink
        textView.insertionPointColor = PocketPalette.accent
        textView.selectedTextAttributes = [.backgroundColor: PocketPalette.selection, .foregroundColor: PocketPalette.ink]
        textView.textContainerInset = NSSize(width: 26, height: 26)
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
        textView.setAccessibilityHelp("Type or paste text. Command-N creates a scratch. Command-S saves a file.")
        applyTypography()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        scroll.backgroundColor = PocketPalette.canvas
        scroll.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        header.onSelect = { [weak self] in self?.switchBuffer(to: $0) }
        header.onClose = { [weak self] in self?.closeBuffer(at: $0) }
        header.onNew = { [weak self] in self?.newScratch() }
        content.appearanceChanged = { [weak self] in self?.applyTypography() }
        content.addSubview(header)
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 54),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 32),
        ])
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshTitle()
    }

    private func applyTypography() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.tabStops = []
        paragraph.defaultTabInterval = fontSize * 2.4
        textView.defaultParagraphStyle = paragraph
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = PocketPalette.ink
        textView.typingAttributes = [.font: textView.font!, .foregroundColor: PocketPalette.ink, .paragraphStyle: paragraph]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        }
        footer.detail.stringValue = "\(Int(fontSize)) pt  ·  UTF-8"
        textView.needsDisplay = true
    }

    @objc private func displayOptionsChanged() {
        (window.contentView as? PocketSurface)?.invalidateAppearance(in: window.contentView!)
    }

    func windowDidResize(_ notification: Notification) { header.needsLayout = true }
    func windowDidBecomeKey(_ notification: Notification) { header.needsLayout = true }
    func windowDidResignKey(_ notification: Notification) { header.needsLayout = true }
    func windowDidEnterFullScreen(_ notification: Notification) { header.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { header.needsLayout = true }

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
        let view = NSMenu(title: "View")
        addItem("Zoom In", action: #selector(zoomIn), key: "+", to: view)
        addItem("Zoom Out", action: #selector(zoomOut), key: "-", to: view)
        addItem("Actual Size", action: #selector(actualSize), key: "0", to: view)
        view.addItem(.separator())
        let appearanceMenu = NSMenu(title: "Appearance")
        for (tag, title) in ["Follow System", "Light", "Dark"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            appearanceMenu.addItem(item)
        }
        addMenu("Appearance", submenu: appearanceMenu, to: view)
        view.addItem(.separator())
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullScreen)
        addMenu("View", submenu: view, to: menu)
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
        textView.needsDisplay = true
        refreshTitle()
        scheduleSessionSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) { scheduleSessionSave() }

    private func refreshTitle() {
        window.title = "\(session.label(session.active)) — vibechar"
        window.isDocumentEdited = session.isModifiedFile(session.active)
        header.update(tabs: (0..<session.count).map {
            PocketTab(title: session.label($0), modifiedFile: session.isModifiedFile($0))
        }, active: session.active)
    }

    @objc private func undoEdit() { applyHistory(redo: false) }
    @objc private func redoEdit() { applyHistory(redo: true) }

    private func applyHistory(redo: Bool) {
        guard let cursor = document.history(redo: redo) else { return }
        textView.string = document.text
        applyTypography()
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
        applyTypography()
        textView.setSelectedRange(session.selection)
        textView.scrollRangeToVisible(textView.selectedRange())
        window.makeFirstResponder(textView)
        refreshTitle()
        scheduleSessionSave()
    }

    @objc private func previousBuffer() { switchBuffer(to: (session.active + session.count - 1) % session.count) }
    @objc private func nextBuffer() { switchBuffer(to: (session.active + 1) % session.count) }

    private func switchBuffer(to index: Int) {
        guard index >= 0, index < session.count else { return }
        if index == session.active { window.makeFirstResponder(textView); return }
        session.rememberSelection(textView.selectedRange())
        session.select(index)
        showActiveBuffer()
    }

    @objc private func closeScratch() {
        guard confirmDiscard() else { return }
        guard session.close(discard: true) else { return }
        showActiveBuffer()
    }

    private func closeBuffer(at index: Int) {
        guard index >= 0, index < session.count else { return }
        let previous = session.active
        switchBuffer(to: index)
        guard confirmDiscard() else { switchBuffer(to: previous); return }
        guard session.close(discard: true) else { return }
        let next = index == previous ? session.active : previous - (index < previous ? 1 : 0)
        session.select(next)
        showActiveBuffer()
    }

    @objc private func zoomIn() { fontSize = min(28, fontSize + 1); applyTypography() }
    @objc private func zoomOut() { fontSize = max(11, fontSize - 1); applyTypography() }
    @objc private func actualSize() { fontSize = 15; applyTypography() }

    @objc private func changeAppearance(_ sender: NSMenuItem) {
        let choice = ["system", "light", "dark"][sender.tag]
        UserDefaults.standard.set(choice, forKey: "PocketAppearance")
        NSApp.appearance = sender.tag == 1 ? NSAppearance(named: .aqua) : sender.tag == 2 ? NSAppearance(named: .darkAqua) : nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(changeAppearance(_:)) {
            let choice = UserDefaults.standard.string(forKey: "PocketAppearance") ?? "system"
            menuItem.state = ["system", "light", "dark"][menuItem.tag] == choice ? .on : .off
        }
        return true
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
        // Preserve a visible failure until a checkpoint has actually succeeded.
        if !footer.failed { footer.showStatus("Saving locally…") }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.saveGeneration == generation, let recovery = self.recovery else { return }
            self.session.rememberSelection(self.textView.selectedRange())
            recovery.save(self.session.checkpoint()) { [weak self] saved in
                guard let self, self.saveGeneration == generation else { return }
                self.footer.showStatus(saved ? "Saved locally" : "Couldn't save tabs · Use ⌘S to keep your text", failed: !saved)
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
        footer.showStatus("Couldn't save tabs · Use ⌘S to keep your text", failed: true)
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

    // Exercise the real window composition without opening a window or recovery store.
    static func interfaceSmokeTest() {
        let app = AppDelegate()
        app.makeWindow(restoreFrame: false)
        defer { app.window.delegate = nil; app.window.close() }
        let sample = "{\n  \"service\": \"vibechar\",\n  \"environment\": \"development\",\n  \"api\": {\n    \"host\": \"localhost\",\n    \"port\": 8080\n  }\n}"
        precondition(app.document.replace(NSRange(location: 0, length: 0), with: sample))
        app.session.open("Ребят, небольшой апдейт по редактору.\n\nВкладки сохраняются после перезапуска. 👩‍💻")
        app.session.open("09:41:02 INFO  worker started\n09:41:04 ERROR request timeout")
        app.session.select(0)
        app.showActiveBuffer()
        let output = ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            app.window.appearance = NSAppearance(named: appearance)
            for width in [420, 880] {
                app.window.setContentSize(NSSize(width: width, height: 600))
                let view = app.window.contentView!
                app.window.layoutIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                view.superview?.layoutSubtreeIfNeeded()
                app.header.needsLayout = true
                view.layoutSubtreeIfNeeded()
                precondition(app.textView.string == sample, "Layout/theme must not alter the document")
                precondition(app.header.frame.height == 54 && app.footer.frame.height == 32)
                precondition(!app.header.frame.intersects(app.footer.frame))
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    let button = app.window.standardWindowButton(kind)!
                    let root = view.superview!
                    let center = root.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                    let fits = button.visibleRect.contains(button.bounds)
                    let hit = root.hitTest(center)
                    if !fits || hit !== button {
                        FileHandle.standardError.write(Data("Window-button check failed (\(name), \(width)): frame \(button.frame), container \(button.superview!.bounds), hit \(String(describing: hit)), expected \(button)\n".utf8))
                        preconditionFailure("System window buttons must fit and receive clicks")
                    }
                }
                let close = app.window.standardWindowButton(.closeButton)!
                let closeCenter = app.header.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), from: close)
                precondition(abs(closeCenter.y - 27) < 1, "Traffic lights must align with the tab row")
                func checkHeaderHitTargets(_ node: NSView) {
                    guard !node.isHidden else { return }
                    if let button = node as? NSButton {
                        let root = view.superview!
                        let center = root.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                        let hit = root.hitTest(center)
                        if hit !== button && hit?.isDescendant(of: button) != true {
                            FileHandle.standardError.write(Data("Header click intercepted: \(button.toolTip ?? button.title), frame \(button.frame), parent \(String(describing: button.superview)), center \(center), header \(app.header.frame), root frame \(root.frame) bounds \(root.bounds), by \(String(describing: hit))\n".utf8))
                            preconditionFailure("The native titlebar must not intercept tab controls")
                        }
                    }
                    node.subviews.forEach(checkHeaderHitTargets)
                }
                checkHeaderHitTargets(app.header)
                guard let output else { continue }
                app.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        preconditionFailure("Could not render the native interface")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("pocket-\(name)-\(width).png"))
                }
            }
        }
        app.fontSize = 19
        app.applyTypography()
        precondition(app.textView.string == sample && app.document.text == sample)
        precondition(app.document.history(redo: false) != nil)
        precondition(app.document.text.isEmpty, "Typography changes must not enter document history")
        precondition(app.document.history(redo: true) != nil)
        precondition(!app.session.isModifiedFile(0))
        app.session.setFileURL(URL(fileURLWithPath: "/tmp/vibechar-interface-smoke.json"))
        app.refreshTitle()
        precondition(app.window.isDocumentEdited)
        app.document.markSaved()
        app.refreshTitle()
        precondition(!app.window.isDocumentEdited)
        print("Pocket window smoke test passed: light/dark, narrow/wide, native/tab click targets, text/history")
    }
}

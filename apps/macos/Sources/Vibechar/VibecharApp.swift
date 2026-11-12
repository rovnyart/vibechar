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
            AppDelegate.inputSmokeTest()
            AppDelegate.closeSmokeTest()
            AppDelegate.saveAsSmokeTest()
            AppDelegate.syntaxSmokeTest()
            AppDelegate.quietSelectionSmokeTest()
            AppDelegate.findSmokeTest()
            AppDelegate.toolsSmokeTest()
            AppDelegate.multiSmokeTest()
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
            original.openPrivate()
            precondition(text.replace(NSRange(location: 0, length: 0), with: "PRIVATE_NATIVE_FIXTURE"))
            original.select(1)
            precondition(store!.flush(original.checkpoint()))
            let savedBytes = try Data(contentsOf: store!.fileURL)
            precondition(!String(decoding: savedBytes, as: UTF8.self).contains("PRIVATE_NATIVE_FIXTURE"))
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
    private let clipboard: NSPasteboard
    private var fileURL: URL? { session.fileURL }
    private var window: NSWindow!
    private let textView = PocketTextView()
    private let header = PocketHeader()
    private let footer = PocketFooter()
    private let findBar = FindBar()
    private var toolPalette: ToolPalette?
    private lazy var multiController:MultiController = {
        let controller=MultiController(document:document,textView:textView,clipboard:clipboard)
        controller.didEdit={ [weak self] in
            guard let self else {return}
            self.applyTypography();self.refreshTitle();self.scheduleSessionSave();self.scheduleSyntax()
        }
        controller.didUpdate={ [weak self] state in
            guard let self else {return}
            self.footer.operationError=state.message
            let count=state.selections.count
            let noun=state.selections.allSatisfy {$0.length==0} ? (count==1 ? "caret" : "carets") : (count==1 ? "selection" : "selections")
            self.footer.multiStatus=state.busy ? "Finding matches…" : state.active ? "\(count) \(noun) · Esc to leave" : nil
            self.scheduleSessionSave(quiet:true)
        }
        return controller
    }()
    private lazy var findController: FindController = {
        let controller = FindController(bar: findBar,document: document,textView: textView)
        controller.didReplace = { [weak self] selection in
            guard let self else { return }
            self.textView.string = self.document.text
            self.applyTypography(); self.textView.setSelectedRange(selection)
            self.textView.scrollRangeToVisible(selection)
            self.window.makeFirstResponder(self.textView)
            self.refreshTitle(); self.scheduleSessionSave(); self.scheduleSyntax()
        }
        controller.didSelectAll={ [weak self] frame,primary in
            guard let self else {return}
            self.multiController.adopt(frame:frame,primary:primary)
            if self.multiController.active {self.findController.close();self.multiController.paint()}
        }
        return controller
    }()
    private var fontSize: CGFloat = 15
    private var closingWindow = false
    private var recovery: SessionRecovery?
    private var pendingSave: DispatchWorkItem?
    private var saveGeneration: UInt64 = 0
    private var dropTimer: Timer?
    private var syntaxTimer: Timer?
    private var syntaxWork: DispatchWorkItem?
    private var syntaxFrame: SyntaxFrame?
    private var syntaxSerial: UInt64 = 0
    private var syntaxGeneration: UInt64 = 0
    private var languagePopover: NSPopover?

    init(clipboard: NSPasteboard = .general) {
        let session = RustSession()
        self.session = session
        document = RustDocument(session: session)
        self.clipboard = clipboard
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
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(closeAllAgentAccess), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(closeAllAgentAccess), name: name, object: nil)
        }
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
        // Rust checkpoints are the only document recovery path, including private filtering.
        window.isRestorable = false
        window.disableSnapshotRestoration()
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
        textView.onBreakUndoGroup = { [weak self] in self?.document.breakUndoGroup() }
        textView.setAccessibilityLabel("Text editor")
        textView.setAccessibilityHelp("Type or paste text. Command-N creates a scratch. Command-S saves a file.")
        applyTypography()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(syntaxViewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.documentView = textView
        scroll.backgroundColor = PocketPalette.canvas
        scroll.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        header.onSelect = { [weak self] in self?.switchBuffer(to: $0) }
        header.onClose = { [weak self] in self?.closeBuffer(at: $0) }
        header.onNew = { [weak self] in self?.newScratch() }
        footer.onGive = { [weak self] in self?.copyForAgent() }
        footer.onStop = { [weak self] in self?.closeAgentAccess() }
        footer.onLanguage = { [weak self] in self?.showLanguagePicker() }
        content.appearanceChanged = { [weak self] in self?.applyTypography() }
        content.addSubview(header)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(findBar)
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 54),
            findBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            findBar.height,
            scroll.topAnchor.constraint(equalTo: findBar.bottomAnchor),
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
        _ = findController
        _ = multiController
        textView.onEscape = { [weak self] in
            guard let self else {return false}
            if self.multiController.active {self.multiController.cancel();return true}
            guard self.findController.visible else { return false }
            self.findController.close(); return true
        }
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
        paintSyntax()
    }

    @objc private func displayOptionsChanged() {
        (window.contentView as? PocketSurface)?.invalidateAppearance(in: window.contentView!)
    }

    func windowDidResize(_ notification: Notification) { header.needsLayout = true }
    func windowDidBecomeKey(_ notification: Notification) { header.needsLayout = true }
    func windowDidResignKey(_ notification: Notification) { document.breakUndoGroup(); header.needsLayout = true }
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
        let privateScratch = NSMenuItem(title: "New Private Scratch", action: #selector(newPrivateScratch), keyEquivalent: "n")
        privateScratch.keyEquivalentModifierMask = [.command, .shift]
        privateScratch.target = self
        file.addItem(privateScratch)
        addItem("Open…", action: #selector(openFile), key: "o", to: file)
        addItem("Save", action: #selector(saveFile), key: "s", to: file)
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(saveFileAs), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        saveAs.target = self
        file.addItem(saveAs)
        addItem("Close Tab", action: #selector(closeScratch), key: "w", to: file)
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
        edit.addItem(.separator())
        addItem("Add Next Occurrence",action:#selector(addNextOccurrence),key:"d",to:edit)
        let allOccurrences=NSMenuItem(title:"Select All Occurrences",action:#selector(selectAllOccurrences),keyEquivalent:"l")
        allOccurrences.keyEquivalentModifierMask=[.command,.shift];allOccurrences.target=self;edit.addItem(allOccurrences)
        addItem("Text Tools…",action:#selector(openTools),key:"k",to:edit)
        addItem("Find…",action:#selector(openFind),key:"f",to:edit)
        let replace = NSMenuItem(title:"Find and Replace…",action:#selector(openReplace),keyEquivalent:"f")
        replace.keyEquivalentModifierMask = [.command,.option]; replace.target=self; edit.addItem(replace)
        addItem("Find Next",action:#selector(findNext),key:"g",to:edit)
        let previousMatchItem = NSMenuItem(title:"Find Previous",action:#selector(findPrevious),keyEquivalent:"g")
        previousMatchItem.keyEquivalentModifierMask = [.command,.shift]; previousMatchItem.target=self; edit.addItem(previousMatchItem)
        addMenu("Edit", submenu: edit, to: menu)
        let view = NSMenu(title: "View")
        let language = NSMenuItem(title: "Choose Language…", action: #selector(showLanguagePicker), keyEquivalent: "l")
        language.keyEquivalentModifierMask = [.command, .control]
        language.target = self
        view.addItem(language)
        view.addItem(.separator())
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
        let agent = NSMenu(title: "Agent")
        let give = NSMenuItem(title: "Copy for Agent", action: #selector(copyForAgent), keyEquivalent: "c")
        give.keyEquivalentModifierMask = [.command, .shift]
        give.target = self
        agent.addItem(give)
        let paste = NSMenuItem(title: "Paste Secret for Agent", action: #selector(pasteForAgent), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = [.command, .option]
        paste.target = self
        agent.addItem(paste)
        agent.addItem(.separator())
        addItem("Close This Tab's Agent Access", action: #selector(closeAgentAccess), key: "", to: agent)
        addItem("Close All Agent Access", action: #selector(closeAllAgentAccess), key: "", to: agent)
        addMenu("Agent", submenu: agent, to: menu)
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
        let accepted = document.replace(affectedCharRange, with: replacementString, kind: self.textView.editKind)
        if !accepted { NSSound.beep() }
        return accepted
    }

    func textDidChange(_ notification: Notification) {
        multiController.sourceChanged()
        toolPalette?.close(); toolPalette=nil
        textView.needsDisplay = true
        refreshTitle()
        scheduleSessionSave()
        scheduleSyntax()
        findController.sourceChanged()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        multiController.selectionChanged()
        if !textView.isPerformingEdit && !multiController.syncing {
            document.breakUndoGroup()
            scheduleSessionSave(quiet: true)
        }
    }

    private func scheduleSyntax() {
        guard !closingWindow else { return }
        syntaxWork?.cancel()
        syntaxGeneration &+= 1; let generation = syntaxGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.closingWindow, self.syntaxGeneration == generation else { return }
            self.session.submitSyntax()
            if self.pollSyntax() && self.syntaxTimer == nil {
                self.syntaxTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] timer in
                    MainActor.assumeIsolated {
                        guard let self else { timer.invalidate(); return }
                        self.pollSyntax()
                    }
                }
            }
        }
        syntaxWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    @discardableResult private func pollSyntax() -> Bool {
        // Read busy first so a completion between these calls still gets painted.
        let busy = session.syntaxBusy
        if let frame = session.syntaxFrame(after: syntaxSerial) {
            syntaxFrame = frame; syntaxSerial = frame.serial
            footer.showSyntax(frame.language, automatic: frame.automatic, reason: frame.reason, limited: frame.limited)
            paintSyntax()
        }
        if !busy { syntaxTimer?.invalidate(); syntaxTimer = nil }
        return busy
    }
    @objc private func syntaxViewportChanged() { paintSyntax(); findController.paint();multiController.paint() }
    @objc private func addNextOccurrence() {openOccurrences(all:false)}
    @objc private func selectAllOccurrences() {openOccurrences(all:true)}
    private func openOccurrences(all:Bool) {
        toolPalette?.close();toolPalette=nil;languagePopover?.performClose(nil);languagePopover=nil
        if all && findController.visible {findController.selectAllForEditing();return}
        if findController.visible {findController.close()}
        window.makeFirstResponder(textView);multiController.request(all:all)
    }
    private func multipleInputReady()->Bool {
        if multiController.ready() {return true}
        footer.operationError="Finishing matching · try that command again shortly";return false
    }
    @objc private func openFind() {guard multipleInputReady() else {return}; multiController.cancel();toolPalette?.close(); toolPalette=nil; findController.open(replacing:false) }
    @objc private func openReplace() {guard multipleInputReady() else {return}; multiController.cancel();toolPalette?.close(); toolPalette=nil; findController.open(replacing:true) }
    @objc private func openTools() {
        guard multipleInputReady() else {return}
        multiController.cancel()
        toolPalette?.close(); toolPalette=nil
        languagePopover?.performClose(nil); languagePopover=nil
        if findController.visible { findController.close() }
        let selection=textView.selectedRange(); let selected=selection.length>0
        let target=selected ? selection : NSRange(location:0,length:(textView.string as NSString).length)
        let scope="\(selected ? "Selection" : "Whole tab") · \(session.isPrivate ? "private · " : "")local text tools"
        let palette=ToolPalette(document:document,target:target,selectedText:selected,scope:scope,didDismiss:{ [weak self] in
            self?.toolPalette=nil; self?.window.makeFirstResponder(self?.textView)
        },didApply:{ [weak self] range,changed in
            guard let self else { return }
            self.toolPalette=nil
            if changed {
                self.footer.operationError=nil
                self.textView.string=self.document.text; self.applyTypography()
                self.textView.setSelectedRange(range); self.textView.scrollRangeToVisible(range)
                self.refreshTitle(); self.scheduleSessionSave(); self.scheduleSyntax()
            } else { self.footer.operationError="Already in shape · no changes" }
            self.window.makeFirstResponder(self.textView)
        })
        toolPalette=palette; palette.open(relativeTo:header)
    }
    @objc private func findNext() { if !findController.visible { openFind() } else { findController.move(1) } }
    @objc private func findPrevious() { if !findController.visible { openFind() } else { findController.move(-1) } }
    private func paintSyntax() {
        guard let layout = textView.layoutManager, let storage = textView.textStorage else { return }
        guard let frame = syntaxFrame else {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            return
        }
        guard frame.revision == document.revision else { return }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        guard !frame.spans.isEmpty, let container = textView.textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let start = max(0, visible.location - 2048)
        let end = min(storage.length, NSMaxRange(visible) + 2048)
        let window = NSRange(location: start, length: max(0, end-start))
        for span in frame.spans {
            if span.start >= end { break }
            let range = NSIntersectionRange(window, NSRange(location: span.start, length: span.length))
            if range.length > 0 { layout.addTemporaryAttribute(.foregroundColor, value: SyntaxColors.color(span.role), forCharacterRange: range) }
        }
    }
    @objc private func showLanguagePicker() {
        guard multipleInputReady() else {return}
        multiController.cancel()
        toolPalette?.close(); toolPalette=nil
        document.breakUndoGroup()
        languagePopover?.performClose(nil)
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
        let hint = syntaxFrame.map { "\($0.language) · \($0.reason)" } ?? "Automatic · file name + pasted text"
        let dismiss = { [weak self] in
            self?.languagePopover?.performClose(nil)
            if let self { self.window.makeFirstResponder(self.textView) }
        }
        popover.contentViewController = LanguagePicker(hint: hint, dismissed: dismiss) { [weak self] mode in
            guard let self, self.session.setLanguage(mode) else { return }
            self.languagePopover?.performClose(nil)
            self.window.makeFirstResponder(self.textView)
            self.syntaxFrame = nil; self.syntaxSerial = 0
            self.footer.showSyntax(mode.isEmpty ? "Text" : mode, automatic: mode.isEmpty, reason: mode.isEmpty ? "Detecting locally" : "Pinned for this tab", limited: false)
            self.paintSyntax(); self.scheduleSyntax(); self.scheduleSessionSave()
        }
        languagePopover = popover
        popover.show(relativeTo: footer.languageButton.bounds, of: footer.languageButton, preferredEdge: .maxY)
    }

    private func refreshTitle() {
        window.title = "\(session.label(session.active)) — vibechar"
        window.isDocumentEdited = session.isModifiedFile(session.active)
        header.update(tabs: (0..<session.count).map {
            PocketTab(title: session.label($0), modifiedFile: session.isModifiedFile($0), isPrivate: session.isPrivate($0))
        }, active: session.active)
        footer.privateTab = session.isPrivate
        refreshDropStatus()
    }

    @objc private func undoEdit() {
        if let field=NSApp.keyWindow?.firstResponder as? NSTextView,field.isFieldEditor { field.undoManager?.undo(); return }
        applyHistory(redo: false)
    }
    @objc private func redoEdit() {
        if let field=NSApp.keyWindow?.firstResponder as? NSTextView,field.isFieldEditor { field.undoManager?.redo(); return }
        applyHistory(redo: true)
    }

    private func applyHistory(redo: Bool) {
        guard multipleInputReady() else {return}
        multiController.cancel()
        guard let cursor = document.history(redo: redo) else { return }
        textView.string = document.text
        applyTypography()
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        refreshTitle()
        scheduleSessionSave()
        scheduleSyntax()
        findController.sourceChanged()
    }

    @objc private func newScratch() {
        guard multipleInputReady() else {return}
        session.rememberSelection(textView.selectedRange())
        session.open()
        showActiveBuffer()
    }

    @objc private func newPrivateScratch() {
        guard multipleInputReady() else {return}
        session.rememberSelection(textView.selectedRange())
        session.openPrivate()
        showActiveBuffer()
    }

    @objc private func copyForAgent() {
        guard multipleInputReady() else {return}
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vibechar").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            footer.operationError = "Agent helper unavailable · Rebuild the app"
            return
        }
        do {
            let instruction = try session.shareForAgent(executable: helper)
            clipboard.clearContents()
            guard clipboard.setString(instruction, forType: .string) else {
                session.revokeDrop()
                footer.operationError = "Couldn't copy instructions · Access closed"
                return
            }
            footer.operationError = nil
            refreshDropStatus()
            if dropTimer == nil {
                dropTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                    MainActor.assumeIsolated {
                        guard let self else { timer.invalidate(); return }
                        self.refreshDropStatus()
                    }
                }
            }
        } catch {
            session.revokeDrop()
            footer.operationError = error.localizedDescription
        }
    }

    @objc private func pasteForAgent() {
        guard multipleInputReady() else {return}
        guard let text = clipboard.string(forType: .string), !text.isEmpty,
              text.utf8.count <= 65536, !text.contains("\0") else {
            footer.operationError = "Copy a secret first · Up to 64 KiB of text"
            return
        }
        guard !text.hasPrefix("Use this local Vibechar Secret Drop") else {
            footer.operationError = "Instructions already copied · Copy a new secret first"
            return
        }
        newPrivateScratch()
        let inserted = document.replace(NSRange(location: 0, length: 0), with: text)
        precondition(inserted)
        session.rememberSelection(NSRange(location: text.utf16.count, length: 0))
        showActiveBuffer()
        copyForAgent()
    }
    @objc private func closeAgentAccess() { session.revokeDrop(); footer.operationError = nil; refreshDropStatus() }
    @objc private func closeAllAgentAccess() { session.revokeAllDrops(); footer.operationError = nil; refreshDropStatus() }
    private func refreshDropStatus() {
        footer.agentUses = session.dropActive ? session.dropUses : nil
        if !session.hasDropAccess {
            dropTimer?.invalidate()
            dropTimer = nil
        }
    }

    @objc private func openFile() {
        guard multipleInputReady() else {return}
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
        multiController.cancel()
        toolPalette?.close(); toolPalette=nil
        if findController.visible { findController.close() }
        footer.operationError = nil
        syntaxFrame = nil; syntaxSerial = 0
        footer.showSyntax(session.language.isEmpty ? "Text" : session.language, automatic: session.language.isEmpty, reason: session.language.isEmpty ? "Detects file names and pasted text locally" : "Pinned for this tab", limited: false)
        textView.string = document.text
        applyTypography()
        textView.setSelectedRange(session.selection)
        textView.scrollRangeToVisible(textView.selectedRange())
        window.makeFirstResponder(textView)
        refreshTitle()
        scheduleSessionSave()
        scheduleSyntax()
    }

    @objc private func previousBuffer() { switchBuffer(to: (session.active + session.count - 1) % session.count) }
    @objc private func nextBuffer() { switchBuffer(to: (session.active + 1) % session.count) }

    private func switchBuffer(to index: Int) {
        guard multipleInputReady() else {return}
        guard index >= 0, index < session.count else { return }
        if index == session.active { document.breakUndoGroup(); window.makeFirstResponder(textView); return }
        session.rememberSelection(textView.selectedRange())
        session.select(index)
        showActiveBuffer()
    }

    @objc private func closeScratch() {
        closeBuffer(at: session.active)
    }

    private func closeBuffer(at index: Int) {
        guard multipleInputReady() else {return}
        guard index >= 0, index < session.count else { return }
        let previous = session.active
        switchBuffer(to: index)
        guard confirmDiscard() else { switchBuffer(to: previous); return }
        let lastTab = session.count == 1
        // Persist the removal before discarding the live document. A failed flush
        // can then keep the original text open if the user cancels closing.
        if lastTab && !flushBeforeExit(RustSession().checkpoint(), closingLastTab: true) { return }
        guard session.close(discard: true) else { return }
        if lastTab {
            closingWindow = true
            textView.delegate = nil
            closeAllAgentAccess()
            window.performClose(nil)
            return
        }
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
        if menuItem.action == #selector(copyForAgent) { return session.isPrivate && !textView.string.isEmpty }
        if menuItem.action == #selector(closeAgentAccess) { return session.dropActive }
        if menuItem.action == #selector(closeAllAgentAccess) { return session.hasDropAccess }
        if menuItem.action == #selector(saveFile) {
            menuItem.title = session.isPrivate ? "Save…" : "Save"
        }
        if menuItem.action == #selector(changeAppearance(_:)) {
            let choice = UserDefaults.standard.string(forKey: "PocketAppearance") ?? "system"
            menuItem.state = ["system", "light", "dark"][menuItem.tag] == choice ? .on : .off
        }
        return true
    }

    @objc private func saveFile() {
        do { try performSave(alwaysChooseDestination: false) }
        catch { NSApp.presentError(error) }
    }

    @objc private func saveFileAs() {
        do { try performSave(alwaysChooseDestination: true) }
        catch { NSApp.presentError(error) }
    }

    private func performSave(alwaysChooseDestination: Bool,
                             chooseDestination: @MainActor (NSSavePanel) -> URL? = { $0.runModal() == .OK ? $0.url : nil }) throws {
        guard multipleInputReady() else {throw NSError(domain:"Vibechar",code:1,userInfo:[NSLocalizedDescriptionKey:"Finishing occurrence matching. Save again when it completes."])}
        toolPalette?.close(); toolPalette=nil
        document.breakUndoGroup()
        let wasPrivate = session.isPrivate
        var destination = alwaysChooseDestination || wasPrivate ? nil : fileURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.txt"
            if let fileURL { panel.directoryURL = fileURL.deletingLastPathComponent() }
            if wasPrivate {
                panel.title = "Save Private Tab"
                panel.message = "Saving makes this a regular file tab, includes it in local recovery, and closes its agent access."
                panel.nameFieldStringValue = "Private.txt"
            }
            destination = chooseDestination(panel)
        }
        guard let destination else { return }
        try saveActive(to: destination)
    }

    private func saveActive(to destination: URL) throws {
        do {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isWritableKey])
            if values.isSymbolicLink == true || values.isWritable == false { throw CocoaError(.fileWriteNoPermission) }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // A new destination is expected not to exist before the first save.
        }
        try document.text.write(to: destination, atomically: true, encoding: .utf8)
        session.completeSave(to: destination)
        footer.operationError = nil
        refreshTitle()
        scheduleSessionSave()
        scheduleSyntax()
    }

    private func confirmDiscard() -> Bool {
        guard session.needsCloseConfirmation else { return true }
        let alert = NSAlert()
        alert.messageText = session.isPrivate ? "Discard this private tab?" : "Close this scratch?"
        alert.informativeText = session.isPrivate
            ? "This text is not saved for recovery. Files you explicitly saved remain on disk."
            : "Closing removes this tab from your saved session. Save it as a file if you want to keep a separate copy."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingWindow { return true }
        closingWindow = saveBeforeQuitting()
        return closingWindow
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (closingWindow || saveBeforeQuitting()) ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        // AppKit terminates the process without guaranteeing Swift/Rust deinit.
        closeAllAgentAccess()
        syntaxWork?.cancel(); syntaxTimer?.invalidate()
        findController.close()
        multiController.cancel()
        toolPalette?.close(); toolPalette=nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func scheduleSessionSave(quiet: Bool = false) {
        guard !closingWindow, recovery != nil else { return }
        // Capture the latest caret when queued work runs; navigation must not
        // flash the text-save status or postpone an already pending text write.
        if quiet && (session.isPrivate || pendingSave != nil || session.selection == textView.selectedRange()) { return }
        saveGeneration &+= 1
        let generation = saveGeneration
        pendingSave?.cancel()
        // Preserve a visible failure until a checkpoint has actually succeeded.
        if !quiet && !footer.failed { footer.showStatus("Saving locally…") }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.saveGeneration == generation, let recovery = self.recovery else { return }
            self.pendingSave = nil
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
        guard multipleInputReady() else {return false}
        if session.hasPrivateText {
            let alert = NSAlert()
            alert.messageText = "Quit and discard private tabs?"
            alert.informativeText = "Private tabs won't return when you reopen vibechar. Ordinary tabs will be saved. Files you explicitly saved remain on disk."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Quit and Discard Private Tabs")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        session.rememberSelection(textView.selectedRange())
        return flushBeforeExit(session.checkpoint())
    }

    private func flushBeforeExit(_ checkpoint: RustCheckpoint, closingLastTab: Bool = false) -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        saveGeneration &+= 1
        if let recovery, recovery.flush(checkpoint) { return true }
        footer.showStatus("Couldn't save tabs · Use ⌘S to keep your text", failed: true)
        let alert = NSAlert()
        alert.messageText = closingLastTab ? "The closed-tab state could not be saved." : "Your latest tabs could not be saved."
        alert.informativeText = closingLastTab
            ? "Keep Editing preserves this tab. Closing anyway may restore an earlier session when you reopen vibechar."
            : "Keep editing and save important text with ⌘S. Quitting now may lose changes since the last successful local save."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: closingLastTab ? "Close Anyway" : "Quit Without Saving")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "vibechar", .applicationVersion: "0.1.0 · Preview"])
    }

    static func quietSelectionSmokeTest() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-selection-\(UUID().uuidString)", isDirectory: true)
        let app = AppDelegate(clipboard: .withUniqueName())
        app.recovery = try! SessionRecovery(directory: root)
        app.makeWindow(restoreFrame: false)
        defer {
            app.pendingSave?.cancel(); app.saveGeneration &+= 1
            app.syntaxWork?.cancel(); app.syntaxTimer?.invalidate()
            app.window.delegate = nil; app.window.close(); app.recovery = nil
            app.clipboard.clearContents(); try! FileManager.default.removeItem(at: root)
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 5)
            while !condition() {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                precondition(Date() < deadline, "Selection recovery must finish")
            }
        }
        app.showActiveBuffer()
        app.textView.insertText("hello 👩‍💻", replacementRange: NSRange(location: NSNotFound, length: 0))
        wait { app.pendingSave == nil && app.footer.status.stringValue == "Saved locally" }
        let revision = app.document.revision
        for range in [NSRange(location: 0, length: 0), NSRange(location: 1, length: 3), NSRange(location: 0, length: 5)] {
            app.textView.setSelectedRange(range)
            precondition(app.footer.status.stringValue == "Saved locally", "Selection must not show Saving locally")
        }
        let restored = RustSession()
        wait { (try? restored.restore(from: app.recovery!.fileURL)) == true && restored.selection == NSRange(location: 0, length: 5) }
        precondition(app.document.revision == revision)
        let generation = app.saveGeneration
        app.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        precondition(app.saveGeneration == generation, "Unchanged selection must not schedule a write")

        app.textView.insertText("world", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(app.footer.status.stringValue == "Saving locally…")
        let pending = app.pendingSave
        let editGeneration = app.saveGeneration
        for index in 0..<4 {
            app.textView.setSelectedRange(NSRange(location: index, length: 1))
            precondition(app.pendingSave === pending && app.saveGeneration == editGeneration, "Navigation must not postpone the text write")
        }
        wait { app.pendingSave == nil && app.footer.status.stringValue == "Saved locally" }
        precondition(try! restored.restore(from: app.recovery!.fileURL))
        precondition(RustDocument(session: restored).text == "world 👩‍💻")
        precondition(restored.selection == NSRange(location: 3, length: 1))

        // Quiet saves still report real failures, and clear them only after success.
        let file = app.recovery!.fileURL
        try! FileManager.default.removeItem(at: file)
        try! FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        app.textView.setSelectedRange(NSRange(location: 0, length: 0))
        wait { app.footer.failed }
        precondition(app.footer.status.stringValue.contains("Couldn't save tabs"))
        try! FileManager.default.removeItem(at: file)
        app.textView.setSelectedRange(NSRange(location: 2, length: 0))
        precondition(app.footer.failed, "Navigation must preserve an error until saving succeeds")
        wait { !app.footer.failed && app.footer.status.stringValue == "Saved locally" }
        app.newPrivateScratch()
        app.textView.insertText("PRIVATE_SELECTION_FIXTURE", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.65))
        let privateGeneration = app.saveGeneration
        app.textView.setSelectedRange(NSRange(location: 0, length: 7))
        precondition(app.saveGeneration == privateGeneration)
        precondition(!String(decoding: try! Data(contentsOf: file), as: UTF8.self).contains("PRIVATE_SELECTION_FIXTURE"))
        print("Quiet Mac selection smoke passed: caret/selection, no-op, pending text deadline, restart, failure/recovery, private exclusion")
    }

    static func multiSmokeTest() {
        let app=AppDelegate(clipboard:.withUniqueName())
        app.makeWindow(restoreFrame:false)
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-multi-\(UUID().uuidString)")
        defer {
            app.multiController.cancel();app.findController.close();app.pendingSave?.cancel();app.pendingSave=nil
            if let recovery=app.recovery {_=recovery.flush(app.session.checkpoint())};app.recovery=nil
            app.syntaxWork?.cancel();app.syntaxTimer?.invalidate();app.window.delegate=nil;app.window.close();app.clipboard.clearContents()
            try? FileManager.default.removeItem(at:temporary)
        }
        let source="cat 👩‍💻\r\ncat CAT cat"
        precondition(app.document.replace(NSRange(location:0,length:0),with:source));app.document.markSaved();app.showActiveBuffer();app.makeMenus()
        app.recovery=try! SessionRecovery(directory:temporary)
        precondition(app.recovery!.flush(app.session.checkpoint()))
        app.footer.showStatus("Saved locally")
        func wait() {
            let deadline=Date(timeIntervalSinceNow:4)
            while app.multiController.state.busy {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01));app.multiController.poll();precondition(Date()<deadline)}
        }
        func selectAll(_ range:NSRange=NSRange(location:0,length:3)) {
            app.multiController.cancel();app.textView.setSelectedRange(range);app.selectAllOccurrences();wait()
        }
        app.addNextOccurrence();app.selectAllOccurrences()
        app.textView.doCommand(by:#selector(NSResponder.moveRight(_:)));app.textView.deleteBackward(nil);app.textView.deleteBackward(nil);wait()
        precondition(app.document.text=="c 👩‍💻\r\nc CAT c");app.undoEdit();precondition(app.document.text==source && !app.document.isDirty)
        let saveDeadline=Date(timeIntervalSinceNow:4)
        while app.pendingSave != nil || app.footer.status.stringValue.hasPrefix("Saving locally") {
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01));precondition(Date()<saveDeadline)
        }
        let revision=app.document.revision
        app.textView.setSelectedRange(NSRange(location:0,length:0))
        app.addNextOccurrence();precondition(app.multiController.state.selections.count==1 && app.textView.selectedRange()==NSRange(location:0,length:3))
        app.addNextOccurrence();wait();precondition(app.multiController.state.selections.count==2)
        app.selectAllOccurrences();wait();precondition(app.multiController.state.selections.count==3)
        precondition(app.document.revision==revision && !app.document.isDirty && app.footer.status.stringValue.hasPrefix("Saved locally"))
        let output=ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"].map {URL(fileURLWithPath:$0,isDirectory:true)}
        func snapshots(_ state:String) {
            guard let output else {return}
            try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
                app.window.appearance=NSAppearance(named:appearance)
                for width in [420,880] {
                    app.window.setContentSize(NSSize(width:width,height:600));app.window.contentView!.layoutSubtreeIfNeeded();app.multiController.paint()
                    app.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        let view=app.window.contentView!,bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                        view.cacheDisplay(in:view.bounds,to:bitmap)
                        try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("multi-\(state)-\(name)-\(width).png"))
                    }
                }
            }
        }
        snapshots("selections")
        for text in ["d","o","g"] {app.textView.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0))}
        precondition(app.document.text=="dog 👩‍💻\r\ndog CAT dog" && app.textView.string==app.document.text)
        precondition(app.textView.secondaryCarets.count==2);snapshots("carets")
        app.undoEdit();precondition(app.document.text==source && !app.document.isDirty && !app.multiController.active)
        app.redoEdit();precondition(app.document.text=="dog 👩‍💻\r\ndog CAT dog");app.undoEdit()
        selectAll();app.textView.copy(nil);precondition(app.clipboard.string(forType:.string)=="cat\ncat\ncat")
        app.textView.cut(nil);precondition(app.document.text==" 👩‍💻\r\n CAT ");app.undoEdit();precondition(app.document.text==source)
        selectAll();app.clipboard.clearContents();precondition(app.clipboard.setString("a\r\nb",forType:.string));app.textView.paste(nil)
        precondition(app.document.text==source.replacingOccurrences(of:"cat",with:"a\r\nb"));app.undoEdit();precondition(app.document.text==source)
        selectAll();app.textView.doCommand(by:#selector(NSResponder.moveRight(_:)));app.textView.deleteBackward(nil);app.textView.deleteBackward(nil)
        precondition(app.document.text=="c 👩‍💻\r\nc CAT c");app.undoEdit();precondition(app.document.text==source && !app.document.isDirty)
        selectAll(NSRange(location:4,length:5));app.textView.doCommand(by:#selector(NSResponder.moveRight(_:)));app.textView.deleteBackward(nil)
        precondition(app.document.text=="cat \r\ncat CAT cat");app.undoEdit();precondition(app.document.text==source)
        app.openFind();app.findBar.find.stringValue="cat|👩‍💻";app.findBar.regex.state = .on
        app.findController.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));app.selectAllOccurrences()
        let deadline=Date(timeIntervalSinceNow:4)
        while app.findController.visible {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01));app.findController.poll();precondition(Date()<deadline)}
        precondition(app.multiController.state.selections.count==5) // Default Find is case-insensitive: CAT is included.
        app.textView.insertText("X",replacementRange:NSRange(location:NSNotFound,length:0));precondition(app.document.text=="X X\r\nX X X")
        app.undoEdit();precondition(app.document.text==source)
        app.textView.setSelectedRange(NSRange(location:(source as NSString).range(of:"\r\n").location,length:0));app.openFind()
        app.findBar.find.stringValue="cat|$";app.findBar.regex.state = .on
        app.findController.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));app.selectAllOccurrences()
        let copyDeadline=Date(timeIntervalSinceNow:4)
        while app.findController.visible {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01));app.findController.poll();precondition(Date()<copyDeadline)}
        precondition(app.multiController.state.current?.length==0 && app.multiController.state.selections.contains {$0.length>0})
        precondition(app.textView.validateUserInterfaceItem(NSMenuItem(title:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")))
        app.textView.copy(nil);precondition(app.clipboard.string(forType:.string)=="cat\ncat\nCAT\ncat")
        selectAll();let beforeEscape=app.document.revision;app.textView.cancelOperation(nil)
        precondition(!app.multiController.active && app.textView.secondaryCarets.isEmpty && app.document.revision==beforeEscape)
        selectAll();app.textView.setMarkedText("に",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        precondition(!app.multiController.active && app.document.text=="に 👩‍💻\r\ncat CAT cat" && app.document.text==app.textView.string)
        app.textView.unmarkText()
        // Composition uses the ordinary primary-cursor path; its history granularity is a separate IME gate.
        selectAll(NSRange(location:0,length:1));app.newPrivateScratch();precondition(!app.multiController.active)
        let privateText="PRIVATE_MULTI_FIXTURE x x"
        precondition(app.document.replace(NSRange(location:0,length:0),with:privateText));app.textView.string=app.document.text
        let privateRange=(privateText as NSString).range(of:"x");selectAll(privateRange)
        precondition(app.multiController.state.selections.count==2);app.textView.insertText("Y",replacementRange:NSRange(location:NSNotFound,length:0))
        precondition(app.document.text=="PRIVATE_MULTI_FIXTURE Y Y" && app.session.isPrivate)
        precondition(app.recovery!.flush(app.session.checkpoint()))
        precondition(!String(decoding:try! Data(contentsOf:app.recovery!.fileURL),as:UTF8.self).contains("PRIVATE_MULTI_FIXTURE"))
        print("Multiple selections native smoke passed: next/all, quiet selection, grouped typing, copy/cut/paste, grapheme deletion, navigation, Find regex, Undo/Redo, Escape, tab/private recovery, light/dark narrow/wide rendering")
    }

    static func toolsSmokeTest() {
        let app=AppDelegate(clipboard:NSPasteboard(name:NSPasteboard.Name("vibechar-tools-smoke-\(UUID().uuidString)")))
        app.makeWindow(restoreFrame:false)
        defer { app.toolPalette?.close(); app.syntaxWork?.cancel(); app.syntaxTimer?.invalidate(); app.window.delegate=nil; app.window.close(); app.clipboard.clearContents() }
        precondition(app.document.replace(NSRange(location:0,length:0),with:"👩‍💻\nb\r\na\r\ntail"))
        app.document.markSaved(); app.showActiveBuffer(); app.makeMenus()
        var applied: (NSRange,Bool)?
        func palette(_ target:NSRange, selected:Bool=true) -> ToolPalette {
            applied=nil
            let palette=ToolPalette(document:app.document,target:target,selectedText:selected,scope:"Selection · private · local text tools",didDismiss:{},didApply:{ applied=($0,$1) })
            _=palette.view
            return palette
        }
        func run(_ palette:ToolPalette,_ query:String) {
            palette.search.stringValue=query; palette.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification)); palette.runSelected()
            let deadline=Date(timeIntervalSinceNow:3)
            while applied==nil { RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01)); palette.poll(); precondition(Date()<deadline,"Tool must finish") }
        }
        let target=NSRange(location:6,length:4)
        let sort=palette(target)
        let revision=app.document.revision
        sort.search.stringValue="sort"; sort.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        precondition(app.document.revision==revision && !app.document.isDirty)
        run(sort,"sort")
        precondition(applied!.1 && applied!.0==target && app.document.text=="👩‍💻\na\r\nb\r\ntail")
        app.applyHistory(redo:false); precondition(app.document.text=="👩‍💻\nb\r\na\r\ntail" && !app.document.isDirty)
        run(palette(NSRange(location:0,length:(app.document.text as NSString).length),selected:false),"trim")
        precondition(!applied!.1 && !app.document.isDirty)
        let dismissed=palette(target)
        dismissed.search.stringValue="unknown tool"; dismissed.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification)); dismissed.runSelected()
        precondition(dismissed.choices.isEmpty && applied==nil)
        dismissed.close(); precondition(dismissed.search.stringValue.isEmpty && !app.document.isDirty)
        let output=ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"].map { URL(fileURLWithPath:$0,isDirectory:true) }
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            let picker=palette(target); picker.view.appearance=NSAppearance(named:appearance)
            for subview in picker.view.subviews { precondition(picker.view.bounds.contains(subview.frame)) }
            if let output {
                try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                picker.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let bitmap=picker.view.bitmapImageRepForCachingDisplay(in:picker.view.bounds)!
                    picker.view.cacheDisplay(in:picker.view.bounds,to:bitmap)
                    try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("text-tools-\(name).png"))
                }
            }
            picker.close()
        }
        app.newPrivateScratch()
        precondition(app.document.replace(NSRange(location:0,length:0),with:"{\"n\":1e400,\"x\":[]}"))
        app.textView.string=app.document.text
        run(palette(NSRange(location:0,length:(app.document.text as NSString).length),selected:false),"format")
        precondition(app.session.isPrivate && app.document.text.contains("  \"n\": 1e400,"))
        let invalid=RustTool(app.document,range:NSRange(location:0,length:(app.document.text as NSString).length),command:999)!
        precondition(invalid.poll() == -1 && !invalid.error.isEmpty)
        let stale=RustTool(app.document,range:NSRange(location:0,length:(app.document.text as NSString).length),command:2)!
        precondition(app.document.replace(NSRange(location:0,length:0),with:" "))
        let deadline=Date(timeIntervalSinceNow:3)
        while stale.poll()==0 { RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01)); precondition(Date()<deadline) }
        precondition(stale.apply(app.document)==nil)
        print("Text tools native smoke passed: command search, UTF-16 selection, exact scope, one Undo, no-op, cancel, private JSON, stale/error rejection, light/dark palette")
        ToolPalette.smokeTest()
    }

    static func findSmokeTest() {
        let app=AppDelegate(clipboard:.withUniqueName())
        app.makeWindow(restoreFrame:false)
        defer { app.findController.close(); app.syntaxWork?.cancel(); app.syntaxTimer?.invalidate(); app.window.delegate=nil; app.window.close(); app.clipboard.clearContents() }
        let sample="{\n  \"service\": \"pocket\",\n  \"host\": \"pocket.local\",\n  \"message\": \"Hello 👩‍💻 from Pocket\"\n}\r\n"
        precondition(app.document.replace(NSRange(location:0,length:0),with:sample))
        app.document.markSaved(); app.showActiveBuffer(); app.makeMenus(); app.openReplace()
        func query(_ needle:String,_ replacement:String,regex:Bool=false) {
            app.findBar.find.stringValue=needle; app.findBar.replacement.stringValue=replacement; app.findBar.regex.state=regex ? .on : .off
            app.findController.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
            let deadline=Date(timeIntervalSinceNow:5)
            while app.findController.frame == nil {
                RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01)); app.findController.poll()
                precondition(Date()<deadline,"Find worker must finish")
            }
        }
        query("service","service")
        let unchangedRevision=app.document.revision
        app.findController.apply(index:nil)
        precondition(app.document.revision==unchangedRevision && !app.document.isDirty && app.footer.status.stringValue=="Saved locally")
        query("pocket","vibechar")
        precondition(app.findController.frame!.matches.count==3 && app.findController.frame!.changed==3)
        precondition(app.document.text==sample && !app.document.isDirty)
        precondition(app.footer.status.stringValue=="Saved locally")
        let syntaxDeadline=Date(timeIntervalSinceNow:5)
        while app.syntaxFrame?.language != "JSON" {
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01));app.pollSyntax()
            precondition(Date()<syntaxDeadline)
        }
        app.findController.move(1)
        precondition(app.textView.selectedRange()==app.findController.frame!.matches[1].range)
        let output=ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"].map {URL(fileURLWithPath:$0,isDirectory:true)}
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            app.window.appearance=NSAppearance(named:appearance)
            for width in [420,880] {
                app.window.setContentSize(NSSize(width:width,height:600)); app.window.layoutIfNeeded();app.header.needsLayout=true;app.header.needsDisplay=true; app.window.contentView!.layoutSubtreeIfNeeded(); app.findBar.layoutSubtreeIfNeeded(); app.findController.paint()
                let controls=app.findBar.subviews.compactMap {$0 as? NSControl}.filter {!$0.isHidden}
                for (i,control) in controls.enumerated() {
                    precondition(app.findBar.bounds.contains(control.frame),"Find controls must fit")
                    for other in controls.dropFirst(i+1) { precondition(!control.frame.intersects(other.frame),"Find controls must not overlap") }
                }
                if let output {
                    let view=app.window.contentView!
                    app.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                        view.cacheDisplay(in:view.bounds,to:bitmap)
                        try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("find-\(name)-\(width).png"))
                    }
                }
            }
        }
        let serial=app.findController.frame!.serial
        app.findController.apply(index:nil,serial:serial)
        let replaced=sample.replacingOccurrences(of:"pocket",with:"vibechar",options:.caseInsensitive)
        precondition(app.document.text==replaced && app.textView.string==replaced && app.document.isDirty)
        app.undoEdit(); precondition(app.document.text==sample && !app.document.isDirty)
        app.redoEdit(); precondition(app.document.text==replaced)
        query("[","x",regex:true); precondition(app.findController.frame!.error != nil && !app.findBar.all.isEnabled)
        query("vibechar","$0!",regex:true)
        let stale=app.findController.frame!.serial
        app.textView.insertText("!",replacementRange:NSRange(location:0,length:0))
        let afterEdit=app.document.text
        app.findController.apply(index:nil,serial:stale); precondition(app.document.text==afterEdit)
        app.newPrivateScratch(); precondition(!app.findController.visible)
        app.textView.insertText("PRIVATE_FIND_FIXTURE x x",replacementRange:NSRange(location:NSNotFound,length:0))
        app.openReplace(); app.findBar.sensitive.state = .on; query("x","y"); app.findController.apply(index:nil)
        precondition(app.document.text=="PRIVATE_FIND_FIXTURE y y")
        app.undoEdit(); precondition(app.document.text=="PRIVATE_FIND_FIXTURE x x")
        app.textView.cancelOperation(nil); precondition(!app.findController.visible)
        print("Find/replace native smoke passed: local matching, counts, navigation, preview plan, one Undo, stale/error rejection, private, light/dark narrow/wide layout")
    }

    static func inputSmokeTest() {
        let app = AppDelegate(clipboard: .withUniqueName())
        app.makeWindow(restoreFrame: false)
        app.showActiveBuffer()
        defer { app.closeAllAgentAccess(); app.clipboard.clearContents(); app.window.delegate = nil; app.window.close() }
        func type(_ text: String) {
            for character in text { app.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        func check(_ text: String) {
            precondition(app.document.text == text && app.textView.string == text, "Native input and shared history must stay identical")
        }
        let unicode = "Привет 👩‍💻e\u{301}"
        type(unicode); check(unicode)
        app.undoEdit(); check("")
        app.redoEdit(); check(unicode)
        type("!"); app.undoEdit(); check(unicode)
        app.newScratch(); type("abc👩‍💻")
        app.textView.deleteBackward(nil); app.textView.deleteBackward(nil); check("ab")
        app.undoEdit(); check("abc👩‍💻")
        app.redoEdit(); check("ab")
        app.undoEdit()
        app.textView.setSelectedRange(NSRange(location: 0, length: 0))
        app.textView.deleteForward(nil); app.textView.deleteForward(nil); check("c👩‍💻")
        app.undoEdit(); check("abc👩‍💻")
        app.newScratch(); type("ab")
        app.clipboard.clearContents(); app.clipboard.setString("P", forType: .string)
        precondition(app.textView.readSelection(from: app.clipboard))
        check("abP"); type("cd"); check("abPcd")
        app.undoEdit(); check("abP")
        app.undoEdit(); check("ab")
        app.undoEdit(); check("")
        app.newScratch(); type("ab")
        app.textView.setSelectedRange(NSRange(location: 0, length: 0))
        app.textView.setSelectedRange(NSRange(location: 2, length: 0))
        type("cd"); app.undoEdit(); check("ab")
        app.newScratch(); type("hello")
        app.textView.setSelectedRange(NSRange(location: 0, length: 5))
        type("x"); type("y"); app.undoEdit(); check("x")
        app.undoEdit(); check("hello")
        app.newScratch(); type("abcdef")
        app.textView.setSelectedRange(NSRange(location: 2, length: 2))
        app.textView.deleteBackward(nil); check("abef")
        app.textView.deleteBackward(nil); check("aef")
        app.undoEdit(); check("abef")
        app.undoEdit(); check("abcdef")
        app.newScratch(); type("a"); app.textView.insertNewline(nil); type("b")
        app.undoEdit(); check("a\n")
        app.undoEdit(); check("a")
        app.undoEdit(); check("")
        app.newScratch(); type("saved"); app.document.markSaved(); type("new")
        app.undoEdit(); check("saved"); precondition(!app.document.isDirty)
        app.undoEdit(); check(""); precondition(app.document.isDirty)
        app.redoEdit(); check("saved"); precondition(!app.document.isDirty)
        app.newScratch(); let left = app.session.active; type("left")
        app.newScratch(); let right = app.session.active; type("right")
        app.switchBuffer(to: left); type("!"); app.undoEdit(); check("left")
        app.undoEdit(); check("")
        app.switchBuffer(to: right); check("right"); app.undoEdit(); check("")
        print("Grouped input native smoke passed: typing, Unicode deletion, isolated paste, cursor/selection, newline, save, tab boundaries")
    }

    static func saveAsSmokeTest() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-save-as-\(UUID().uuidString)", isDirectory: true)
        let app = AppDelegate(clipboard: .withUniqueName())
        app.recovery = try! SessionRecovery(directory: root)
        app.makeWindow(restoreFrame: false)
        defer {
            app.pendingSave?.cancel()
            app.saveGeneration &+= 1
            app.window.delegate = nil
            app.window.close()
            app.recovery = nil
            app.clipboard.clearContents()
            try! FileManager.default.removeItem(at: root)
        }
        app.makeMenus()
        let saveAs = NSApp.mainMenu!.items.first { $0.title == "File" }!.submenu!.items.first { $0.action == #selector(saveFileAs) }!
        precondition(saveAs.keyEquivalent == "s" && saveAs.keyEquivalentModifierMask == [.command, .shift] && saveAs.target === app)
        let original = root.appendingPathComponent("original.txt")
        let renamed = root.appendingPathComponent("копия.txt")
        let fixture = "Save As · Привет 👩‍💻\r\n"
        try! fixture.write(to: original, atomically: true, encoding: .utf8)
        precondition(app.document.replace(NSRange(location: 0, length: 0), with: fixture))
        app.session.completeSave(to: original)
        precondition(app.document.replace(NSRange(location: fixture.utf16.count, length: 0), with: "!"))
        app.session.rememberSelection(NSRange(location: 0, length: 1))
        app.showActiveBuffer()
        let textBeforeSave = app.document.text
        var asked = false
        try! app.performSave(alwaysChooseDestination: true) { panel in
            asked = true
            precondition(panel.nameFieldStringValue == "original.txt")
            precondition(panel.directoryURL?.resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
            return nil
        }
        precondition(asked && app.session.fileURL == original && app.document.isDirty && app.document.text == textBeforeSave)
        precondition(app.textView.selectedRange() == NSRange(location: 0, length: 1))
        let readOnly = root.appendingPathComponent("readonly.txt")
        let symlink = root.appendingPathComponent("link.txt")
        try! "preserve".write(to: readOnly, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        try! FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        for invalid in [root.appendingPathComponent("missing/file.txt"), readOnly, symlink] {
            do {
                try app.performSave(alwaysChooseDestination: true) { _ in invalid }
                preconditionFailure("A failed Save As must keep the original destination")
            } catch {}
            precondition(app.session.fileURL == original && app.document.isDirty && app.document.text == textBeforeSave)
        }
        try! "replace fixture".write(to: renamed, atomically: true, encoding: .utf8)
        try! app.performSave(alwaysChooseDestination: true) { _ in renamed }
        precondition(app.session.fileURL == renamed && !app.document.isDirty && app.session.count == 1)
        precondition(app.session.label(0) == "копия.txt" && app.textView.selectedRange() == NSRange(location: 0, length: 1))
        precondition(try! Data(contentsOf: original) == Data(fixture.utf8))
        precondition(try! Data(contentsOf: renamed) == Data((fixture + "!").utf8))
        precondition(try! String(contentsOf: readOnly, encoding: .utf8) == "preserve")
        precondition(app.document.history(redo: false) != nil && app.document.isDirty)
        precondition(app.document.history(redo: true) != nil && !app.document.isDirty)
        precondition(app.document.replace(NSRange(location: app.document.text.utf16.count, length: 0), with: "?"))
        app.showActiveBuffer()
        try! app.performSave(alwaysChooseDestination: false) { _ in preconditionFailure("Regular Save must reuse the new destination") }
        precondition(try! Data(contentsOf: renamed) == Data((fixture + "!?").utf8))
        precondition(try! Data(contentsOf: original) == Data(fixture.utf8))
        precondition(app.recovery!.flush(app.session.checkpoint()))
        let restored = RustSession()
        precondition(try! restored.restore(from: app.recovery!.fileURL))
        precondition(restored.fileURL == renamed && RustDocument(session: restored).text == fixture + "!?")
        print("Save As native smoke passed: menu, cancel/failure, replacement, Unicode/CRLF, selection/history, next save, restart")
    }

    static func closeSmokeTest() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-close-\(UUID().uuidString)", isDirectory: true)
        defer { try! FileManager.default.removeItem(at: root) }
        for action in ["shortcut", "tab-button", "private-empty", "multiple-tabs", "window-button"] {
            let app = AppDelegate(clipboard: .withUniqueName())
            app.recovery = try! SessionRecovery(directory: root.appendingPathComponent(action, isDirectory: true))
            app.makeWindow(restoreFrame: false)
            defer {
                app.pendingSave?.cancel()
                app.saveGeneration &+= 1
                app.window.delegate = nil
                app.window.close()
                app.recovery = nil
                app.clipboard.clearContents()
            }
            var closed = false
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: app.window, queue: .main) { _ in
                MainActor.assumeIsolated { closed = true }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            if action == "private-empty" {
                app.session.openPrivate()
                app.session.select(0)
                precondition(app.session.close(discard: true))
            } else if action == "tab-button" {
                let file = root.appendingPathComponent("saved.txt")
                try! "saved fixture".write(to: file, atomically: true, encoding: .utf8)
                precondition(app.document.replace(NSRange(location: 0, length: 0), with: "saved fixture"))
                app.session.completeSave(to: file)
            } else if action == "window-button" {
                precondition(app.document.replace(NSRange(location: 0, length: 0), with: "RECOVER_ON_WINDOW_CLOSE"))
            } else if action == "multiple-tabs" {
                app.session.open()
            }
            app.showActiveBuffer()
            precondition(app.recovery!.flush(app.session.checkpoint()))
            if action == "multiple-tabs" {
                app.closeScratch()
                precondition(!closed && !app.closingWindow && app.session.count == 1)
            }
            if action == "tab-button" {
                app.header.layoutSubtreeIfNeeded()
                let close = app.header.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.toolTip?.hasPrefix("Close saved.txt") == true }!
                close.performClick(nil)
            } else if action == "window-button" {
                app.window.performClose(nil)
            } else {
                app.closeScratch()
            }
            precondition(closed && app.closingWindow, "Closing the last tab must close its actual window")
            precondition(app.applicationShouldTerminateAfterLastWindowClosed(NSApp))
            precondition(app.applicationShouldTerminate(NSApp) == .terminateNow)
            let restored = RustSession()
            precondition(try! restored.restore(from: app.recovery!.fileURL))
            precondition(restored.count == 1 && !restored.isPrivate)
            precondition(RustDocument(session: restored).text == (action == "window-button" ? "RECOVER_ON_WINDOW_CLOSE" : ""))
        }
        print("Last-tab close native smoke passed: Cmd+W, tab close button, private empty, multiple tabs, quit recovery")
    }

    static func syntaxSmokeTest() {
        let app = AppDelegate(clipboard: .withUniqueName())
        app.makeWindow(restoreFrame: false)
        defer {
            app.syntaxWork?.cancel(); app.syntaxTimer?.invalidate()
            app.clipboard.clearContents(); app.window.delegate = nil; app.window.close()
        }
        let sample = "{\n  \"name\": \"Pocket 👩‍💻\",\n  \"local\": true,\n  \"languages\": 186,\n  \"features\": [\"Auto\", \"Private\", \"Secret Drop\"]\n}"
        precondition(app.document.replace(NSRange(location: 0, length: 0), with: sample))
        app.showActiveBuffer()
        let selection = NSRange(location: 12, length: 4)
        app.textView.setSelectedRange(selection)
        func waitForSyntax(_ language: String, automatic: Bool) {
            app.session.submitSyntax()
            let deadline = Date(timeIntervalSinceNow: 15)
            repeat {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                app.pollSyntax()
                precondition(Date() < deadline, "Syntax worker must finish")
            } while app.syntaxFrame?.complete != true || app.syntaxFrame?.language != language || app.syntaxFrame?.automatic != automatic
            precondition(app.textView.string == sample && app.document.text == sample)
            precondition(app.textView.selectedRange() == selection)
        }
        waitForSyntax("JSON", automatic: true)
        precondition(app.syntaxFrame!.spans.contains { $0.role == 2 })
        let revision = app.document.revision
        let output = ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        LanguagePicker.smokeTest(output: output)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            app.window.appearance = NSAppearance(named: appearance)
            for width in [420, 880] {
                app.window.setContentSize(NSSize(width: width, height: 600))
                app.window.layoutIfNeeded()
                app.window.contentView!.layoutSubtreeIfNeeded()
                app.paintSyntax()
                let stringSpan = app.syntaxFrame!.spans.first { $0.role == 2 }!
                precondition(app.textView.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: stringSpan.start, effectiveRange: nil) != nil)
                for isPrivate in [false, true] {
                    app.footer.privateTab = isPrivate
                    app.footer.agentUses = isPrivate ? 1 : nil
                    app.footer.layoutSubtreeIfNeeded()
                    let buttons = app.footer.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
                    for (index, button) in buttons.enumerated() {
                        precondition(app.footer.bounds.contains(button.frame), "Footer buttons must fit at narrow widths")
                        for other in buttons.dropFirst(index + 1) { precondition(!button.frame.intersects(other.frame)) }
                    }
                }
                app.footer.privateTab = false; app.footer.agentUses = nil
                app.footer.layoutSubtreeIfNeeded()
                if let output {
                    let view = app.window.contentView!
                    app.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("syntax-\(name)-\(width).png"))
                    }
                }
            }
        }
        precondition(app.session.setLanguage("Python"))
        waitForSyntax("Python", automatic: false)
        precondition(app.session.setLanguage(""))
        waitForSyntax("JSON", automatic: true)
        precondition(app.document.revision == revision)
        precondition(app.document.history(redo: false) != nil && app.document.text.isEmpty, "Syntax must not enter Undo")
        print("Smart syntax native smoke passed: Auto, manual pin, UTF-16 colors, selection/Undo, narrow private footer, light/dark")
    }

    // Exercise the real window composition without opening a window or recovery store.
    static func interfaceSmokeTest() {
        let app = AppDelegate(clipboard: .withUniqueName())
        app.makeWindow(restoreFrame: false)
        defer { app.closeAllAgentAccess(); app.clipboard.clearContents(); app.window.delegate = nil; app.window.close() }
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
                app.window.setFrame(NSRect(origin: app.window.frame.origin, size: NSSize(width: width, height: 600)), display: false)
                let view = app.window.contentView!
                app.window.layoutIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                view.superview?.layoutSubtreeIfNeeded()
                precondition(abs(view.bounds.width - CGFloat(width)) < 1, "Window must reach the requested width")
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
        app.newPrivateScratch()
        let privateFixture = "PRIVATE_INTERFACE_FIXTURE"
        precondition(app.document.replace(NSRange(location: 0, length: 0), with: privateFixture))
        app.showActiveBuffer()
        precondition(app.session.isPrivate && app.session.hasPrivateText)
        precondition(app.footer.status.stringValue == "Private · not recovered")
        precondition(!app.window.title.contains(privateFixture))
        app.footer.showStatus("Saved locally")
        precondition(app.footer.status.stringValue == "Private · not recovered")
        app.newScratch()
        precondition(!app.session.isPrivate && app.session.hasPrivateText)
        precondition(!app.footer.status.stringValue.contains("Private"))
        let dropFixture = "NATIVE_DROP_FIXTURE_👩‍💻"
        app.clipboard.clearContents()
        app.clipboard.setString(dropFixture, forType: .string)
        app.pasteForAgent()
        precondition(app.session.isPrivate && app.document.text == dropFixture && app.session.dropActive)
        let instruction = app.clipboard.string(forType: .string)!
        precondition(!instruction.contains(dropFixture))
        var reference = instruction.components(separatedBy: "\n").first { $0.hasPrefix("vibechar://grant/") }!
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vibechar").path
        func useDrop(_ code: String) -> (Int32, String, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["run", reference, "--env", "DROP_TOKEN", "--", "/usr/bin/python3", "-c", code]
            var environment = ["PATH": "/usr/bin:/bin", "EXPECTED": dropFixture]
            if let directory = ProcessInfo.processInfo.environment["VIBECHAR_HANDOFF_DIR"] { environment["VIBECHAR_HANDOFF_DIR"] = directory }
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try! process.run()
            let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, stdout, stderr)
        }
        let exact = useDrop("import os; print(os.environ['DROP_TOKEN'] == os.environ['EXPECTED'])")
        precondition(exact.0 == 0 && exact.1 == "True\n" && exact.2.isEmpty)
        let masked = useDrop("import os,sys; print(os.environ['DROP_TOKEN']); print(os.environ['DROP_TOKEN'],file=sys.stderr); sys.exit(7)")
        precondition(masked.0 == 7 && masked.1 == "[REDACTED]\n" && masked.2 == "[REDACTED]\n")
        app.refreshDropStatus()
        precondition(app.footer.status.stringValue.contains("2 uses"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            app.window.appearance = NSAppearance(named: appearance)
            for width in [420, 880] {
                app.window.setFrame(NSRect(origin: app.window.frame.origin, size: NSSize(width: width, height: 600)), display: false)
                app.window.layoutIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                let view = app.window.contentView!
                view.layoutSubtreeIfNeeded()
                precondition(abs(view.bounds.width - CGFloat(width)) < 1, "Secret Drop must fit the actual narrow window")
                let buttons = app.footer.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0 !== app.footer.languageButton }
                precondition(buttons.count == 2 && !buttons[0].frame.intersects(buttons[1].frame))
                precondition(buttons.allSatisfy { app.footer.bounds.contains($0.frame) })
                for button in buttons {
                    let root = view.superview!
                    let center = root.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                    let hit = root.hitTest(center)
                    if hit !== button && hit?.isDescendant(of: button) != true {
                        FileHandle.standardError.write(Data("Agent control click intercepted (\(name), \(width)): \(button.title), frame \(button.frame), center \(center), hit \(String(describing: hit))\n".utf8))
                        preconditionFailure("Agent controls must receive clicks")
                    }
                }
                if let output {
                    app.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("secret-drop-\(name)-\(width).png"))
                    }
                }
            }
        }
        app.closeAgentAccess()
        precondition(!app.session.dropActive)
        precondition(useDrop("raise Exception('CHILD_MUST_NOT_START')").0 == 1)
        app.copyForAgent()
        reference = app.clipboard.string(forType: .string)!.components(separatedBy: "\n").first { $0.hasPrefix("vibechar://grant/") }!
        precondition(app.session.hasDropAccess)
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        precondition(!app.session.hasDropAccess)
        precondition(useDrop("raise Exception('CHILD_MUST_NOT_START')").0 == 1)
        let savedFolder = FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-private-save-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: savedFolder, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: savedFolder) }
        let savedFile = savedFolder.appendingPathComponent("saved.txt")
        app.copyForAgent()
        reference = app.clipboard.string(forType: .string)!.components(separatedBy: "\n").first { $0.hasPrefix("vibechar://grant/") }!
        do {
            try app.saveActive(to: savedFolder.appendingPathComponent("missing/file.txt"))
            preconditionFailure("A failed write must not complete a save")
        } catch {}
        precondition(app.session.isPrivate && app.session.fileURL == nil && app.document.isDirty)
        precondition(app.session.dropActive && useDrop("import os; print(bool(os.environ['DROP_TOKEN']))").1 == "True\n")
        let symlink = savedFolder.appendingPathComponent("link.txt")
        try! "preserve destination".write(to: savedFile, atomically: true, encoding: .utf8)
        try! FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: savedFile)
        do {
            try app.saveActive(to: symlink)
            preconditionFailure("A symlink must not complete a save")
        } catch {}
        precondition(app.session.isPrivate && app.session.dropActive)
        precondition(try! String(contentsOf: savedFile, encoding: .utf8) == "preserve destination")
        let countBeforeSave = app.session.count
        let selectionBeforeSave = app.textView.selectedRange()
        try! app.saveActive(to: savedFile)
        precondition(try! Data(contentsOf: savedFile) == Data(dropFixture.utf8))
        precondition(!app.session.isPrivate && !app.document.isDirty && !app.session.dropActive)
        precondition(app.session.count == countBeforeSave && app.textView.selectedRange() == selectionBeforeSave)
        precondition(app.session.fileURL == savedFile && app.session.label(app.session.active) == "saved.txt")
        precondition(!app.session.needsCloseConfirmation && !app.footer.status.stringValue.contains("Private"))
        precondition(app.footer.subviews.compactMap { $0 as? NSButton }.filter { $0 !== app.footer.languageButton }.allSatisfy { $0.isHidden })
        precondition(useDrop("raise Exception('CHILD_MUST_NOT_START')").0 == 1)
        let checkpointURL = savedFolder.appendingPathComponent("session.json")
        precondition(app.session.checkpoint().save(to: checkpointURL))
        let restored = RustSession()
        precondition(try! restored.restore(from: checkpointURL))
        precondition(!restored.isPrivate && restored.fileURL == savedFile)
        precondition(RustDocument(session: restored).text == dropFixture)
        precondition(app.document.replace(NSRange(location: dropFixture.utf16.count, length: 0), with: "!"))
        app.showActiveBuffer()
        app.saveFile() // A subsequent Cmd+S uses the attached file without a panel.
        precondition(try! Data(contentsOf: savedFile) == Data((dropFixture + "!").utf8))
        precondition(!app.document.isDirty && !app.session.isPrivate)
        print("Private save native smoke passed: failed/symlink saves stay private, successful save converts/revokes, recovery, repeat save")
        print("Secret Drop native smoke passed: clipboard fast path, exact injection, masking, exit status, Stop/quit")
        print("Pocket window smoke test passed: light/dark, narrow/wide, native/tab click targets, text/history")
    }
}

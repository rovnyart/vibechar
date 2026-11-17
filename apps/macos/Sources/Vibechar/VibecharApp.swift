import AppKit
import Darwin

@main
struct VibecharApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--smoke") }) {
            setbuf(stdout,nil); setbuf(stderr,nil)
            // Sheets require a launched application, including in a headless CI
            // fixture. No delegate is installed, so no user session is opened.
            NSApplication.shared.finishLaunching()
        }
        if CommandLine.arguments.contains("--profile-appkit") {
            AppDelegate.profileNativeEditing()
            return
        }
        if CommandLine.arguments.contains("--smoke-ai-settings") {
            aiSettingsSmokeTest()
            return
        }
        if CommandLine.arguments.contains("--smoke-rewrite") { rewriteSmokeTest(); return }
        if CommandLine.arguments.contains("--smoke-examples") { exampleSmokeTest(); return }
        if CommandLine.arguments.contains("--smoke-recipes") { recipeSmokeTest(); return }
        if CommandLine.arguments.contains("--smoke-updates") { AppDelegate.updatesSmokeTest(); return }
        if CommandLine.arguments.contains("--smoke-update-install") { AppDelegate.updateInstallationSmokeTest(); return }
        if CommandLine.arguments.contains("--smoke-launcher") { AppDelegate.launcherSmokeTest(); return }
        if CommandLine.arguments.contains("--smoke-first-presentation") {
            AppDelegate.firstPresentationSmokeTest()
            return
        }
        if CommandLine.arguments.contains("--smoke-editing") {
            AppDelegate.editingSmokeTest()
            return
        }
        if CommandLine.arguments.contains("--smoke-counters") {
            AppDelegate.countersSmokeTest()
            return
        }
        if CommandLine.arguments.contains("--smoke-large-text") {
            AppDelegate.largeTextSmokeTest();return
        }
        if CommandLine.arguments.contains("--profile-snapshots") {
            profileSnapshotCopies()
            return
        }
        if CommandLine.arguments.contains("--smoke-test") {
            snapshotCopySmokeTest()
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
            historyRetentionSmokeTest()

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
            AppDelegate.presentationHistorySmokeTest()
            AppDelegate.firstPresentationSmokeTest()
            AppDelegate.largeTextSmokeTest()
            AppDelegate.editingSmokeTest()
            AppDelegate.countersSmokeTest()
            AppDelegate.closeSmokeTest()
            AppDelegate.saveAsSmokeTest()
            AppDelegate.syntaxSmokeTest()
            AppDelegate.quietSelectionSmokeTest()
            AppDelegate.findSmokeTest()
            AppDelegate.toolsSmokeTest()
            AppDelegate.multicursorPasteSmokeTest()
            AppDelegate.multiSmokeTest()
            AppDelegate.launcherSmokeTest()
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
    private static func historyRetentionSmokeTest() {
        let document = RustDocument("")
        for index in 0..<1029 {
            precondition(document.replace(NSRange(location:index,length:0),with:"я"))
        }
        document.markSaved()
        for remaining in stride(from:1028,through:5,by:-1) {
            precondition(document.history(redo:false)==remaining && document.isDirty)
        }
        precondition(document.history(redo:false)==nil && document.text==String(repeating:"я",count:5))
        for _ in 0..<1024 {precondition(document.history(redo:true) != nil)}
        precondition(document.text==String(repeating:"я",count:1029) && !document.isDirty)
        precondition(document.history(redo:false) != nil)
        precondition(document.replace(NSRange(location:1028,length:0),with:"🦀"))
        precondition(document.history(redo:true)==nil && document.isDirty)
        precondition(document.history(redo:false)==1028)
        print("History retention native smoke passed: bounded steps, Unicode, exhausted Undo, saved-state Redo and divergent edits")
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
    private let aiSettingsFactory: (@MainActor () -> AISettingsWindowController)?
    private let commandWindow: @MainActor () -> NSWindow?
    private var aiSettings: AISettingsWindowController?
    private var rewriteWindow: RewriteWindowController?
    private let rewriteFactory: (@MainActor (RustSession, NSRange) throws -> RewriteModel)?
    private var exampleWindow: ExampleWindowController?
    private let exampleFactory: (@MainActor (RustSession, NSRange) throws -> ExampleModel)?
    private let recipeStore: RecipeStore
    private var recipeWindow: RecipeWindowController?
    private var pendingOpenFiles: [URL] = []
    private var commandInstallBusy = false
    private var fileURL: URL? { session.fileURL }
    private var window: NSWindow!
    private let textView = PocketTextView()
    private let header = PocketHeader()
    private let footer = PocketFooter()
    private let metrics=RustMetrics()
    private var metricsTimer:Timer?
    private var metricsPopover:NSPopover?
    private var lineNumbers:PocketLineNumbers?
    private var showLineNumbers=true
    private var stopping=false
    private let findBar = FindBar()
    private var toolPalette: ToolPalette?
    private lazy var multiController:MultiController = {
        let controller=MultiController(document:document,textView:textView,clipboard:clipboard)
        controller.didEdit={ [weak self] in
            guard let self else {return}
            self.refreshTitle();self.scheduleSessionSave();self.scheduleSyntax()
        }
        controller.didUpdate={ [weak self] state in
            guard let self else {return}
            self.footer.operationError=state.message
            self.footer.multiStatus=state.busy ? "Finding matches…" : nil
            self.updateStatistics()
            self.scheduleSessionSave(quiet:true)
        }
        return controller
    }()
    private lazy var findController: FindController = {
        let controller = FindController(bar: findBar,document: document,textView: textView)
        controller.didReplace = { [weak self] selection in
            guard let self else { return }
            self.textView.setPlainText(self.document.text)
            self.textView.setSelectedRange(selection)
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
    private var wrapLines = true
    private let budgetTypesetter=BudgetTypesetter()
    private var largeTextChoice=0 // Auto / On / Off, client-session preference.
    private var expandedLayoutRevision:UInt64?
    private var closingWindow = false
    private var updates: UpdateController?
    private var recovery: SessionRecovery?
    private var pendingSave: DispatchWorkItem?
    private var saveGeneration: UInt64 = 0
    private var dropTimer: Timer?
    private var syntaxTimer: Timer?
    private var syntaxWork: DispatchWorkItem?
    private var syntaxFrame: SyntaxFrame?
    private var hasSyntaxPaint=false
    private var syntaxSerial: UInt64 = 0
    private var syntaxGeneration: UInt64 = 0
    private var languagePopover: NSPopover?

    static func profileNativeEditing() {
        _ = NSApplication.shared
        func option(_ name:String,_ fallback:String)->String {
            guard let index=CommandLine.arguments.firstIndex(of:name),index+1<CommandLine.arguments.count else {return fallback}
            return CommandLine.arguments[index+1]
        }
        let mib=Int(option("--mib","1"))!, samples=Int(option("--samples","30"))!
        let kind=option("--kind","minified")
        precondition((1...10).contains(mib) && (1...30).contains(samples))
        let line="2026-11-12T00:00:00Z INFO synthetic request completed status=200 duration=12ms\n"
        let source=kind=="logs" ? String(repeating:line,count:mib*1024*1024/line.utf8.count) : "{\"data\":\""+String(repeating:"x",count:mib*1024*1024-11)+"\"}"
        let nativeStart=ContinuousClock.now
        let app=AppDelegate(clipboard:.withUniqueName());app.makeWindow(restoreFrame:false)
        if option("--wrap","auto")=="off" {app.toggleWrapLines()}
        app.largeTextChoice=["auto","on","off"].firstIndex(of:option("--large-mode","auto")) ?? 0
        let setupDuration=nativeStart.duration(to:.now)
        defer {
            app.syntaxWork?.cancel();app.syntaxGeneration &+= 1;app.syntaxTimer?.invalidate()
            app.pendingSave?.cancel();app.multiController.cancel();app.window.delegate=nil;app.window.close();app.clipboard.clearContents()
        }
        func phase(_ name:String) {FileHandle.standardError.write(Data("native-profile: \(name)\n".utf8))}
        func timed(_ action:()->Void)->Double {
            let start=ContinuousClock.now;action();let elapsed=start.duration(to:.now)
            return Double(elapsed.components.seconds)*1000+Double(elapsed.components.attoseconds)/1e15
        }
        let pasted=option("--load","open")=="paste"
        if pasted {app.showActiveBuffer();app.clipboard.setString(source,forType:.string)}
        else {app.session.open(source,url:URL(fileURLWithPath:kind=="logs" ? "/synthetic.log" : "/synthetic.json"))}
        phase("show")
        let screenStart=ContinuousClock.now
        let show=timed {
            if pasted {precondition(app.textView.readSelection(from:app.clipboard))} else {app.showActiveBuffer()}
            app.window.contentView!.layoutSubtreeIfNeeded()
        }
        app.syntaxWork?.cancel();app.syntaxGeneration &+= 1
        let surface=app.window.contentView!
        let bitmap=surface.bitmapImageRepForCachingDisplay(in:surface.bounds)!
        func draw() {surface.cacheDisplay(in:surface.bounds,to:bitmap)}
        phase("first-draw")
        let first=timed {draw()}
        let screenDuration=screenStart.duration(to:.now),nativeDuration=nativeStart.duration(to:.now)
        let initiallyBounded=app.budgetTypesetter.glyphBudget>0
        let returnToStart=pasted ? timed {app.textView.setSelectedRange(NSRange(location:0,length:0));app.textView.scrollRangeToVisible(app.textView.selectedRange());draw()} : 0
        phase("first-input-at-start")
        let firstInput=timed {app.textView.insertText("!",replacementRange:NSRange(location:NSNotFound,length:0));draw()}
        let firstDelete=timed {app.textView.deleteBackward(nil);draw()}
        precondition(app.document.text==source && app.textView.string==source)
        phase("jump-to-end")
        let end=(source as NSString).length
        let jump=timed {app.textView.setSelectedRange(NSRange(location:end,length:0));app.textView.scrollRangeToVisible(app.textView.selectedRange());draw()}
        var typing:[Double]=[],deletion:[Double]=[]
        for index in 0..<samples {
            phase("edit \(index+1)/\(samples)")
            typing.append(timed {app.textView.insertText("!",replacementRange:NSRange(location:NSNotFound,length:0));draw()})
            deletion.append(timed {app.textView.deleteBackward(nil);draw()})
        }
        precondition(app.document.text==source && app.textView.string==source)
        phase("undo-redo")
        let undo=timed {app.applyHistory(redo:false);draw()}
        precondition(app.document.text==source+"!")
        let redo=timed {app.applyHistory(redo:true);draw()}
        precondition(app.document.text==source && app.textView.string==source)
        let returnJump=timed {app.textView.setSelectedRange(NSRange(location:0,length:0));app.textView.scrollRangeToVisible(app.textView.selectedRange());draw()}
        let repeatJump=timed {app.textView.setSelectedRange(NSRange(location:end,length:0));app.textView.scrollRangeToVisible(app.textView.selectedRange());draw()}
        typing.sort();deletion.sort()
        let data:[String:Any]=["kind":kind,"bytes":source.utf8.count,"samples":samples,"wrapped":app.wrapLines,"large_mode":app.footer.largeText,"bounded_initial_layout":initiallyBounded,"load":pasted ? "paste" : "open",
            "return_to_start_ms":returnToStart,"return_jump_ms":returnJump,"repeat_jump_ms":repeatJump,
            "window_setup_ms":Double(setupDuration.components.seconds)*1000+Double(setupDuration.components.attoseconds)/1e15,
            "first_screen_ms":Double(screenDuration.components.seconds)*1000+Double(screenDuration.components.attoseconds)/1e15,
            "native_first_frame_ms":Double(nativeDuration.components.seconds)*1000+Double(nativeDuration.components.attoseconds)/1e15,
            "first_input_ms":firstInput,"first_backspace_ms":firstDelete,
            "show_ms":show,"first_draw_ms":first,"jump_ms":jump,
            "typing_p50_ms":typing[samples/2],"typing_p95_ms":typing[min(samples-1,samples*95/100)],
            "backspace_p50_ms":deletion[samples/2],"backspace_p95_ms":deletion[min(samples-1,samples*95/100)],
            "undo_ms":undo,"redo_ms":redo]
        print(String(decoding:try! JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }

    static func firstPresentationSmokeTest() {
        _ = NSApplication.shared
        final class GeometryObserver:NSObject,NSLayoutManagerDelegate {
            var loadedWidthChanges=0
            func layoutManager(_ layoutManager:NSLayoutManager,textContainer:NSTextContainer,didChangeGeometryFrom oldSize:NSSize) {
                if (layoutManager.textStorage?.length ?? 0)>0 && oldSize.width != textContainer.containerSize.width {
                    loadedWidthChanges+=1
                }
            }
        }
        for privateTab in [false,true] {
            let app=AppDelegate(clipboard:.withUniqueName());app.makeWindow(restoreFrame:false)
            let observer=GeometryObserver();app.textView.layoutManager?.delegate=observer
            defer {
                app.syntaxWork?.cancel();app.syntaxGeneration &+= 1;app.syntaxTimer?.invalidate()
                app.pendingSave?.cancel();app.multiController.cancel();app.window.delegate=nil;app.window.close();app.clipboard.clearContents()
            }
            let source="я👩‍💻e\u{301}\0"+String(repeating:"x",count:256*1024)+"\r\nlast"
            if privateTab {app.session.openPrivate();nativeSmokeInvariant(app.document.replace(NSRange(location:0,length:0),with:source))}
            else {app.session.open(source)}
            let index=app.session.active
            app.showActiveBuffer()
            func draw() {
                let surface=app.window.contentView!;surface.layoutSubtreeIfNeeded()
                let bitmap=surface.bitmapImageRepForCachingDisplay(in:surface.bounds)!
                surface.cacheDisplay(in:surface.bounds,to:bitmap)
            }
            func check(_ text:String) {nativeSmokeInvariant(app.document.text==text && app.textView.string==text)}
            func checkCaret() {
                let screen=app.textView.firstRect(forCharacterRange:app.textView.selectedRange(),actualRange:nil)
                let rect=app.textView.convert(app.window.convertFromScreen(screen),from:nil)
                nativeSmokeInvariant(app.textView.visibleRect.contains(NSPoint(x:rect.minX,y:rect.midY)),"Restored caret must be visible")
            }
            draw();check(source);checkCaret()
            nativeSmokeInvariant(observer.loadedWidthChanges==0,"Resolve the initial viewport before laying out loaded text")
            app.textView.insertText("!",replacementRange:NSRange(location:NSNotFound,length:0));draw();check("!"+source)
            app.applyHistory(redo:false);draw();check(source)
            app.applyHistory(redo:true);draw();check("!"+source)
            app.textView.deleteBackward(nil);draw();check(source)
            app.textView.setSelectedRange(NSRange(location:(source as NSString).length,length:0))
            app.textView.scrollRangeToVisible(app.textView.selectedRange());draw();checkCaret()
            app.newScratch();draw();check("");checkCaret()
            app.switchBuffer(to:index);draw();check(source);checkCaret()
            nativeSmokeInvariant(app.session.isPrivate==privateTab)
            app.textView.selectAll(nil)
            nativeSmokeInvariant(app.textView.selectedRange().length==(source as NSString).length)
            nativeSmokeInvariant(app.textView.writeSelection(to:app.clipboard,types:app.textView.writablePasteboardTypes),"Copy the full selection to an isolated pasteboard")
            nativeSmokeInvariant(app.clipboard.string(forType:.string)==source)
            app.textView.insertText("short\n",replacementRange:NSRange(location:NSNotFound,length:0));draw();check("short\n")
            app.applyHistory(redo:false);draw();check(source)
            app.applyHistory(redo:true);draw();check("short\n")
            app.applyHistory(redo:false);draw();check(source)
            let revision=app.document.revision
            for appearance in [NSAppearance.Name.aqua,.darkAqua] {
                app.window.appearance=NSAppearance(named:appearance)
                for width in [420,880] {
                    app.window.setContentSize(NSSize(width:width,height:600));draw();check(source)
                    nativeSmokeInvariant(app.document.revision==revision)
                }
            }
        }
        print("First presentation native smoke passed: stable initial width, Unicode/CRLF/NUL, first input/history, copy-all, tab/caret restoration, private, narrow and light/dark")
    }

    static func editingSmokeTest() {
        _ = NSApplication.shared
        let app=AppDelegate(clipboard:.withUniqueName());app.makeWindow(restoreFrame:false);app.makeMenus()
        defer {app.closeAllAgentAccess();app.syntaxWork?.cancel();app.syntaxTimer?.invalidate();app.multiController.cancel();app.clipboard.clearContents();app.window.delegate=nil;app.window.close()}
        func check(_ text:String) {nativeSmokeInvariant(app.document.text==text && app.textView.string==text,"Shared editing and native storage must agree")}
        func command(_ selector:Selector) {app.textView.doCommand(by:selector)}
        func toggleWrap() {
            let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command,.option],timestamp:0,windowNumber:app.window.windowNumber,context:nil,characters:"w",charactersIgnoringModifiers:"w",isARepeat:false,keyCode:13)!
            nativeSmokeInvariant(NSApp.mainMenu!.performKeyEquivalent(with:event),"Wrap shortcut must dispatch through the native menu")
        }
        let sample="  я👩‍💻\r\n\tb\r\nlast"
        app.session.open(sample);app.document.markSaved();app.showActiveBuffer()
        let end=(sample as NSString).range(of:"last").location
        app.textView.setSelectedRange(NSRange(location:0,length:end))
        command(#selector(NSResponder.insertTab(_:)));check("      я👩‍💻\r\n    \tb\r\nlast")
        let indentedSelection=app.textView.selectedRange()
        app.applyHistory(redo:false);check(sample);nativeSmokeInvariant(!app.document.isDirty)
        app.applyHistory(redo:true)
        app.textView.setSelectedRange(indentedSelection)
        command(#selector(NSResponder.insertBacktab(_:)));check(sample)
        app.textView.setSelectedRange(NSRange(location:1,length:0));command(#selector(NSResponder.insertTab(_:)))
        check("     я👩‍💻\r\n\tb\r\nlast");nativeSmokeInvariant(app.footer.position.stringValue=="1:5")
        app.applyHistory(redo:false);check(sample)
        app.textView.setSelectedRange(NSRange(location:8,length:0));command(#selector(NSResponder.insertNewline(_:)))
        check("  я👩‍💻\r\n  \r\n\tb\r\nlast");nativeSmokeInvariant(app.footer.position.stringValue=="2:3")
        app.applyHistory(redo:false);check(sample)

        let long=String(repeating:"  👩‍💻x",count:40)+"\r\nend"
        app.session.open(long);app.document.markSaved();app.showActiveBuffer()
        let selection=NSRange(location:40,length:8);app.textView.setSelectedRange(selection)
        let revision=app.document.revision
        let output=ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"].map {URL(fileURLWithPath:$0,isDirectory:true)}
        if let output {try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)}
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            app.window.appearance=NSAppearance(named:appearance)
            for width in [420,880] {
                app.window.setContentSize(NSSize(width:width,height:600));app.window.contentView!.layoutSubtreeIfNeeded()
                var heights:[CGFloat]=[]
                for wrapped in [true,false] {
                    if app.wrapLines != wrapped {toggleWrap()}
                    app.textView.layoutManager!.ensureLayout(for:app.textView.textContainer!)
                    let glyph=app.textView.layoutManager!.glyphIndexForCharacter(at:(long as NSString).range(of:"\r\n").location-1)
                    heights.append(app.textView.layoutManager!.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).minY)
                    check(long);nativeSmokeInvariant(app.document.revision==revision && !app.document.isDirty && app.textView.selectedRange()==selection)
                    nativeSmokeInvariant(app.textView.textContainer!.widthTracksTextView==wrapped && app.textView.enclosingScrollView!.hasHorizontalScroller == !wrapped)
                    let root=app.window.contentView!;root.layoutSubtreeIfNeeded()
                    nativeSmokeInvariant(app.footer.bounds.contains(app.footer.position.frame) && !app.footer.position.isHidden)
                    if let output {
                        app.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                            let bitmap=root.bitmapImageRepForCachingDisplay(in:root.bounds)!
                            root.cacheDisplay(in:root.bounds,to:bitmap)
                            try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("editing-\(wrapped ? "wrap" : "nowrap")-\(name)-\(width).png"))
                        }
                    }
                }
                nativeSmokeInvariant(heights[0]>heights[1],"Wrapping must change the actual native line geometry")
            }
        }
        app.session.open("short");app.showActiveBuffer()
        if app.wrapLines {toggleWrap()}
        app.window.setContentSize(NSSize(width:1600,height:600));app.window.contentView!.layoutSubtreeIfNeeded()
        nativeSmokeInvariant(app.textView.frame.width>=app.textView.enclosingScrollView!.contentView.bounds.width,"Unwrapped editor must fill an expanded viewport: frame \(app.textView.frame.width), viewport \(app.textView.enclosingScrollView!.contentView.bounds.width)")
        app.newPrivateScratch();app.textView.insertText("  foo\r\n\tfoo",replacementRange:NSRange(location:NSNotFound,length:0))
        let privateSource=app.document.text
        _=try! app.session.shareForAgent(executable:"/synthetic/vibechar");nativeSmokeInvariant(app.session.dropActive)
        let privateRevision=app.document.revision
        toggleWrap();nativeSmokeInvariant(app.session.dropActive && app.document.revision==privateRevision)
        app.textView.setSelectedRange(NSRange(location:2,length:3));app.selectAllOccurrences()
        let deadline=Date(timeIntervalSinceNow:5)
        while app.multiController.state.busy {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01));app.multiController.poll();nativeSmokeInvariant(Date()<deadline)}
        nativeSmokeInvariant(app.multiController.state.selections.count==2)
        command(#selector(NSResponder.insertTab(_:)));check("      foo\r\n    \tfoo");nativeSmokeInvariant(!app.session.dropActive)
        command(#selector(NSResponder.insertBacktab(_:)));check(privateSource)
        command(#selector(NSResponder.insertNewline(_:)));check("  \r\n  \r\n\t\r\n\t")
        app.applyHistory(redo:false);check(privateSource)
        print("Editing native smoke passed: shared Tab/Shift+Tab/Enter, UTF-16/CRLF, one Undo, position, actual wrap geometry, resize/light/dark, selections, multiple carets and private grant behavior")
    }

    static func presentationHistorySmokeTest() {
        let app=AppDelegate(clipboard:.withUniqueName());app.makeWindow(restoreFrame:false)
        defer {app.syntaxWork?.cancel();app.syntaxGeneration &+= 1;app.syntaxTimer?.invalidate();app.multiController.cancel();app.window.delegate=nil;app.window.close();app.clipboard.clearContents()}
        func check(_ expected:String) {
            precondition(app.document.text==expected && app.textView.string==expected)
            guard let storage=app.textView.textStorage,storage.length>0 else {return}
            for at in Set([0,storage.length/2,storage.length-1]) {
                let font=storage.attribute(.font,at:at,effectiveRange:nil) as? NSFont
                let paragraph=storage.attribute(.paragraphStyle,at:at,effectiveRange:nil) as? NSParagraphStyle
                precondition(font?.pointSize==app.fontSize && paragraph?.lineSpacing==6)
            }
        }
        for source in ["","я👩‍💻e\u{301}\0\r\n"] {
            app.session.open(source);app.showActiveBuffer()
            app.textView.setSelectedRange(NSRange(location:(source as NSString).length,length:0))
            app.textView.insertText("🦀",replacementRange:NSRange(location:NSNotFound,length:0));check(source+"🦀")
            app.fontSize=18;app.applyTypography()
            app.applyHistory(redo:false);check(source)
            app.applyHistory(redo:true);check(source+"🦀")
        }
        app.session.open();app.showActiveBuffer()
        let large=String(repeating:"Q",count:200*1024)
        app.textView.insertText(large,replacementRange:NSRange(location:NSNotFound,length:0));check(large)
        app.applyHistory(redo:false);check("")
        app.applyHistory(redo:true);check(large) // Large replacement uses the bounded snapshot fallback.
        app.textView.setPlainText("stale presentation")
        app.applyHistory(redo:false);check("")
        let invalid=HistoryUpdate(cursor:0,source_length:0,target_length:0,edits:[.init(start:1,length:0,text:"x")])
        precondition(!app.textView.applyHistoryUpdate(invalid) && app.textView.string.isEmpty)
        app.textView.setMarkedText("日本",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        precondition(app.textView.hasMarkedText())
        app.applyHistory(redo:false)
        precondition(!app.textView.hasMarkedText() && app.document.text==app.textView.string)
        let line=String(repeating:"x",count:32769)
        app.session.open(line+"\nshort");app.showActiveBuffer()
        precondition(app.textView.layoutManager?.allowsNonContiguousLayout==false)
        app.textView.setSelectedRange(NSRange(location:(line as NSString).length+1,length:0))
        precondition(app.textView.layoutManager?.allowsNonContiguousLayout==true)
        app.textView.setSelectedRange(NSRange(location:0,length:0))
        precondition(app.textView.layoutManager?.allowsNonContiguousLayout==false)
        app.textView.selectAll(nil);app.textView.insertText("short",replacementRange:NSRange(location:NSNotFound,length:0));check("short")
        precondition(app.textView.layoutManager?.allowsNonContiguousLayout==true)
        app.applyHistory(redo:false);check(line+"\nshort")
        precondition(app.textView.layoutManager?.backgroundLayoutEnabled==false)
        print("Presentation history native smoke passed: incremental edits, UTF-16, empty Redo, typography, fallback, marked text and layout policy")
    }

    init(clipboard: NSPasteboard = .general, aiSettingsFactory: (@MainActor () -> AISettingsWindowController)? = nil,
         commandWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
         rewriteFactory: (@MainActor (RustSession, NSRange) throws -> RewriteModel)? = nil,
         exampleFactory: (@MainActor (RustSession, NSRange) throws -> ExampleModel)? = nil,
         recipeStore: RecipeStore? = nil) {
        let session = RustSession()
        self.session = session
        document = RustDocument(session: session)
        self.clipboard = clipboard
        self.aiSettingsFactory = aiSettingsFactory
        self.commandWindow = commandWindow
        self.rewriteFactory = rewriteFactory
        self.exampleFactory = exampleFactory
        self.recipeStore = recipeStore ?? RecipeStore()
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
        let pending = pendingOpenFiles; pendingOpenFiles = []
        for url in pending { do { try openRequestedFile(url) } catch { NSApp.presentError(error) } }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        let updater = UpdateController()
        connectUpdates(updater)
        updater.start()
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
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.layoutManager?.backgroundLayoutEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self
        budgetTypesetter.owner=textView.layoutManager
        textView.layoutManager?.typesetter=budgetTypesetter
        textView.onBreakUndoGroup = { [weak self] in self?.document.breakUndoGroup() }
        textView.onWillSelect={ [weak self] offset in self?.updateLayoutPolicy(at:offset) }
        textView.onWordSelection={ [weak self] offset in
            guard let self,self.document.isLarge || self.document.lineLength(at:offset)>32768 else {return nil}
            if let range=self.document.wordRange(at:offset) {return range}
            self.footer.operationError="Long line · drag to select a fragment"
            return NSRange(location:offset,length:0)
        }
        textView.onEditingAction = { [weak self] action in self?.performEditing(action) ?? false }
        textView.setAccessibilityLabel("Text editor")
        textView.setAccessibilityHelp("Type or paste text. Command-T creates a tab. Command-S saves a file.")
        applyTypography()

        let scroll = PocketEditorScrollView()
        scroll.hasVerticalScroller = true
        // A classic scroller changes the text width when it first appears. Keep
        // its space reserved so loading a giant paragraph never relays it out.
        scroll.autohidesScrollers = NSScroller.preferredScrollerStyle == .overlay
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(syntaxViewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.documentView = textView
        let gutter=PocketLineNumbers(scroll:scroll,editor:textView,document:document)
        lineNumbers=gutter;scroll.verticalRulerView=gutter;scroll.hasVerticalRuler=true;scroll.rulersVisible=true
        scroll.hasHorizontalRuler=false
        gutter.onSelect={ [weak self] line in
            guard let self,self.multipleInputReady(),let range=self.document.lineRange(line) else {return}
            self.multiController.cancel();self.textView.setSelectedRange(range);self.window.makeFirstResponder(self.textView)
        }
        scroll.backgroundColor = PocketPalette.canvas
        scroll.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        header.onSelect = { [weak self] in self?.switchBuffer(to: $0) }
        header.onClose = { [weak self] in self?.closeBuffer(at: $0) }
        header.onNew = { [weak self] in self?.newScratch() }
        header.onUpdate = { [weak self] in self?.updates?.activate() }
        footer.onGive = { [weak self] in self?.copyForAgent() }
        footer.onStop = { [weak self] in self?.closeAgentAccess() }
        footer.onLanguage = { [weak self] in self?.showLanguagePicker() }
        footer.onMetrics={ [weak self] anchor in self?.showStatistics(relativeTo:anchor) }
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
        // Resolve the viewport while storage is empty. Resizing a text container
        // for the first time after loading a giant paragraph forces full layout.
        content.layoutSubtreeIfNeeded()
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
        lineNumbers?.refresh()
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
        addItem("Settings…", action: #selector(showAISettings), key: ",", to: appMenu)
        addItem("Install vc Command…",action: #selector(installCommand),key: "",to: appMenu)
        addItem("Check for Updates…",action: #selector(checkForUpdates),key: "",to: appMenu)
        addItem("Automatically Check for Updates",action: #selector(toggleUpdateChecks),key: "",to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit vibechar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu("vibechar", submenu: appMenu, to: menu)
        let file = NSMenu(title: "File")
        addItem("New Tab", action: #selector(newScratch), key: "t", to: file)
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
        buffers.addItem(.separator())
        for number in 1...9 {
            let item = NSMenuItem(title: number == 9 ? "Last Tab" : "Tab \(number)", action: #selector(selectNumberedBuffer(_:)), keyEquivalent: String(number))
            item.tag = number
            item.target = self
            buffers.addItem(item)
        }
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
        let rewriteItem = NSMenuItem(title: "Rewrite Selection…", action: #selector(openRewrite), keyEquivalent: "k")
        rewriteItem.keyEquivalentModifierMask = [.command,.shift]; rewriteItem.target = self; edit.addItem(rewriteItem)
        let exampleItem = NSMenuItem(title: "Do the Rest…",action: #selector(openExample),keyEquivalent: "k")
        exampleItem.keyEquivalentModifierMask = [.command,.option]; exampleItem.target = self; edit.addItem(exampleItem)
        let recipesItem = NSMenuItem(title: "Saved Recipes…",action: #selector(openRecipes),keyEquivalent: "r")
        recipesItem.keyEquivalentModifierMask = [.command,.option]; recipesItem.target = self; edit.addItem(recipesItem)
        addItem("Find…",action:#selector(openFind),key:"f",to:edit)
        let replace = NSMenuItem(title:"Find and Replace…",action:#selector(openReplace),keyEquivalent:"f")
        replace.keyEquivalentModifierMask = [.command,.option]; replace.target=self; edit.addItem(replace)
        addItem("Find Next",action:#selector(findNext),key:"g",to:edit)
        let previousMatchItem = NSMenuItem(title:"Find Previous",action:#selector(findPrevious),keyEquivalent:"g")
        previousMatchItem.keyEquivalentModifierMask = [.command,.shift]; previousMatchItem.target=self; edit.addItem(previousMatchItem)
        addMenu("Edit", submenu: edit, to: menu)
        let view = NSMenu(title: "View")
        let numbers=NSMenuItem(title:"Line Numbers",action:#selector(toggleLineNumbers),keyEquivalent:"n")
        numbers.keyEquivalentModifierMask=[.command,.option];numbers.target=self;view.addItem(numbers)
        let wrap=NSMenuItem(title:"Wrap Lines",action:#selector(toggleWrapLines),keyEquivalent:"w")
        wrap.keyEquivalentModifierMask=[.command,.option];wrap.target=self;view.addItem(wrap)
        let largeMenu=NSMenu(title:"Large Text Mode")
        for (tag,title) in ["Automatic","On","Off"].enumerated() {
            let item=NSMenuItem(title:title,action:#selector(changeLargeTextMode(_:)),keyEquivalent:"");item.tag=tag;item.target=self;largeMenu.addItem(item)
        }
        addMenu("Large Text Mode",submenu:largeMenu,to:view)
        view.addItem(.separator())
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
        if accepted {updateLayoutPolicy(at:affectedCharRange.location+replacementString.utf16.count)}
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
        guard !textView.isInstallingText else {return}
        updateLayoutPolicy(at:textView.selectedRange().location)
        multiController.selectionChanged()
        updatePosition()
        if !textView.isPerformingEdit && !multiController.syncing {
            document.breakUndoGroup()
            scheduleSessionSave(quiet: true)
        }
    }

    private func performEditing(_ action:UInt32)->Bool {
        if textView.hasMarkedText() {return false}
        guard multipleInputReady() else {return true}
        guard let update=document.editing(action,range:textView.selectedRange()) else {NSSound.beep();return true}
        if !textView.applyHistoryUpdate(update.history) {textView.setPlainText(document.text)}
        textView.setSelectedRange(update.selection)
        textView.scrollRangeToVisible(NSRange(location:update.history.cursor,length:0))
        updatePosition()
        if update.changed {textDidChange(Notification(name:NSText.didChangeNotification))}
        return true
    }
    private func updatePosition() {
        let offset=multiController.state.current?.head ?? textView.selectedRange().location
        if let (line,column)=document.position(at:offset) {footer.showPosition(line:line,column:column)}
        lineNumbers?.activeLine=max(0,document.lineIndex(at:offset))
        lineNumbers?.refresh();updateStatistics()
    }
    private func updateStatistics() {
        guard !stopping else {return}
        let ranges=multiController.active ? multiController.state.selections.map(\.range) : [textView.selectedRange()]
        metrics.submit(document,ranges:ranges);refreshStatistics()
    }
    private func refreshStatistics() {
        let frame=metrics.frame(document);footer.showMetrics(frame)
        if let controller=metricsPopover?.contentViewController as? MetricsPopover {controller.update(frame)}
        if frame?.busy==true {
            if metricsTimer==nil {metricsTimer=Timer.scheduledTimer(withTimeInterval:0.025,repeats:true) { [weak self] timer in
                MainActor.assumeIsolated {guard let self else {timer.invalidate();return};self.refreshStatistics()}
            }}
        } else {metricsTimer?.invalidate();metricsTimer=nil}
    }
    private func showStatistics(relativeTo anchor:NSView) {
        metricsPopover?.performClose(nil)
        let popover=NSPopover();popover.behavior = .transient;popover.animates=false
        popover.contentViewController=MetricsPopover(metrics.frame(document))
        metricsPopover=popover;popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.maxY)
    }
    @objc private func toggleLineNumbers() {
        showLineNumbers.toggle();textView.enclosingScrollView?.rulersVisible=showLineNumbers
        textView.scrollRangeToVisible(NSRange(location:textView.selectedRange().location,length:0))
    }
    @objc private func toggleWrapLines() {
        wrapLines.toggle()
        expandedLayoutRevision=nil
        updateLayoutPolicy(at:textView.selectedRange().location)
        guard let scroll=textView.enclosingScrollView,let container=textView.textContainer else {return}
        textView.minSize=NSSize(width:wrapLines ? 0 : scroll.contentView.bounds.width,height:0)
        textView.isHorizontallyResizable = !wrapLines
        textView.autoresizingMask = wrapLines ? [.width] : []
        container.widthTracksTextView=wrapLines
        if wrapLines {
            textView.setFrameSize(NSSize(width:scroll.contentView.bounds.width,height:textView.frame.height))
        }
        container.containerSize=NSSize(width:wrapLines ? max(1,scroll.contentView.bounds.width-2*textView.textContainerInset.width) : CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = !wrapLines
        textView.scrollRangeToVisible(NSRange(location:textView.selectedRange().location,length:0))
        textView.needsDisplay=true
    }

    private func updateLayoutPolicy(at position:Int) {
        let length=document.lineLength(at:position)
        guard length>=0 else {return}
        // AppKit's noncontiguous layout helps short paragraphs but makes editing
        // a giant wrapped paragraph slower. Choose from Rope metadata, not a scan.
        let large=largeTextChoice==1 || largeTextChoice==0 && document.isLarge
        let lineStart=document.lineRange(document.lineIndex(at:position))?.location ?? position
        let nativeBudget=large && wrapLines ? document.nativeParagraphBudget : 0
        // In Auto, a distant reveal/paste uses one native paragraph context,
        // avoiding repeated prefix work through many bounded chunks.
        let distant=largeTextChoice==0 && nativeBudget>0 && position-lineStart>=nativeBudget
        if distant {expandedLayoutRevision=document.revision}
        let expanded=largeTextChoice==0 && expandedLayoutRevision==document.revision
        let budget=expanded ? 0 : nativeBudget
        if budgetTypesetter.glyphBudget != budget {
            budgetTypesetter.glyphBudget=budget
            if let storage=textView.textStorage {
                textView.layoutManager?.invalidateLayout(forCharacterRange:NSRange(location:0,length:storage.length),actualCharacterRange:nil)
            }
        }
        footer.largeText=large
        footer.largeTextNote = !wrapLines ? "No wrap uses standard native layout." : expanded ? "Adaptive native layout · full paragraph context prepared." : budget==0 && large ? "Standard layout preserves bidirectional paragraph context." : "Wrapped paragraphs use bounded layout; first distant navigation can take longer."
        // Partial layout keeps the first bounded window responsive. Beyond it,
        // contiguous layout preserves the faster native tail-edit/history path.
        let partial=length>=0 && (length<=32768 || budget>0 && position-lineStart<budget)
        if textView.layoutManager?.allowsNonContiguousLayout != partial {
            textView.layoutManager?.allowsNonContiguousLayout=partial
        }
    }
    @objc private func changeLargeTextMode(_ sender:NSMenuItem) {
        guard (0...2).contains(sender.tag) else {return}
        largeTextChoice=sender.tag;expandedLayoutRevision=nil;updateLayoutPolicy(at:textView.selectedRange().location)
        textView.scrollRangeToVisible(NSRange(location:textView.selectedRange().location,length:0));textView.needsDisplay=true
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
    @objc private func syntaxViewportChanged() {
        if !wrapLines,let scroll=textView.enclosingScrollView {
            let width=scroll.contentView.bounds.width
            if textView.minSize.width != width {textView.minSize=NSSize(width:width,height:0)}
            if textView.frame.width<width {textView.setFrameSize(NSSize(width:width,height:textView.frame.height))}
        }
        lineNumbers?.needsDisplay=true;paintSyntax();findController.paint();multiController.paint()
    }
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
        let target=selected ? selection : NSRange(location:0,length:textView.textStorage?.length ?? 0)
        let scope="\(selected ? "Selection" : "Whole tab") · \(session.isPrivate ? "private · " : "")local text tools"
        let palette=ToolPalette(document:document,target:target,selectedText:selected,scope:scope,didDismiss:{ [weak self] in
            self?.toolPalette=nil; self?.window.makeFirstResponder(self?.textView)
        },didApply:{ [weak self] range,changed in
            guard let self else { return }
            self.toolPalette=nil
            if changed {
                self.footer.operationError=nil
                self.textView.setPlainText(self.document.text)
                self.textView.setSelectedRange(range); self.textView.scrollRangeToVisible(range)
                self.refreshTitle(); self.scheduleSessionSave(); self.scheduleSyntax()
            } else { self.footer.operationError="Already in shape · no changes" }
            self.window.makeFirstResponder(self.textView)
        })
        toolPalette=palette; palette.open(relativeTo:header)
    }
    @objc private func openRewrite() {
        guard multipleInputReady() else { return }
        guard !session.isPrivate else { footer.operationError = "Private tabs use local text tools. AI is disabled."; return }
        guard textView.selectedRange().length > 0, !multiController.active else { footer.operationError = "Select one text fragment to rewrite."; return }
        exampleWindow?.shutdown(); exampleWindow = nil
        rewriteWindow?.shutdown(); rewriteWindow = nil
        toolPalette?.close(); toolPalette = nil; findController.close()
        document.breakUndoGroup()
        do {
            let target = textView.selectedRange()
            let model = try rewriteFactory?(session,target) ?? RewriteModel(session: session,target: target)
            let controller = RewriteWindowController(model: model)
            rewriteWindow = controller
            controller.onSettings = { [weak self] in self?.showAISettings() }
            controller.onClose = { [weak self] in self?.rewriteWindow = nil }
            model.onApplied = { [weak self,weak controller] range,changed,target,text in
                guard let self else { return }
                self.presentGeneratedEdit(range: range,changed: changed,target: target,text: text)
                controller?.close(); self.rewriteWindow = nil
                self.window.makeKeyAndOrderFront(nil); self.window.makeFirstResponder(self.textView)
            }
            controller.present()
        } catch { footer.operationError = (error as? RewriteFailure)?.message ?? "Couldn't prepare this selection." }
    }
    @objc private func openExample() {
        guard multipleInputReady() else { return }
        guard !session.isPrivate else { footer.operationError = "Private tabs cannot teach AI examples."; return }
        guard textView.selectedRange().length > 0, !multiController.active else { footer.operationError = "Select two or more complete rows."; return }
        rewriteWindow?.shutdown(); rewriteWindow = nil; exampleWindow?.shutdown(); exampleWindow = nil
        toolPalette?.close(); toolPalette = nil; findController.close(); document.breakUndoGroup()
        do {
            let target = textView.selectedRange()
            let model = try exampleFactory?(session,target) ?? ExampleModel(session: session,target: target)
            presentExample(model)
        } catch { footer.operationError = (error as? RewriteFailure)?.message ?? "Couldn't prepare these rows." }
    }
    private func presentExample(_ model: ExampleModel) {
        let controller = ExampleWindowController(model: model); exampleWindow = controller
        controller.onSettings = { [weak self] in self?.showAISettings() }
        controller.onSave = { [recipeStore] name,rule in _ = try recipeStore.save(name: name,rule: rule) }
        controller.onClose = { [weak self] in self?.exampleWindow = nil }
        model.onApplied = { [weak self,weak controller] range,changed,target,text in
            guard let self else { return }
            self.presentGeneratedEdit(range: range,changed: changed,target: target,text: text)
            controller?.close(); self.exampleWindow = nil
            self.window.makeKeyAndOrderFront(nil); self.window.makeFirstResponder(self.textView)
        }
        controller.present()
    }
    @objc private func openRecipes() {
        guard multipleInputReady() else { return }
        guard !session.isPrivate else { footer.operationError = "Saved recipes are available in ordinary tabs."; return }
        if let recipeWindow { recipeWindow.present(); return }
        let controller = RecipeWindowController(store: recipeStore); recipeWindow = controller
        controller.onClose = { [weak self] in self?.recipeWindow = nil }
        controller.onRun = { [weak self,weak controller] recipe in
            guard let self, self.multipleInputReady() else { return }
            guard !self.session.isPrivate, !self.multiController.active, self.textView.selectedRange().length > 0 else {
                throw RewriteFailure(message: "Select complete lines in an ordinary tab first.")
            }
            let model = try ExampleModel(session: self.session,target: self.textView.selectedRange(),savedRecipe: recipe)
            self.rewriteWindow?.shutdown(); self.rewriteWindow = nil; self.exampleWindow?.shutdown(); self.exampleWindow = nil
            self.toolPalette?.close(); self.toolPalette = nil; self.findController.close(); self.document.breakUndoGroup()
            controller?.close(); self.recipeWindow = nil; self.presentExample(model)
        }
        controller.present()
    }
    private func presentGeneratedEdit(range: NSRange, changed: Bool, target: NSRange, text: String) {
        if changed {
            let sourceLength = textView.textStorage?.length ?? 0
            let update = HistoryUpdate(cursor: NSMaxRange(range),source_length: sourceLength,
                target_length: sourceLength-target.length+range.length,
                edits: [.init(start: target.location,length: target.length,text: text)])
            updateLayoutPolicy(at: NSMaxRange(range))
            if !textView.applyHistoryUpdate(update) { textView.setPlainText(document.text) }
            textView.setSelectedRange(range); textView.scrollRangeToVisible(range)
            textDidChange(Notification(name: NSText.didChangeNotification))
        } else { footer.operationError = "No changes proposed" }
    }
    @objc private func findNext() { if !findController.visible { openFind() } else { findController.move(1) } }
    @objc private func findPrevious() { if !findController.visible { openFind() } else { findController.move(-1) } }
    private func paintSyntax() {
        guard let layout = textView.layoutManager, let storage = textView.textStorage else { return }
        if hasSyntaxPaint {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            hasSyntaxPaint=false
        }
        guard let frame = syntaxFrame else {return}
        guard frame.revision == document.revision else { return }
        guard !frame.spans.isEmpty, let container = textView.textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let start = max(0, visible.location - 2048)
        let end = min(storage.length, NSMaxRange(visible) + 2048)
        let window = NSRange(location: start, length: max(0, end-start))
        for span in frame.spans {
            if span.start >= end { break }
            let range = NSIntersectionRange(window, NSRange(location: span.start, length: span.length))
            if range.length > 0 { layout.addTemporaryAttribute(.foregroundColor, value: SyntaxColors.color(span.role), forCharacterRange: range);hasSyntaxPaint=true }
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
        rewriteWindow?.model.sourceChanged()
        exampleWindow?.model.sourceChanged()
        updatePosition()
        window.title = "\(session.label(session.active)) — vibechar"
        window.isDocumentEdited = session.isModifiedFile(session.active)
        header.update(tabs: (0..<session.count).map {
            PocketTab(title: session.label($0), modifiedFile: session.isModifiedFile($0), isPrivate: session.isPrivate($0))
        }, active: session.active)
        footer.privateTab = session.isPrivate
        refreshDropStatus()
    }

    @objc private func undoEdit() {
        if let field=commandWindow()?.firstResponder as? NSTextView,field.isFieldEditor || commandWindow() === rewriteWindow?.window || commandWindow() === exampleWindow?.window { field.undoManager?.undo(); return }
        applyHistory(redo: false)
    }
    @objc private func redoEdit() {
        if let field=commandWindow()?.firstResponder as? NSTextView,field.isFieldEditor || commandWindow() === rewriteWindow?.window || commandWindow() === exampleWindow?.window { field.undoManager?.redo(); return }
        applyHistory(redo: true)
    }

    private func applyHistory(redo: Bool) {
        guard multipleInputReady() else {return}
        multiController.cancel()
        guard let update = document.historyUpdate(redo: redo) else { return }
        updateLayoutPolicy(at:update.cursor)
        if !textView.applyHistoryUpdate(update) {
            textView.setPlainText(document.text)
        }
        textView.setSelectedRange(NSRange(location: update.cursor, length: 0))
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
            try openRequestedFile(url)
        }
        catch { NSApp.presentError(error) }
    }

    private func openRequestedFile(_ requested: URL) throws {
        let url = requested.standardizedFileURL
        guard url.isFileURL else { throw RewriteFailure(message: "Choose a local text file.") }
        if window == nil { pendingOpenFiles.append(url); return }
        guard multipleInputReady() else { throw RewriteFailure(message: "Matching is finishing. Try opening the file again.") }
        for index in 0..<session.count where session.fileURL(index)?.standardizedFileURL == url {
            switchBuffer(to: index); window.makeKeyAndOrderFront(nil); return
        }
        let text = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url,encoding: .utf8) : ""
        session.rememberSelection(textView.selectedRange()); session.open(text,url: url)
        showActiveBuffer(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(textView)
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        do { for path in filenames { try openRequestedFile(URL(fileURLWithPath: path)) }; sender.reply(toOpenOrPrint: .success) }
        catch { sender.reply(toOpenOrPrint: .failure); NSApp.presentError(error) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let components = URLComponents(url: url,resolvingAgainstBaseURL: false),
                  components.scheme == "vibechar", components.host == "open",
                  let items = components.queryItems, items.count == 1,
                  items[0].name == "path", let path = items[0].value,
                  path.hasPrefix("/"), !path.contains("\0") else { continue }
            do { try openRequestedFile(URL(fileURLWithPath: path)) } catch { NSApp.presentError(error) }
        }
    }
    @objc private func installCommand() {
        guard !commandInstallBusy else { return }; commandInstallBusy = true
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vc")
        Task { [weak self] in
            let result = await Task.detached { () -> Result<String,Error> in
                do {
                    let task = Process(), pipe = Pipe(); task.executableURL = executable; task.arguments = ["--install"]
                    task.standardOutput = pipe; task.standardError = pipe
                    try task.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
                    let message = String(decoding: data,as: UTF8.self)
                    guard task.terminationStatus == 0 else { throw RewriteFailure(message: message) }
                    return .success(message)
                } catch { return .failure(error) }
            }.value
            guard let self else { return }; self.commandInstallBusy = false
            let alert = NSAlert()
            switch result {
            case .success(let message): alert.messageText = "vc is ready"; alert.informativeText = message
            case .failure(let error): alert.messageText = "Couldn't install vc"; alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
    }

    // Actual replacement/relaunch runs only on a disposable GitHub Mac runner.
    // Ordinary native fixtures never open the user's default recovery directory.
    static func updateInstallationSmokeTest() {
        let environment = ProcessInfo.processInfo.environment
        precondition(environment["GITHUB_ACTIONS"] == "true")
        guard let feed = environment["VIBECHAR_TEST_UPDATE_FEED"],
              let url = URL(string: feed), url.host == "127.0.0.1" else {
            preconditionFailure("Update fixture requires a loopback feed")
        }
        let app = AppDelegate(clipboard: .withUniqueName())
        app.recovery = try! SessionRecovery()
        precondition(!FileManager.default.fileExists(atPath: app.recovery!.fileURL.path))
        app.makeMenus(); app.makeWindow(restoreFrame: false); app.showActiveBuffer()
        app.textView.insertText("UPDATE_RECOVERY_FIXTURE 🦀\n",replacementRange: NSRange(location: NSNotFound,length: 0))
        app.window.makeKeyAndOrderFront(nil)
        let controller = UpdateController(feedOverride: feed)
        app.connectUpdates(controller)
        controller.onTestAvailable = { [weak app] in app?.header.updateButton.performClick(nil) }
        controller.start()
        NSApp.delegate = app
        DispatchQueue.main.async { controller.check() }
        withExtendedLifetime(app) { NSApp.run() }
    }

    static func updatesSmokeTest() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-update-ui-\(UUID().uuidString)")
        let app = AppDelegate(clipboard: .withUniqueName())
        app.recovery = try! SessionRecovery(directory: directory)
        app.makeWindow(restoreFrame: false); app.makeMenus(); app.showActiveBuffer()
        let controller = UpdateController(testing: true)
        app.connectUpdates(controller)
        defer {
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.window.delegate = nil; app.window.close(); app.clipboard.releaseGlobally()
            app.recovery = nil; try? FileManager.default.removeItem(at: directory)
        }
        let text = "A little space for your text.\n\nUpdates keep your scratch tabs and refresh both clients. 🦀\n"
        app.textView.insertText(text,replacementRange: NSRange(location: NSNotFound,length: 0))
        var downloads = 0, restarts = 0
        controller.simulateAvailable("1.1.0") { downloads += 1 }
        app.header.updateButton.performClick(nil); app.header.updateButton.performClick(nil)
        nativeSmokeInvariant(downloads == 1)
        app.newPrivateScratch()
        app.textView.insertText("PRIVATE_UPDATE_FIXTURE",replacementRange: NSRange(location: NSNotFound,length: 0))
        _ = try! app.session.shareForAgent(executable: "/synthetic/vibechar")
        controller.simulateReady { restarts += 1 }
        controller.activate()
        nativeSmokeInvariant(restarts == 0 && !controller.restartRequested && app.session.hasPrivateText && app.session.dropActive)
        nativeSmokeInvariant(app.footer.operationError?.contains("private") == true)
        controller.restartRequested = true
        nativeSmokeInvariant(app.applicationShouldTerminate(NSApp) == .terminateCancel && app.session.dropActive)
        nativeSmokeInvariant(app.session.close(discard: true)); app.showActiveBuffer()
        let store = app.recovery; app.recovery = nil
        controller.activate(); nativeSmokeInvariant(restarts == 0)
        app.recovery = store
        controller.activate(); nativeSmokeInvariant(restarts == 1 && controller.restartRequested)
        nativeSmokeInvariant(app.applicationShouldTerminate(NSApp) == .terminateNow)
        let restored = RustSession(); nativeSmokeInvariant(try! restored.restore(from: app.recovery!.fileURL))
        nativeSmokeInvariant(RustDocument(session: restored).text == text)
        nativeSmokeInvariant(!(try! String(contentsOf: app.recovery!.fileURL,encoding: .utf8)).contains("PRIVATE_UPDATE_FIXTURE"))
        controller.simulateAvailable("1.1.0") {}
        app.footer.operationError = nil
        let output = ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"].map { URL(fileURLWithPath: $0,isDirectory: true) }
        if let output { try! FileManager.default.createDirectory(at: output,withIntermediateDirectories: true) }
        for (theme,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            app.window.appearance = NSAppearance(named: appearance)
            for width in [420,880] {
                app.window.setContentSize(NSSize(width: width,height: 600))
                let root = app.window.contentView!; root.layoutSubtreeIfNeeded()
                nativeSmokeInvariant(app.header.bounds.contains(app.header.updateButton.frame))
                for other in app.header.subviews where other !== app.header.updateButton && !other.isHidden {
                    nativeSmokeInvariant(!other.frame.intersects(app.header.updateButton.frame),"Update pill must not overlap tabs or controls")
                }
                if let output {
                    root.effectiveAppearance.performAsCurrentDrawingAppearance {
                        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
                        root.cacheDisplay(in: root.bounds,to: bitmap)
                        try! bitmap.representation(using: .png,properties: [:])!.write(to: output.appendingPathComponent("updates-\(theme)-\(width).png"))
                    }
                }
            }
        }
        print("Update native smoke passed: quiet header, one-click lifecycle, private/grant protection, failed recovery pause, restored tabs and narrow themes")
    }

    static func launcherSmokeTest() {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu, clipboard = NSPasteboard.withUniqueName()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-launch-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let app = AppDelegate(clipboard: clipboard)
        defer {
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.textView.delegate = nil; app.window.delegate = nil; app.window.close()
            clipboard.releaseGlobally(); NSApp.mainMenu = previousMenu; try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("я 🦀 &?#.txt")
        try! "Hello 🦀\r\n".write(to: file,atomically: true,encoding: .utf8)
        try! app.openRequestedFile(file); precondition(app.pendingOpenFiles.count == 1)
        app.makeWindow(restoreFrame: false); app.makeMenus()
        for url in app.pendingOpenFiles { try! app.openRequestedFile(url) }; app.pendingOpenFiles = []
        precondition(app.document.text == "Hello 🦀\r\n" && app.session.fileURL == file)
        let count = app.session.count; try! app.openRequestedFile(file); precondition(app.session.count == count)
        let fresh = directory.appendingPathComponent("new file.txt")
        var uri = URLComponents(); uri.scheme = "vibechar"; uri.host = "open"; uri.queryItems = [.init(name: "path",value: fresh.path)]
        app.application(NSApp,open: [uri.url!]); precondition(app.document.text.isEmpty && app.session.fileURL == fresh)
        precondition(!FileManager.default.fileExists(atPath: fresh.path))
        app.application(NSApp,open: [URL(string: "vibechar://grant/ignore-me")!]); precondition(app.session.fileURL == fresh)
        let menu = NSApp.mainMenu!.items.first!.submenu!
        precondition(menu.items.contains { $0.action == #selector(installCommand) })
        print("Launcher native smoke passed: queued/running URL opens, Unicode/CRLF, existing-tab reuse, new files, ignored grants and Install vc menu")
    }

    private func showActiveBuffer() {
        recipeWindow?.close(); recipeWindow = nil
        rewriteWindow?.shutdown(); rewriteWindow = nil
        exampleWindow?.shutdown(); exampleWindow = nil
        expandedLayoutRevision=nil
        multiController.cancel()
        toolPalette?.close(); toolPalette=nil
        if findController.visible { findController.close() }
        footer.operationError = nil
        syntaxFrame = nil; syntaxSerial = 0
        footer.showSyntax(session.language.isEmpty ? "Text" : session.language, automatic: session.language.isEmpty, reason: session.language.isEmpty ? "Detects file names and pasted text locally" : "Pinned for this tab", limited: false)
        lineNumbers?.refresh();textView.enclosingScrollView?.tile()
        updateLayoutPolicy(at:session.selection.location)
        textView.setPlainText(document.text)
        textView.setSelectedRange(session.selection)
        textView.scrollRangeToVisible(textView.selectedRange())
        window.makeFirstResponder(textView)
        refreshTitle()
        scheduleSessionSave()
        scheduleSyntax()
    }

    @objc private func selectNumberedBuffer(_ sender: NSMenuItem) {
        switchBuffer(to: sender.tag == 9 ? session.count - 1 : sender.tag - 1)
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
        if let settings = aiSettings, commandWindow() === settings.window { settings.close(); return }
        if let rewriteWindow, commandWindow() === rewriteWindow.window { rewriteWindow.close(); return }
        if let exampleWindow, commandWindow() === exampleWindow.window { exampleWindow.close(); return }
        if let recipeWindow, commandWindow() === recipeWindow.window { recipeWindow.close(); return }
        closeBuffer(at: session.active)
    }

    @objc private func showAISettings() {
        if aiSettings == nil { aiSettings = aiSettingsFactory?() ?? AISettingsWindowController() }
        aiSettings?.present()
    }

    static func aiSettingsMenuSmokeTest(controller: AISettingsWindowController) {
        let previousMenu = NSApp.mainMenu
        let clipboard = NSPasteboard.withUniqueName()
        var creations = 0
        // Window activation is controlled by macOS and may be denied to background
        // CLI builds. Supply the focused window to test the same command routing.
        let app = AppDelegate(clipboard: clipboard, aiSettingsFactory: { creations += 1; return controller }, commandWindow: { controller.window })
        app.makeWindow(restoreFrame: false); app.makeMenus()
        defer {
            controller.shutdown(); app.textView.delegate = nil; app.window.orderOut(nil)
            clipboard.releaseGlobally(); NSApp.mainMenu = previousMenu
        }
        let settingsItem = NSApp.mainMenu!.items[0].submenu!.items.first { $0.action == #selector(showAISettings) }!
        precondition(settingsItem.keyEquivalent == "," && settingsItem.keyEquivalentModifierMask == [.command])
        precondition(NSApp.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem))
        app.showAISettings()
        precondition(creations == 1 && controller.window?.isVisible == true)
        for action in [#selector(saveFile), #selector(saveFileAs), #selector(newScratch), #selector(openTools), #selector(addNextOccurrence)] {
            precondition(!app.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
        let count = app.session.count, revision = app.document.revision
        controller.window?.makeFirstResponder(controller.keyField)
        precondition((controller.window?.firstResponder as? NSTextView)?.isFieldEditor == true)
        app.undoEdit()
        precondition(app.session.count == count && app.document.revision == revision)
        precondition(app.validateMenuItem(NSMenuItem(title: "", action: #selector(closeScratch), keyEquivalent: "w")))
        app.closeScratch()
        precondition(controller.window?.isVisible == false && app.session.count == count && app.document.revision == revision)
    }

    static func rewriteIntegrationSmokeTest(factory: @escaping @MainActor (RustSession,NSRange) throws -> RewriteModel) {
        let previousMenu = NSApp.mainMenu, clipboard = NSPasteboard.withUniqueName()
        var focused: NSWindow?
        let app = AppDelegate(clipboard: clipboard,commandWindow: { focused },rewriteFactory: factory)
        app.makeWindow(restoreFrame: false); app.makeMenus(); focused = app.window
        defer {
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.textView.delegate = nil; app.window.delegate = nil; app.window.close()
            clipboard.releaseGlobally(); NSApp.mainMenu = previousMenu
        }
        let source = "Outside\nhello 🦀\r\nTail"
        app.session.open(source); app.showActiveBuffer()
        app.textView.setSelectedRange((source as NSString).range(of: "hello 🦀"))
        let item = NSApp.mainMenu!.items.first { $0.title == "Edit" }!.submenu!.items.first { $0.action == #selector(openRewrite) }!
        precondition(item.keyEquivalent == "k" && item.keyEquivalentModifierMask == [.command,.shift] && app.validateMenuItem(item))
        precondition(NSApp.sendAction(item.action!,to: item.target,from: item))
        let pane = app.rewriteWindow!; focused = pane.window
        precondition(!app.validateMenuItem(NSMenuItem(title: "Save",action: #selector(saveFile),keyEquivalent: "s")))
        pane.instruction.string = "Make it shorter"; pane.textDidChange(Notification(name: NSText.didChangeNotification,object: pane.instruction))
        pane.preview.setSelectedRange((pane.model.source as NSString).range(of: "🦀"))
        pane.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,object: pane.preview))
        pane.protectButton.performClick(nil)
        precondition(pane.model.protected.count == 1)
        rewriteSnapshot(pane,name: "source")
        pane.generateButton.performClick(nil); rewriteWait { pane.model.phase != .generating }
        precondition(pane.model.phase == .preview && app.document.text == source && pane.tabs.selectedSegment == 1)
        precondition(pane.preview.string.contains("− hello") && pane.preview.string.contains("+ Hi"))
        rewriteSnapshot(pane,name: "changes")
        pane.window?.setContentSize(NSSize(width: 640,height: 600)); pane.window?.contentView?.layoutSubtreeIfNeeded()
        precondition(pane.window!.contentView!.bounds.contains(pane.applyButton.frame))
        rewriteSnapshot(pane,name: "narrow")
        pane.applyButton.performClick(nil)
        let rewritten = source.replacingOccurrences(of: "hello",with: "Hi")
        precondition(app.document.text == rewritten && app.textView.string == rewritten && app.rewriteWindow == nil)
        focused = app.window; app.undoEdit(); precondition(app.document.text == source && app.textView.string == source)
        app.redoEdit(); precondition(app.document.text == rewritten && app.textView.string == rewritten)
        app.textView.setSelectedRange((rewritten as NSString).range(of: "Hi 🦀")); app.openRewrite()
        let stale = app.rewriteWindow!
        stale.instruction.string = "Again"; stale.textDidChange(Notification(name: NSText.didChangeNotification,object: stale.instruction))
        stale.generateButton.performClick(nil); rewriteWait { stale.model.phase != .generating }
        app.window.makeFirstResponder(app.textView)
        app.textView.setSelectedRange(NSRange(location: 0,length: 0)); app.textView.insertText("!",replacementRange: NSRange(location: NSNotFound,length: 0))
        precondition(stale.model.phase == .stale && !stale.applyButton.isEnabled)
        let edited = app.document.text; stale.applyButton.performClick(nil); precondition(app.document.text == edited)
        focused = stale.window; let count = app.session.count; app.closeScratch()
        precondition(app.rewriteWindow == nil && app.session.count == count && stale.model.source.isEmpty)
        focused = app.window
        app.textView.setSelectedRange(NSRange(location: 0,length: 3)); app.openRewrite()
        let switched = app.rewriteWindow!; app.newScratch()
        precondition(app.rewriteWindow == nil && switched.model.phase == .closed)
        app.session.openPrivate(); precondition(app.document.replace(NSRange(location: 0,length: 0),with: "PRIVATE_REWRITE_FIXTURE"))
        app.showActiveBuffer(); app.textView.selectAll(nil)
        precondition(!app.validateMenuItem(item)); app.openRewrite(); precondition(app.rewriteWindow == nil)
    }

    static func exampleIntegrationSmokeTest(factory: @escaping @MainActor (RustSession,NSRange) throws -> ExampleModel) {
        let previousMenu = NSApp.mainMenu, clipboard = NSPasteboard.withUniqueName()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-example-library-\(UUID().uuidString)")
        var focused: NSWindow?
        let app = AppDelegate(clipboard: clipboard,commandWindow: { focused },exampleFactory: factory,recipeStore: RecipeStore(directory: directory))
        app.makeWindow(restoreFrame: false); app.makeMenus(); focused = app.window
        defer {
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.textView.delegate = nil; app.window.delegate = nil; app.window.close()
            clipboard.releaseGlobally(); NSApp.mainMenu = previousMenu
            try? FileManager.default.removeItem(at: directory)
        }
        let rows = "{\"id\":42,\"name\":\"Anna\"}\r\n{\"id\":7,\"name\":\"Боб 🦀\"}\nnot json\n"
        let source = "outside\n"+rows+"tail"
        app.session.open(source); app.document.markSaved(); app.showActiveBuffer()
        app.textView.setSelectedRange((source as NSString).range(of: rows))
        let item = NSApp.mainMenu!.items.first { $0.title == "Edit" }!.submenu!.items.first { $0.action == #selector(openExample) }!
        precondition(item.keyEquivalent == "k" && item.keyEquivalentModifierMask == [.command,.option] && app.validateMenuItem(item))
        precondition(NSApp.sendAction(item.action!,to: item.target,from: item))
        let pane = app.exampleWindow!; focused = pane.window
        precondition(!pane.learnButton.isEnabled && pane.beforeText.string == "{\"id\":42,\"name\":\"Anna\"}")
        precondition(!app.validateMenuItem(NSMenuItem(title: "Save",action: #selector(saveFile),keyEquivalent: "s")))
        pane.afterText.string = "Anna — /users/42"; pane.textDidChange(Notification(name: NSText.didChangeNotification,object: pane.afterText))
        exampleSnapshot(pane,name: "example")
        pane.learnButton.performClick(nil); rewriteWait { !pane.model.busy }
        precondition(pane.model.phase == .preview && pane.applyButton.isEnabled && pane.tabs.selectedSegment == 1)
        precondition(pane.preview.string.contains("+ Anna") && pane.preview.string.contains("Боб 🦀"))
        precondition(app.document.text == source && app.textView.string == source)
        precondition(pane.saveButton.isEnabled)
        pane.saveButton.performClick(nil); recipeCompleteSheet(pane.window!,accept: false)
        precondition(try! app.recipeStore.load().isEmpty)
        pane.saveButton.performClick(nil); recipeCompleteSheet(pane.window!,name: "User links",accept: true)
        rewriteWait { (try? app.recipeStore.load().count) == 1 }
        let persisted = try! RecipeStore(directory: directory).load()
        precondition(persisted.count == 1 && persisted[0].name == "User links")
        let stored = try! String(contentsOf: directory.appendingPathComponent("recipes.json"),encoding: .utf8)
        precondition(!stored.contains("Anna") && !stored.contains("Боб") && !stored.contains("not json"))
        exampleSnapshot(pane,name: "changes")
        pane.window?.setContentSize(NSSize(width: 700,height: 640)); pane.window?.contentView?.layoutSubtreeIfNeeded()
        precondition(pane.window!.contentView!.bounds.contains(pane.applyButton.frame))
        exampleSnapshot(pane,name: "narrow")
        pane.tabs.selectedSegment = 3; _ = pane.tabs.sendAction(pane.tabs.action,to: pane.tabs.target)
        precondition(pane.preview.string.contains("Read /name") && pane.preview.string.contains("Add after"))
        exampleSnapshot(pane,name: "rule")
        pane.tabs.selectedSegment = 4; _ = pane.tabs.sendAction(pane.tabs.action,to: pane.tabs.target)
        precondition(pane.preview.string.contains("Selection row 3")); exampleSnapshot(pane,name: "skipped")
        pane.applyButton.performClick(nil)
        let expected = "outside\nAnna — /users/42\r\nБоб 🦀 — /users/7\nnot json\ntail"
        precondition(app.document.text == expected && app.textView.string == expected && app.exampleWindow == nil)
        focused = app.window; app.undoEdit(); precondition(app.document.text == source && app.textView.string == source && !app.document.isDirty)
        app.redoEdit(); precondition(app.document.text == expected && app.textView.string == expected)
        app.undoEdit()
        // Reopen the learned, persisted rule on completely new text with no AI path.
        let unseen = "{\"id\":99,\"name\":\"UNSEEN_PERSON\"}\n"
        app.session.open(unseen); app.showActiveBuffer(); app.textView.selectAll(nil)
        app.openRecipes(); app.recipeWindow!.runButton.performClick(nil)
        let replay = app.exampleWindow!; rewriteWait { !replay.model.busy }
        precondition(replay.model.isReplay && replay.model.canApply && replay.model.frame!.result == "UNSEEN_PERSON — /users/99\n")
        replay.applyButton.performClick(nil)
        precondition(app.document.text == "UNSEEN_PERSON — /users/99\n" && app.textView.string == app.document.text)
        precondition(app.session.close(discard: true)); app.showActiveBuffer(); precondition(app.document.text == source)
        app.textView.setSelectedRange((source as NSString).range(of: rows)); app.openExample()
        let stale = app.exampleWindow!
        stale.afterText.string = "Anna — /users/42"; stale.textDidChange(Notification(name: NSText.didChangeNotification,object: stale.afterText))
        stale.learnButton.performClick(nil); rewriteWait { !stale.model.busy }
        app.window.makeFirstResponder(app.textView); app.textView.setSelectedRange(NSRange(location: 0,length: 0))
        app.textView.insertText("!",replacementRange: NSRange(location: NSNotFound,length: 0))
        precondition(stale.model.phase == .stale && !stale.applyButton.isEnabled)
        let changed = app.document.text; stale.applyButton.performClick(nil); precondition(app.document.text == changed)
        focused = stale.window; let count = app.session.count; app.closeScratch()
        precondition(app.exampleWindow == nil && app.session.count == count && stale.model.frame == nil && stale.afterText.string.isEmpty)
        focused = app.window
        app.textView.setSelectedRange((app.document.text as NSString).range(of: rows)); app.openExample()
        let switched = app.exampleWindow!; app.newScratch()
        precondition(app.exampleWindow == nil && switched.model.phase == .closed)
        app.session.openPrivate(); precondition(app.document.replace(NSRange(location: 0,length: 0),with: "PRIVATE\nEXAMPLE"))
        app.showActiveBuffer(); app.textView.selectAll(nil)
        precondition(!app.validateMenuItem(item)); app.openExample(); precondition(app.exampleWindow == nil)
    }

    static func recipeIntegrationSmokeTest(store: RecipeStore) {
        let previousMenu = NSApp.mainMenu, clipboard = NSPasteboard.withUniqueName()
        var focused: NSWindow?
        let app = AppDelegate(clipboard: clipboard,commandWindow: { focused },recipeStore: store)
        app.makeWindow(restoreFrame: false); app.makeMenus(); focused = app.window
        defer {
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.textView.delegate = nil; app.window.delegate = nil; app.window.close()
            clipboard.releaseGlobally(); NSApp.mainMenu = previousMenu
        }
        let source = "outside\n{\"id\":7}\r\nnot json\ntail", rows = "{\"id\":7}\r\nnot json\n"
        app.session.open(source); app.document.markSaved(); app.showActiveBuffer()
        app.textView.setSelectedRange((source as NSString).range(of: rows))
        let item = NSApp.mainMenu!.items.first { $0.title == "Edit" }!.submenu!.items.first { $0.action == #selector(openRecipes) }!
        precondition(item.keyEquivalent == "r" && item.keyEquivalentModifierMask == [.command,.option] && app.validateMenuItem(item))
        precondition(NSApp.sendAction(item.action!,to: item.target,from: item))
        let library = app.recipeWindow!; focused = library.window
        precondition(library.visible.count == 1 && library.runButton.isEnabled)
        recipeSnapshot(library,name: "library")
        library.search.stringValue = "no such recipe"; library.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,object: library.search))
        precondition(library.visible.isEmpty && !library.runButton.isEnabled)
        recipeSnapshot(library,name: "search-empty")
        library.search.stringValue = "extract USER"; library.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,object: library.search))
        precondition(library.visible.count == 1 && library.runButton.isEnabled)
        library.window?.setContentSize(NSSize(width: 560,height: 460)); library.window?.contentView?.layoutSubtreeIfNeeded()
        precondition(library.window!.contentView!.bounds.contains(library.runButton.frame)); recipeSnapshot(library,name: "narrow")
        precondition(library.control(library.search,textView: NSTextView(),doCommandBy: #selector(NSResponder.insertNewline(_:))))
        precondition(app.recipeWindow == nil)
        let pane = app.exampleWindow!; focused = pane.window; rewriteWait { !pane.model.busy }
        precondition(pane.model.isReplay && pane.model.canApply && pane.learnButton.isHidden && pane.saveButton.isHidden)
        precondition(pane.preview.string.contains("+ user/7") && app.document.text == source)
        exampleSnapshot(pane,name: "saved-replay")
        pane.applyButton.performClick(nil); focused = app.window
        precondition(app.document.text == "outside\nuser/7\r\nnot json\ntail" && app.textView.string == app.document.text)
        app.undoEdit(); precondition(app.document.text == source && !app.document.isDirty)
        app.redoEdit(); precondition(app.document.text == "outside\nuser/7\r\nnot json\ntail")
        app.openRecipes(); focused = app.recipeWindow?.window
        let count = app.session.count; app.closeScratch(); precondition(app.recipeWindow == nil && app.session.count == count)
        focused = app.window; app.openRecipes(); let switching = app.recipeWindow; app.newScratch()
        precondition(app.recipeWindow == nil && switching?.window?.isVisible == false)
        app.session.openPrivate(); app.showActiveBuffer(); precondition(!app.validateMenuItem(item))
        app.openRecipes(); precondition(app.recipeWindow == nil)
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
        if menuItem.action == #selector(checkForUpdates) { return updates?.canCheck ?? false }
        if menuItem.action == #selector(toggleUpdateChecks) {
            menuItem.state = updates?.automaticallyChecks == true ? .on : .off
            return updates != nil
        }
        if menuItem.action == #selector(installCommand) { return !commandInstallBusy }
        if menuItem.action == #selector(closeScratch) {
            menuItem.title = (aiSettings != nil && commandWindow() === aiSettings?.window) || (rewriteWindow != nil && commandWindow() === rewriteWindow?.window) || (exampleWindow != nil && commandWindow() === exampleWindow?.window) || (recipeWindow != nil && commandWindow() === recipeWindow?.window) ? "Close Window" : "Close Tab"
        }
        if let recipeWindow, commandWindow() === recipeWindow.window {
            if menuItem.action == #selector(undoEdit) || menuItem.action == #selector(redoEdit) { return (commandWindow()?.firstResponder as? NSTextView)?.isEditable == true }
            return [#selector(showAbout),#selector(closeScratch),#selector(changeAppearance(_:))].contains(menuItem.action)
        }
        if let exampleWindow, commandWindow() === exampleWindow.window {
            if menuItem.action == #selector(undoEdit) || menuItem.action == #selector(redoEdit) { return (commandWindow()?.firstResponder as? NSTextView)?.isEditable == true }
            return [#selector(showAISettings),#selector(showAbout),#selector(closeScratch),#selector(changeAppearance(_:))].contains(menuItem.action)
        }
        if let rewriteWindow, commandWindow() === rewriteWindow.window {
            if menuItem.action == #selector(undoEdit) || menuItem.action == #selector(redoEdit) {
                return (commandWindow()?.firstResponder as? NSTextView)?.isEditable == true
            }
            return [#selector(showAISettings),#selector(showAbout),#selector(closeScratch),#selector(changeAppearance(_:))].contains(menuItem.action)
        }
        if let settings = aiSettings, commandWindow() === settings.window {
            if menuItem.action == #selector(undoEdit) || menuItem.action == #selector(redoEdit) {
                return (commandWindow()?.firstResponder as? NSTextView)?.isFieldEditor == true
            }
            return [#selector(showAISettings), #selector(showAbout), #selector(closeScratch), #selector(changeAppearance(_:))].contains(menuItem.action)
        }
        if menuItem.action == #selector(changeLargeTextMode(_:)) {menuItem.state=menuItem.tag==largeTextChoice ? .on : .off}
        if menuItem.action == #selector(toggleLineNumbers) {menuItem.state=showLineNumbers ? .on : .off}
        if menuItem.action == #selector(toggleWrapLines) {menuItem.state=wrapLines ? .on : .off}
        if menuItem.action == #selector(selectNumberedBuffer(_:)) {
            return menuItem.tag == 9 || (menuItem.tag >= 1 && menuItem.tag <= session.count)
        }
        if menuItem.action == #selector(copyForAgent) { return session.isPrivate && !textView.string.isEmpty }
        if menuItem.action == #selector(openRewrite) { return !session.isPrivate && textView.selectedRange().length > 0 && !multiController.active }
        if menuItem.action == #selector(openExample) { return !session.isPrivate && textView.selectedRange().length > 0 && !multiController.active }
        if menuItem.action == #selector(openRecipes) { return !session.isPrivate }
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
                             chooseDestination: @MainActor (SaveDestination) -> URL? = { $0.choose() }) throws {
        guard multipleInputReady() else {throw NSError(domain:"Vibechar",code:1,userInfo:[NSLocalizedDescriptionKey:"Finishing occurrence matching. Save again when it completes."])}
        toolPalette?.close(); toolPalette=nil
        document.breakUndoGroup()
        let wasPrivate = session.isPrivate
        var destination = alwaysChooseDestination || wasPrivate ? nil : fileURL
        if destination == nil {
            destination = chooseDestination(SaveDestination(
                name: wasPrivate ? "Private.txt" : fileURL?.lastPathComponent ?? "Untitled.txt",
                directory: fileURL?.deletingLastPathComponent(), isPrivate: wasPrivate))
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
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { aiSettings?.close(); rewriteWindow?.shutdown(); rewriteWindow = nil; exampleWindow?.shutdown(); exampleWindow = nil; recipeWindow?.close(); recipeWindow = nil }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updates?.restartRequested == true {
            updates?.restartRequested = false
            if prepareForUpdate() { return .terminateNow }
            updates?.terminationCancelled()
            return .terminateCancel
        }
        return (closingWindow || saveBeforeQuitting()) ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        stopping=true
        aiSettings?.shutdown()
        rewriteWindow?.shutdown(); rewriteWindow = nil
        exampleWindow?.shutdown(); exampleWindow = nil
        recipeWindow?.close(); recipeWindow = nil
        // AppKit terminates the process without guaranteeing Swift/Rust deinit.
        closeAllAgentAccess()
        syntaxWork?.cancel(); syntaxTimer?.invalidate()
        metricsTimer?.invalidate();metricsTimer=nil;metricsPopover?.performClose(nil)
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Vibechar", .applicationVersion: version])
    }

    @objc private func checkForUpdates() { updates?.check() }
    @objc private func toggleUpdateChecks() { updates?.toggleAutomaticChecks() }
    private func connectUpdates(_ controller: UpdateController) {
        updates = controller
        controller.onChange = { [weak self, weak controller] state in
            guard let self else { return }
            let detail = state.actionable ? "Vibechar \(controller?.availableVersion ?? "") · updates the Mac app and terminal client" : "Updating Vibechar…"
            self.header.showUpdate(title: state.title,enabled: state.actionable,detail: detail)
        }
        controller.onStatus = { [weak self] message, failed in self?.footer.showStatus(message,failed: failed) }
        controller.canRestart = { [weak self] in self?.prepareForUpdate() ?? false }
    }
    private func prepareForUpdate() -> Bool {
        guard !session.hasPrivateText else {
            footer.operationError = "Save or close private tabs before restarting"
            return false
        }
        guard multipleInputReady() else { return false }
        pendingSave?.cancel(); pendingSave = nil; saveGeneration &+= 1
        session.rememberSelection(textView.selectedRange())
        guard let recovery, recovery.flush(session.checkpoint()) else {
            footer.operationError = "Couldn't save tabs · update paused"
            return false
        }
        footer.operationError = nil
        return true
    }

    static func largeTextSmokeTest() {
        _=NSApplication.shared
        let app=AppDelegate(clipboard:.withUniqueName());app.makeWindow(restoreFrame:false);app.makeMenus()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-large-native-\(UUID().uuidString)",isDirectory:true)
        try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {app.stopping=true;app.metricsTimer?.invalidate();app.closeAllAgentAccess();app.syntaxWork?.cancel();app.syntaxTimer?.invalidate();app.multiController.cancel();app.clipboard.clearContents();app.window.delegate=nil;app.window.close();try? FileManager.default.removeItem(at:root)}
        let output=ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"].map {URL(fileURLWithPath:$0,isDirectory:true)}
        if let output {try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)}
        func draw(_ name:String="large") {
            let view=app.window.contentView!;view.layoutSubtreeIfNeeded()
            app.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:bitmap)
                if let output {try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))}
            }
        }
        func check(_ source:String) {precondition(app.document.text==source && app.textView.string==source,"Layout must preserve every source character")}
        func mode(_ choice:Int) {
            let view=NSApp.mainMenu!.item(withTitle:"View")!.submenu!
            let item=view.item(withTitle:"Large Text Mode")!.submenu!.items[choice]
            precondition(NSApp.sendAction(item.action!,to:item.target,from:item));_=app.validateMenuItem(item);precondition(item.state == .on)
        }
        precondition(app.budgetTypesetter.glyphBudget==0)
        let cap=RustDocument.paragraphBudget
        let single=String(repeating:"z",count:cap*2+1)
        app.session.open(single);app.showActiveBuffer()
        precondition(app.budgetTypesetter.glyphBudget==cap,"Ignore transient EOF selections while installing a buffer")
        app.textView.setSelectedRange(NSRange(location:(single as NSString).length,length:0))
        precondition(app.budgetTypesetter.glyphBudget==0)
        app.textView.setSelectedRange(NSRange(location:0,length:0))
        precondition(app.budgetTypesetter.glyphBudget==0,"Reuse prepared context during navigation in the same revision")
        app.textView.insertText("!",replacementRange:NSRange(location:NSNotFound,length:0));check("!"+single)
        precondition(app.budgetTypesetter.glyphBudget==cap,"A new prefix edit returns to bounded context")
        app.applyHistory(redo:false);check(single)
        precondition(app.session.close(discard:true));app.showActiveBuffer()
        let source=String(repeating:"x",count:cap-1)+"👩‍💻e\u{301}"+String(repeating:"y",count:cap*2)+"\0\r\nlast tail 👩‍💻\r\n"
        app.session.open(source);app.document.markSaved();app.showActiveBuffer();draw()
        precondition(app.document.isLarge && app.footer.largeText && app.budgetTypesetter.glyphBudget==cap && app.wrapLines)
        let word=app.textView.selectionRange(forProposedRange:NSRange(location:100,length:0),granularity:.selectByWord)
        precondition(word==NSRange(location:100,length:0) && app.footer.operationError?.contains("drag")==true)
        app.footer.operationError=nil
        let tail=(source as NSString).range(of:"last tail")
        precondition(app.textView.selectionRange(forProposedRange:NSRange(location:tail.location+1,length:6),granularity:.selectByWord)==tail,"Word-drag expands both endpoints")
        let emojiTail=(source as NSString).range(of:"last tail 👩‍💻")
        precondition(app.textView.selectionRange(forProposedRange:NSRange(location:emojiTail.location+1,length:emojiTail.length-1),granularity:.selectByWord)==emojiTail,"Word-drag cannot split a trailing surrogate/emoji cluster")
        precondition(app.textView.selectionRange(forProposedRange:NSRange(location:cap-1,length:5),granularity:.selectByWord)==NSRange(location:cap-1,length:5),"Refused giant-word scans retain native grapheme-safe drag")
        app.footer.operationError=nil
        for offset in [0,cap-1,cap+6,(source as NSString).length] {
            app.textView.setSelectedRange(NSRange(location:offset,length:0));app.textView.scrollRangeToVisible(app.textView.selectedRange());draw()
            let rect=app.textView.firstRect(forCharacterRange:app.textView.selectedRange(),actualRange:nil)
            let local=app.textView.convert(app.window.convertFromScreen(rect),from:nil)
            precondition(app.textView.visibleRect.contains(NSPoint(x:local.minX,y:local.midY)),"Native caret must be visible after a distant reveal")
            precondition(app.textView.characterIndexForInsertion(at:NSPoint(x:local.minX+0.1,y:local.midY))==offset,"Native pointer geometry must agree at layout boundaries")
            check(source)
        }
        app.textView.setSelectedRange(NSRange(location:cap-1,length:7))
        precondition(app.textView.writeSelection(to:app.clipboard,types:app.textView.writablePasteboardTypes))
        precondition(app.clipboard.string(forType:.string)=="👩‍💻e\u{301}")
        app.textView.deleteBackward(nil);check(String(repeating:"x",count:cap-1)+String(repeating:"y",count:cap*2)+"\0\r\nlast tail 👩‍💻\r\n")
        app.applyHistory(redo:false);check(source)
        app.textView.setSelectedRange(NSRange(location:0,length:0))
        app.textView.insertText("!",replacementRange:NSRange(location:NSNotFound,length:0));check("!"+source)
        app.applyHistory(redo:false);check(source);precondition(!app.document.isDirty)
        app.applyHistory(redo:true);check("!"+source);app.applyHistory(redo:false);check(source)
        app.textView.selectAll(nil)
        precondition(app.textView.writeSelection(to:app.clipboard,types:app.textView.writablePasteboardTypes))
        precondition(app.clipboard.string(forType:.string)==source)
        let selected=app.textView.selectedRange()
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            app.window.appearance=NSAppearance(named:appearance)
            for width in [420,880] {app.window.setContentSize(NSSize(width:width,height:600));draw("large-\(name)-\(width)");check(source);precondition(app.textView.selectedRange()==selected && app.footer.bounds.contains(app.footer.counts.frame))}
        }
        let version=app.document.revision
        mode(2);precondition(app.budgetTypesetter.glyphBudget==0 && !app.footer.largeText)
        mode(1);precondition(app.budgetTypesetter.glyphBudget==cap)
        mode(0);precondition(app.document.revision==version && app.textView.selectedRange()==selected)
        app.toggleWrapLines();precondition(app.budgetTypesetter.glyphBudget==0 && !app.wrapLines);check(source)
        app.toggleWrapLines();precondition(app.budgetTypesetter.glyphBudget==cap && app.wrapLines)
        app.textView.setSelectedRange(NSRange(location:0,length:0))
        app.textView.insertText("שלום",replacementRange:NSRange(location:NSNotFound,length:0));check("שלום"+source)
        precondition(app.budgetTypesetter.glyphBudget==0,"Preserve full bidi paragraph context")
        app.applyHistory(redo:false);check(source);precondition(app.budgetTypesetter.glyphBudget==cap)
        try! app.saveActive(to:root.appendingPathComponent("saved.txt"))
        precondition(try! Data(contentsOf:root.appendingPathComponent("saved.txt"))==Data(source.utf8))
        app.newScratch();precondition(app.budgetTypesetter.glyphBudget==0 && !app.footer.largeText)
        app.switchBuffer(to:1);check(source);precondition(app.budgetTypesetter.glyphBudget==cap)
        app.newPrivateScratch();app.textView.insertText("PRIVATE_LARGE_NATIVE",replacementRange:NSRange(location:NSNotFound,length:0))
        _=try! app.session.shareForAgent(executable:"/synthetic/vibechar")
        mode(1);mode(2);mode(0);precondition(app.session.dropActive)
        app.session.openPrivate();precondition(app.document.replace(NSRange(location:0,length:0),with:source));app.showActiveBuffer()
        precondition(app.budgetTypesetter.glyphBudget==cap && app.session.isPrivate)
        let checkpoint=root.appendingPathComponent("recovery.json");precondition(app.session.checkpoint().save(to:checkpoint))
        let restored=RustSession();_=try! restored.restore(from:checkpoint)
        for index in 0..<restored.count {precondition(!restored.isPrivate(index))}
        print("Large text native smoke passed: automatic/manual layout budgets, composed clusters at boundaries, NUL/CRLF, distant caret, native selection/copy/delete, input/Undo/Redo, exact save, tabs, private exclusion/grants and narrow themes")
    }

    static func countersSmokeTest() {
        _ = NSApplication.shared
        let app=AppDelegate(clipboard:.withUniqueName());app.makeWindow(restoreFrame:false);app.makeMenus()
        defer {app.metricsTimer?.invalidate();app.closeAllAgentAccess();app.syntaxWork?.cancel();app.syntaxTimer?.invalidate();app.multiController.cancel();app.clipboard.clearContents();app.window.delegate=nil;app.window.close()}
        func ready()->TextMetrics {
            let end=Date(timeIntervalSinceNow:8)
            while app.metrics.frame(app.document)?.busy != false {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01));app.refreshStatistics();precondition(Date()<end)}
            return app.metrics.frame(app.document)!
        }
        let output=ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"].map {URL(fileURLWithPath:$0,isDirectory:true)}
        if let output {try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)}
        @discardableResult func render(_ name:String)->NSBitmapImageRep {
            let root=app.window.contentView!;root.layoutSubtreeIfNeeded()
            let bitmap=root.bitmapImageRepForCachingDisplay(in:root.bounds)!
            app.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                root.cacheDisplay(in:root.bounds,to:bitmap)
                if let output {try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))}
            }
            return bitmap
        }
        app.showActiveBuffer()
        precondition(ready().total.characters==0 && app.document.lineCount==1)
        render("counters-empty")
        let source="one 👩‍💻e\u{301}\r\nsecond\r\n"
        app.session.open(source);app.showActiveBuffer()
        precondition(ready().total.characters==14 && ready().total.lines==3 && ready().total.words==3)
        app.textView.setSelectedRange(NSRange(location:4,length:5))
        precondition(ready().selected.characters==1 && ready().selected.bytes==11)
        app.textView.setSelectedRange(NSRange(location:9,length:2));precondition(ready().selected.characters==1)
        let long=String(repeating:"Long line 👩‍💻 · ",count:18)+"\r\n"+(1...120).map {"line \($0)"}.joined(separator:"\r\n")+"\r\n"
        app.session.open(long);app.showActiveBuffer();let revision=app.document.revision
        for (theme,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            app.window.appearance=NSAppearance(named:appearance)
            for width in [420,880] {
                app.window.setContentSize(NSSize(width:width,height:600))
                app.textView.setSelectedRange(NSRange(location:0,length:36));_=ready()
                render("counters-\(theme)-\(width)")
                precondition(app.footer.bounds.contains(app.footer.counts.frame))
                precondition(app.footer.bounds.contains(app.footer.position.frame))
                precondition(!app.footer.counts.frame.intersects(app.footer.position.frame))
                precondition(app.textView.enclosingScrollView!.rulersVisible && !app.textView.enclosingScrollView!.hasHorizontalRuler)
            }
        }
        let range=app.document.lineRange(100)!
        app.textView.setSelectedRange(NSRange(location:range.location,length:0));app.textView.scrollRangeToVisible(app.textView.selectedRange());_=ready();render("counters-scrolled")
        precondition(app.lineNumbers!.activeLine==100)
        let layout=app.textView.layoutManager!
        let glyph=layout.glyphIndexForCharacter(at:range.location)
        let fragment=layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        let point=app.lineNumbers!.convert(NSPoint(x:0,y:fragment.midY+app.textView.textContainerOrigin.y),from:app.textView)
        let windowPoint=app.lineNumbers!.convert(NSPoint(x:app.lineNumbers!.bounds.midX,y:point.y),to:nil)
        let event=NSEvent.mouseEvent(with:.leftMouseDown,location:windowPoint,modifierFlags:[],timestamp:0,windowNumber:app.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        app.lineNumbers!.mouseDown(with:event)
        precondition(app.textView.selectedRange()==range && ready().selected.lines==1)
        let selected=app.textView.selectedRange()
        func headerPixels(_ bitmap:NSBitmapImageRep)->Data {
            let scale=CGFloat(bitmap.pixelsHigh)/app.window.contentView!.bounds.height
            let crop=bitmap.cgImage!.cropping(to:NSRect(x:0,y:0,width:CGFloat(bitmap.pixelsWide),height:app.header.bounds.height*scale))!
            return NSBitmapImageRep(cgImage:crop).representation(using:.png,properties:[:])!
        }
        let numberedHeader=headerPixels(render("counters-numbered"))
        app.toggleLineNumbers();precondition(!app.textView.enclosingScrollView!.rulersVisible)
        precondition(numberedHeader==headerPixels(render("counters-unnumbered")),"Ruler paint must never cover the header outside its bounds")
        app.toggleLineNumbers();precondition(app.document.revision==revision && app.textView.selectedRange()==selected && app.document.text==long)
        app.newPrivateScratch();app.textView.insertText("foo foo",replacementRange:NSRange(location:NSNotFound,length:0))
        _=try! app.session.shareForAgent(executable:"/synthetic/vibechar")
        app.refreshTitle()
        app.textView.setSelectedRange(NSRange(location:0,length:3));app.selectAllOccurrences()
        let end=Date(timeIntervalSinceNow:5)
        while app.multiController.state.busy {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01));app.multiController.poll();precondition(Date()<end)}
        let frame=ready();precondition(frame.targets==2 && frame.selected.characters==6 && frame.selected.lines==1)
        app.window.setContentSize(NSSize(width:420,height:600));render("counters-private")
        precondition(app.session.dropActive && app.footer.bounds.contains(app.footer.counts.frame))
        let controller=MetricsPopover(frame)
        if let output {
            let root=controller.view;root.appearance=NSAppearance(named:.darkAqua)
            let bitmap=root.bitmapImageRepForCachingDisplay(in:root.bounds)!;root.cacheDisplay(in:root.bounds,to:bitmap)
            try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("counters-details.png"))
        }
        print("Counters/gutter native smoke passed: graphemes/CRLF, selection/bytes/words, wrapped numbers, scroll, gutter click, toggle, private multicursor, narrow themes and numerical details")
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

    static func multicursorPasteSmokeTest() {
        let app=AppDelegate(clipboard:.withUniqueName());app.makeWindow(restoreFrame:false)
        defer {app.multiController.cancel();app.syntaxWork?.cancel();app.syntaxTimer?.invalidate();app.window.delegate=nil;app.window.close();app.clipboard.clearContents()}
        let source="foo\n\nfoo\n\n"
        precondition(app.document.replace(NSRange(location:0,length:0),with:source));app.document.markSaved();app.showActiveBuffer()
        app.addNextOccurrence();app.addNextOccurrence()
        let deadline=Date(timeIntervalSinceNow:3)
        while app.multiController.state.busy {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01));app.multiController.poll();precondition(Date()<deadline)}
        precondition(app.multiController.state.selections.count==2)
        app.textView.copy(nil);precondition(app.clipboard.string(forType:.string)=="foo\nfoo")
        app.textView.doCommand(by:#selector(NSResponder.moveDown(_:)));app.textView.paste(nil)
        precondition(app.document.text=="foo\nfoo\nfoo\nfoo\n" && app.textView.string==app.document.text)
        precondition(app.multiController.state.selections.count==2 && app.multiController.state.selections.allSatisfy {$0.length==0})
        app.applyHistory(redo:false);precondition(app.document.text==source && !app.document.isDirty)
        print("Multicursor paste native regression passed: Cmd+D twice, Copy, Down, Paste spreads once per caret, native mirror and one Undo")
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
        nativeSmokeInvariant(saveAs.keyEquivalent == "s" && saveAs.keyEquivalentModifierMask == [.command, .shift] && saveAs.target === app)
        let original = root.appendingPathComponent("original.txt")
        let renamed = root.appendingPathComponent("копия.txt")
        let fixture = "Save As · Привет 👩‍💻\r\n"
        try! fixture.write(to: original, atomically: true, encoding: .utf8)
        nativeSmokeInvariant(app.document.replace(NSRange(location: 0, length: 0), with: fixture))
        app.session.completeSave(to: original)
        nativeSmokeInvariant(app.document.replace(NSRange(location: fixture.utf16.count, length: 0), with: "!"))
        app.session.rememberSelection(NSRange(location: 0, length: 1))
        app.showActiveBuffer()
        let textBeforeSave = app.document.text
        var asked = false
        try! app.performSave(alwaysChooseDestination: true) { request in
            asked = true
            nativeSmokeInvariant(request.name == "original.txt" && !request.isPrivate)
            nativeSmokeInvariant(request.directory?.resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
            return nil
        }
        nativeSmokeInvariant(asked && app.session.fileURL == original && app.document.isDirty && app.document.text == textBeforeSave)
        nativeSmokeInvariant(app.textView.selectedRange() == NSRange(location: 0, length: 1))
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
            nativeSmokeInvariant(app.session.fileURL == original && app.document.isDirty && app.document.text == textBeforeSave)
        }
        try! "replace fixture".write(to: renamed, atomically: true, encoding: .utf8)
        try! app.performSave(alwaysChooseDestination: true) { _ in renamed }
        nativeSmokeInvariant(app.session.fileURL == renamed && !app.document.isDirty && app.session.count == 1)
        nativeSmokeInvariant(app.session.label(0) == "копия.txt" && app.textView.selectedRange() == NSRange(location: 0, length: 1))
        nativeSmokeInvariant(try! Data(contentsOf: original) == Data(fixture.utf8))
        nativeSmokeInvariant(try! Data(contentsOf: renamed) == Data((fixture + "!").utf8))
        nativeSmokeInvariant(try! String(contentsOf: readOnly, encoding: .utf8) == "preserve")
        nativeSmokeInvariant(app.document.history(redo: false) != nil && app.document.isDirty)
        nativeSmokeInvariant(app.document.history(redo: true) != nil && !app.document.isDirty)
        nativeSmokeInvariant(app.document.replace(NSRange(location: app.document.text.utf16.count, length: 0), with: "?"))
        app.showActiveBuffer()
        try! app.performSave(alwaysChooseDestination: false) { _ in preconditionFailure("Regular Save must reuse the new destination") }
        nativeSmokeInvariant(try! Data(contentsOf: renamed) == Data((fixture + "!?").utf8))
        nativeSmokeInvariant(try! Data(contentsOf: original) == Data(fixture.utf8))
        nativeSmokeInvariant(app.recovery!.flush(app.session.checkpoint()))
        let restored = RustSession()
        nativeSmokeInvariant(try! restored.restore(from: app.recovery!.fileURL))
        nativeSmokeInvariant(restored.fileURL == renamed && RustDocument(session: restored).text == fixture + "!?")
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
                let buttons = app.footer.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0 !== app.footer.languageButton && $0 !== app.footer.counts }
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
        precondition(app.footer.subviews.compactMap { $0 as? NSButton }.filter { $0 !== app.footer.languageButton && $0 !== app.footer.counts }.allSatisfy { $0.isHidden })
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

// Release builds optimize Swift's assertion messages away; keep native test
// failures actionable on CI without printing any document or credential data.
private func nativeSmokeInvariant(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
    guard condition() else {
        fputs("Native smoke invariant failed at VibecharApp.swift:\(line): \(message)\n", stderr)
        exit(1)
    }
}

// Keep destination choice injectable without contacting the system's remote
// save-panel service during filesystem tests on a headless runner.
@MainActor
private struct SaveDestination {
    let name: String
    let directory: URL?
    let isPrivate: Bool

    func choose() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if let directory { panel.directoryURL = directory }
        if isPrivate {
            panel.title = "Save Private Tab"
            panel.message = "Saving makes this a regular file tab, includes it in local recovery, and closes its agent access."
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

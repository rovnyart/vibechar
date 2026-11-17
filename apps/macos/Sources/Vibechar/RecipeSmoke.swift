import AppKit

private let savedRuleFixture = #"{"version":1,"input":"json","delimiter":"","format":"text","parts":[{"field":"/id","casing":"keep","trim":false,"encoding":"text","prefix":"user/","suffix":""}]}"#
private final class OfflineVault: AICredentialStore, @unchecked Sendable {
    func load() throws -> String? { preconditionFailure("Offline replay accessed credentials") }
    func save(_ key: String) throws { preconditionFailure() }
    func remove() throws { preconditionFailure() }
}
private struct OfflineProvider: AIExampleLearning {
    func inferRecipe(key: String, model: AIModel, before: String, after: String) async throws -> String {
        preconditionFailure("Offline replay called AI")
    }
}

@MainActor
func recipeSmokeTest() {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibechar-recipes-\(UUID().uuidString)",isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecipeStore(directory: directory)
    precondition(try! store.load().isEmpty)
    let saved = try! store.save(name: " User links 🦀 ",rule: savedRuleFixture)
    let file = directory.appendingPathComponent("recipes.json"), bytes = try! Data(contentsOf: file)
    precondition(saved.name == "User links 🦀" && (try! RecipeStore(directory: directory).load()).first?.id == saved.id)
    precondition((try! FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue == 0o600)
    func rejected(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid recipe library operation succeeded") } catch {}
        precondition((try! Data(contentsOf: file)) == bytes)
    }
    rejected { _ = try store.save(name: "user LINKS 🦀",rule: savedRuleFixture) }
    rejected { _ = try store.save(name: "",rule: savedRuleFixture) }
    rejected { _ = try store.save(name: "bad\nname",rule: savedRuleFixture) }
    rejected { _ = try store.save(name: "invalid",rule: "{invalid}") }
    rejected { _ = try store.save(name: "future",rule: savedRuleFixture.replacingOccurrences(of: "\"version\":1",with: "\"version\":99")) }
    try! store.rename(saved.id,to: "Extract user ID")
    let recipe = try! RecipeStore(directory: directory).load().first!
    precondition(recipe.id == saved.id && recipe.name == "Extract user ID" && recipe.rule == saved.rule)

    let session = RustSession(), document = RustDocument(session: session)
    let source = "OUTSIDE\nnot json\r\n{\"id\":900719925474099312345}\n{\"missing\":7}\nTAIL"
    session.open(source); document.markSaved()
    let target = (source as NSString).range(of: "not json\r\n{\"id\":900719925474099312345}\n{\"missing\":7}\n")
    func replay(_ range: NSRange = target) -> ExampleModel {
        try! ExampleModel(session: session,target: range,vault: OfflineVault(),service: OfflineProvider(),savedRecipe: recipe)
    }
    var model = replay(); model.learn(); model.editAfter("MUST_NOT_TEACH")
    rewriteWait { !model.busy }; precondition(model.phase == .preview && model.canApply && !model.canSave && !model.canLearn)
    precondition(model.frame!.stats!.matched == 1 && model.frame!.stats!.skipped == 2 && document.text == source)
    model.apply(); precondition(document.text == "OUTSIDE\nnot json\r\nuser/900719925474099312345\n{\"missing\":7}\nTAIL")
    precondition(document.history(redo: false) != nil && document.text == source && !document.isDirty)
    precondition(!(String(decoding: try! Data(contentsOf: file),as: UTF8.self)).contains("900719925474099312345"))
    model = replay((source as NSString).range(of: "not json")); rewriteWait { !model.busy }
    precondition(model.phase == .preview && !model.canApply && model.status.contains("No rows")); model.apply(); model.close()
    model = replay(); precondition(document.replace(NSRange(location: 0,length: 0),with: "!")); model.sourceChanged()
    precondition(model.phase == .stale && !model.canApply); model.close()
    precondition(document.history(redo: false) != nil && document.text == source)
    model = replay(); model.cancel(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
    precondition(model.phase == .ready && model.frame?.result == nil && !model.canLearn); model.close()
    session.openPrivate(); precondition(document.replace(NSRange(location: 0,length: 0),with: "PRIVATE\nROWS"))
    do { _ = try ExampleModel(session: session,target: NSRange(location: 0,length: 12),vault: OfflineVault(),service: OfflineProvider(),savedRecipe: recipe); preconditionFailure() } catch {}

    AppDelegate.recipeIntegrationSmokeTest(store: RecipeStore(directory: directory))
    try! store.delete(recipe.id); precondition(try! RecipeStore(directory: directory).load().isEmpty)
    let blocked = directory.appendingPathComponent("blocked"); try! Data("file".utf8).write(to: blocked)
    do { _ = try RecipeStore(directory: blocked).save(name: "Blocked",rule: savedRuleFixture); preconditionFailure() } catch {}
    let futureRule = try! JSONSerialization.data(withJSONObject: ["version":1,"recipes":[["id":UUID().uuidString,"name":"New rule","rule":savedRuleFixture.replacingOccurrences(of: "\"version\":1",with: "\"version\":99")]]])
    for corrupt in [Data("{invalid}".utf8),Data("{\"version\":99,\"recipes\":[]}".utf8),futureRule] {
        try! corrupt.write(to: file)
        do { _ = try store.load(); preconditionFailure() } catch {}
        do { _ = try store.save(name: "Don't overwrite",rule: savedRuleFixture); preconditionFailure() } catch {}
        precondition((try! Data(contentsOf: file)) == corrupt)
    }
    print("Saved recipes native smoke passed: restart persistence, CRUD, version/corruption/write protection, offline replay without credentials/provider, one matching row, skips, stale/cancel, private refusal, native menu/search/preview/Undo")
}

/// Exercise the real NSAlert sheet and completion without user clipboard/keychain access.
@MainActor
func recipeCompleteSheet(_ parent: NSWindow, name: String? = nil, accept: Bool) {
    rewriteWait { parent.attachedSheet != nil }
    let sheet = parent.attachedSheet!
    if let name {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        let field = find(sheet.contentView!)!
        field.stringValue = name
        (field.currentEditor() as? NSTextView)?.string = name
        sheet.makeFirstResponder(nil)
    }
    parent.endSheet(sheet,returnCode: accept ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    rewriteWait { parent.attachedSheet == nil }
}

@MainActor
func recipeSnapshot(_ controller: RecipeWindowController, name: String) {
    guard let path = ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"], let window = controller.window, let root = window.contentView else { return }
    try! FileManager.default.createDirectory(atPath: path,withIntermediateDirectories: true)
    func invalidate(_ view: NSView) { view.needsDisplay = true; view.needsLayout = true; view.subviews.forEach(invalidate) }
    for (label,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
        window.appearance = NSAppearance(named: appearance); invalidate(root); root.layoutSubtreeIfNeeded()
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!; root.cacheDisplay(in: root.bounds,to: bitmap)
            try! bitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent("recipes-\(name)-\(label).png"))
        }
    }
}

import AppKit

private let exampleRuleFixture = #"{"version":1,"input":"json","delimiter":"","format":"text","parts":[{"field":"/name","casing":"keep","trim":false,"encoding":"text","prefix":"","suffix":" — /users/"},{"field":"/id","casing":"keep","trim":false,"encoding":"text","prefix":"","suffix":""}]}"#

private final class ExampleVault: AICredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let key: String?
    init(_ key: String? = "synthetic-example-key") { self.key = key }
    var loads: Int { lock.withLock { count } }
    func load() throws -> String? { lock.withLock { count += 1; return key } }
    func save(_ key: String) throws { preconditionFailure() }
    func remove() throws { preconditionFailure() }
}
private actor ExampleProvider: AIExampleLearning {
    var pairs: [(String,String)] = []
    var hold = false
    var output = exampleRuleFixture
    var failure: AIConnectionError?
    var pending: [CheckedContinuation<Void,Never>] = []
    func configure(hold: Bool = false, output: String = exampleRuleFixture, failure: AIConnectionError? = nil) {
        self.hold = hold; self.output = output; self.failure = failure
    }
    func count() -> Int { pairs.count }
    func contains(_ text: String) -> Bool { pairs.contains { $0.0.contains(text) || $0.1.contains(text) } }
    func finish() { let work = pending; pending = []; work.forEach { $0.resume() } }
    func inferRecipe(key: String, model: AIModel, before: String, after: String) async throws -> String {
        precondition(key == "synthetic-example-key")
        pairs.append((before,after))
        if hold { await withCheckedContinuation { pending.append($0) } }
        if let failure { throw failure }
        return output
    }
}
@MainActor
private func exampleAwait<T>(_ operation: @escaping () async throws -> T) throws -> T {
    var result: Result<T,Error>?
    Task { do { result = .success(try await operation()) } catch { result = .failure(error) } }
    rewriteWait { result != nil }; return try result!.get()
}
@MainActor
func exampleSmokeTest() {
    _ = NSApplication.shared
    let suite = "dev.vibechar.example-smoke.\(UUID().uuidString)"
    // The suite is isolated; no production key, preferences or recovery is loaded.
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    let vault = ExampleVault(), service = ExampleProvider(), session = RustSession()
    let document = RustDocument(session: session)
    let source = "OUTSIDE\n{\"id\":42,\"name\":\"Anna\"}\r\n{\"id\":7,\"name\":\"LOCAL_ONLY_BOB\"}\nnot json\n\r\n{\"name\":\"missing id\"}\nTAIL"
    let selected = (source as NSString).range(of: "{\"id\":42,\"name\":\"Anna\"}\r\n{\"id\":7,\"name\":\"LOCAL_ONLY_BOB\"}\nnot json\n\r\n{\"name\":\"missing id\"}\n")
    session.open(source); document.markSaved()
    func make(_ store: AICredentialStore? = nil) -> ExampleModel { try! ExampleModel(session: session,target: selected,vault: store ?? vault,service: service,defaults: prefs) }
    var model = make()
    precondition(vault.loads == 0 && !model.canLearn && model.frame!.records == 4)
    model.editAfter("Anna — /users/42"); model.learn(); rewriteWait { model.phase == .preview || model.phase == .error }
    precondition(model.phase == .preview && model.canApply && document.text == source)
    precondition(model.frame!.stats!.matched == 2 && model.frame!.stats!.skipped == 2 && model.frame!.stats!.blank == 1)
    precondition(!(try! exampleAwait { await service.contains("LOCAL_ONLY_BOB") }))
    precondition(!(try! exampleAwait { await service.contains("OUTSIDE") }))
    let expected = "OUTSIDE\nAnna — /users/42\r\nLOCAL_ONLY_BOB — /users/7\nnot json\n\r\n{\"name\":\"missing id\"}\nTAIL"
    model.apply(); precondition(document.text == expected && model.phase == .closed && model.after.isEmpty && model.frame == nil)
    precondition(document.history(redo: false) != nil && document.text == source && !document.isDirty)
    precondition(!String(describing: prefs.persistentDomain(forName: suite)).contains("Anna"))

    model = make(ExampleVault(nil)); model.editAfter("Anna — /users/42"); model.learn(); rewriteWait { model.phase == .error }
    precondition(model.status.contains("Settings") && document.text == source); model.close()
    try! exampleAwait { await service.configure(output: "{invalid}") }
    model = make(); model.editAfter("Anna — /users/42"); model.learn(); rewriteWait { model.phase == .error }
    precondition(!model.canApply && document.text == source); model.close()
    try! exampleAwait { await service.configure(failure: .quota) }
    model = make(); model.editAfter("Anna — /users/42"); model.learn(); rewriteWait { model.phase == .error }
    precondition(document.text == source); model.close()

    try! exampleAwait { await service.configure(hold: true) }
    for action in 0..<4 {
        let count = try! exampleAwait { await service.count() }
        model = make(); model.editAfter("Anna — /users/42"); model.learn()
        rewriteWait { (try! exampleAwait { await service.count() }) == count+1 }
        if action == 0 { model.cancel() }
        else if action == 1 { model.editAfter("A different example") }
        else if action == 2 { model.close() }
        else { precondition(document.replace(NSRange(location: 0,length: 0),with: "!")); model.sourceChanged(); precondition(model.phase == .stale) }
        try! exampleAwait { await service.finish() }
        precondition(!model.canApply && model.frame?.result == nil)
        model.close()
        if action == 3 { precondition(document.history(redo: false) != nil && document.text == source) }
    }
    let reads = vault.loads
    session.openPrivate(); precondition(document.replace(NSRange(location: 0,length: 0),with: "PRIVATE\nEXAMPLE"))
    do { _ = try ExampleModel(session: session,target: NSRange(location: 0,length: 15),vault: vault,service: service,defaults: prefs); preconditionFailure() }
    catch { precondition(vault.loads == reads) }
    print("Do the Rest smoke: model, cancellation and private-exclusion fixtures passed")
    exampleHTTPTest()
    print("Do the Rest smoke: HTTP fixture passed; testing native recipe sheets")
    try! exampleAwait { await service.configure() }
    AppDelegate.exampleIntegrationSmokeTest { session,target in try ExampleModel(session: session,target: target,vault: vault,service: service,defaults: prefs) }
    print("Do the Rest native smoke passed: example-only requests, structured schema, local recipe validation, counts/skips, stale/cancel, native apply/Undo/Redo, private exclusion and cleanup")
}

@MainActor
private func exampleHTTPTest() {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPFixture.self]
    let client = OpenAIClient(configuration: config)
    defer { AIHTTPFixture.reset() }
    AIHTTPFixture.respond { request in
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0,count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&bytes,maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
        }
        let json = try! JSONSerialization.jsonObject(with: body) as! [String:Any]
        let pair = try! JSONSerialization.jsonObject(with: Data((json["input"] as! String).utf8)) as! [String:String]
        precondition(pair == ["before":"{\"id\":42,\"name\":\"Anna\"}","after":"Anna — /users/42"])
        precondition(Set(json.keys) == ["input","instructions","model","store","max_output_tokens","reasoning","text"])
        precondition(json["store"] as? Bool == false && json["model"] as? String == AIModel.catalog[1].id && json["max_output_tokens"] as? Int == 4096)
        let format = (json["text"] as! [String:Any])["format"] as! [String:Any]
        precondition(format["strict"] as? Bool == true && format["name"] as? String == "vibechar_recipe_v1" && format["type"] as? String == "json_schema")
        let schema = format["schema"] as! [String:Any]
        precondition(schema["additionalProperties"] as? Bool == false)
        precondition(Set(schema["required"] as! [String]) == ["version","input","delimiter","format","parts"])
        precondition(request.url?.absoluteString == "https://api.openai.com/v1/responses" && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-example-key")
        return .init(body: try! JSONSerialization.data(withJSONObject: ["status":"completed","output":[["type":"message","content":[["type":"output_text","text":exampleRuleFixture]]]]]))
    }
    let result = try! exampleAwait { try await client.inferRecipe(key: "synthetic-example-key",model: AIModel.catalog[1],before: "{\"id\":42,\"name\":\"Anna\"}",after: "Anna — /users/42") }
    precondition(result == exampleRuleFixture)
}

@MainActor
func exampleSnapshot(_ controller: ExampleWindowController, name: String) {
    guard let path = ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"], let window = controller.window, let root = window.contentView else { return }
    try! FileManager.default.createDirectory(atPath: path,withIntermediateDirectories: true)
    func invalidate(_ view: NSView) { view.needsDisplay = true; view.needsLayout = true; view.subviews.forEach(invalidate) }
    for (label,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
        window.appearance = NSAppearance(named: appearance); invalidate(root); root.layoutSubtreeIfNeeded()
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!; root.cacheDisplay(in: root.bounds,to: bitmap)
            try! bitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent("examples-\(name)-\(label).png"))
        }
    }
}

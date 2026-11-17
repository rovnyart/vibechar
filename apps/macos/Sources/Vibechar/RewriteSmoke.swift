import AppKit

private final class RewriteVault: AICredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let key: String?
    init(_ key: String? = "synthetic-rewrite-key") { self.key = key }
    var loads: Int { lock.withLock { count } }
    func load() throws -> String? { lock.withLock { count += 1; return key } }
    func save(_ key: String) throws { preconditionFailure("Rewrite must not change credentials") }
    func remove() throws { preconditionFailure("Rewrite must not change credentials") }
}

private actor RewriteProvider: AIRewriting {
    var requests: [String] = []
    var hold = false
    var failure: AIConnectionError?
    var output: String?
    var pending: [CheckedContinuation<Void,Never>] = []
    func configure(hold: Bool = false, failure: AIConnectionError? = nil, output: String? = nil) {
        self.hold = hold; self.failure = failure; self.output = output
    }
    func count() -> Int { requests.count }
    func contains(_ text: String) -> Bool { requests.contains { $0.contains(text) } }
    func finish() { let work = pending; pending = []; work.forEach { $0.resume() } }
    func rewrite(key: String, model: AIModel, instruction: String, text: String) async throws -> String {
        precondition(key == "synthetic-rewrite-key")
        requests.append(text)
        if hold { await withCheckedContinuation { pending.append($0) } }
        if let failure { throw failure }
        return output ?? text.replacingOccurrences(of: "Hello",with: "Hi").replacingOccurrences(of: "hello",with: "Hi")
    }
}

@MainActor
func rewriteWait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    precondition(condition(), "Rewrite fixture timed out")
}
@MainActor
private func rewriteAwait<T>(_ operation: @escaping () async throws -> T) throws -> T {
    var result: Result<T,Error>?
    Task { do { result = .success(try await operation()) } catch { result = .failure(error) } }
    rewriteWait { result != nil }; return try result!.get()
}

@MainActor
func rewriteSmokeTest() {
    _ = NSApplication.shared
    let suite = "dev.vibechar.rewrite-smoke.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(AIModel.defaultModel.id,forKey: AISettingsModel.modelPreference)
    let session = RustSession(), vault = RewriteVault(), service = RewriteProvider()
    let document = RustDocument(session: session)
    let original = "OUTSIDE_FIXTURE 🦀\r\nHello KEPT_FIXTURE!\r\nTRAILER_FIXTURE"
    session.open(original)
    document.markSaved()
    let target = (original as NSString).range(of: "Hello KEPT_FIXTURE!\r\n")
    func make(_ store: AICredentialStore? = nil) -> RewriteModel {
        try! RewriteModel(session: session,target: target,vault: store ?? vault,service: service,defaults: defaults)
    }
    var model = make()
    precondition(vault.loads == 0 && model.source == "Hello KEPT_FIXTURE!\r\n")
    model.protect((model.source as NSString).range(of: "KEPT_FIXTURE"))
    model.editInstruction("Make it shorter")
    model.generate(); rewriteWait { model.phase == .preview }
    precondition(document.text == original && model.result == "Hi KEPT_FIXTURE!\r\n")
    precondition(!(try! rewriteAwait { await service.contains("KEPT_FIXTURE") }))
    precondition(!(try! rewriteAwait { await service.contains("OUTSIDE_FIXTURE") }))
    model.apply()
    precondition(document.text == original.replacingOccurrences(of: "Hello",with: "Hi"))
    precondition(document.history(redo: false) != nil && document.text == original && !document.isDirty)
    precondition(model.phase == .closed && model.source.isEmpty && model.instruction.isEmpty)
    precondition(!String(describing: defaults.persistentDomain(forName: suite)).contains("FIXTURE"))

    let missing = RewriteVault(nil)
    model = make(missing); model.editInstruction("Shorter"); model.generate()
    rewriteWait { model.phase == .error }; precondition(model.status.contains("Settings") && document.text == original)
    model.close()
    try! rewriteAwait { await service.configure(failure: .refused) }
    model = make(); model.editInstruction("Shorter"); model.generate()
    rewriteWait { model.phase == .error }; precondition(document.text == original && model.result == nil)
    model.close()
    try! rewriteAwait { await service.configure(output: "Lost all protected fragments") }
    model = make(); model.protect((model.source as NSString).range(of: "KEPT_FIXTURE")); model.editInstruction("Shorter"); model.generate()
    rewriteWait { model.phase == .error }; model.apply(); precondition(document.text == original && model.result == nil)
    model.close()

    try! rewriteAwait { await service.configure(hold: true) }
    let before = try! rewriteAwait { await service.count() }
    model = make(); model.editInstruction("Shorter"); model.generate()
    rewriteWait { (try! rewriteAwait { await service.count() }) == before + 1 }
    precondition(document.replace(NSRange(location: 0,length: 0),with: "!"))
    model.sourceChanged(); precondition(model.phase == .stale)
    try! rewriteAwait { await service.finish() }; model.apply()
    precondition(document.text == "!"+original && model.result == nil)
    precondition(document.history(redo: false) != nil && document.text == original)
    model.close()

    for action in 0..<3 {
        let count = try! rewriteAwait { await service.count() }
        model = make(); model.editInstruction("Shorter"); model.generate()
        rewriteWait { (try! rewriteAwait { await service.count() }) == count + 1 }
        if action == 0 { model.cancel() }
        else if action == 1 { model.editInstruction("A new instruction") }
        else { model.close() }
        try! rewriteAwait { await service.finish() }
        precondition(model.result == nil && document.text == original)
        model.close()
    }
    let reads = vault.loads
    session.openPrivate(); precondition(document.replace(NSRange(location: 0,length: 0),with: "PRIVATE_REWRITE_FIXTURE"))
    do { _ = try RewriteModel(session: session,target: NSRange(location: 0,length: 7),vault: vault,service: service,defaults: defaults); preconditionFailure() }
    catch { precondition(vault.loads == reads) }

    let diff = RewriteDiff(before: "same\r\nold\r\ntail",after: "same\r\nnew\r\ntail")
    precondition(diff.added == 1 && diff.removed == 1 && !diff.coarse && diff.lines.count == 4)
    precondition(diff.lines.map(\.displayText).joined() == "same\nold\nnew\ntail\n")
    precondition(RewriteDiff(before: "",after: "x").added == 1)
    precondition(RewriteDiff(before: "x",after: "").removed == 1)
    precondition(RewriteDiff(before: "same",after: "same").added == 0)
    let large = RewriteDiff(before: String(repeating: "old\n",count: 600),after: String(repeating: "new\n",count: 600))
    precondition(large.coarse && large.added == 600 && large.removed == 600)
    let capped = RewriteDiff(before: String(repeating: "context\n",count: 5000)+"old\n",after: String(repeating: "context\n",count: 5000)+String(repeating: "new\n",count: 5000))
    precondition(capped.partial && capped.displayStart == 4997 && capped.added == 5000)
    rewriteHTTPTest()
    try! rewriteAwait { await service.configure() }
    AppDelegate.rewriteIntegrationSmokeTest { session,target in
        try RewriteModel(session: session,target: target,vault: vault,service: service,defaults: defaults)
    }
    print("Rewrite native smoke passed: selection-only requests, protected fragments, errors, stale/cancel/reject, diff, native apply/Undo/Redo, private exclusion and transient UI")
}

@MainActor
private func rewriteHTTPTest() {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPFixture.self]
    let client = OpenAIClient(configuration: config)
    defer { AIHTTPFixture.reset() }
    let requestText = "Hello [[VIBECHAR_KEEP_123_0]]"
    AIHTTPFixture.respond { request in
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0,count: 4096)
            while stream.hasBytesAvailable { let size = stream.read(&buffer,maxLength: buffer.count); if size <= 0 { break }; body.append(contentsOf: buffer.prefix(size)) }
        }
        let json = try! JSONSerialization.jsonObject(with: body) as! [String:Any]
        let input = try! JSONSerialization.jsonObject(with: Data((json["input"] as! String).utf8)) as! [String:String]
        precondition(input == ["instruction":"Shorter","text":requestText])
        precondition(json["store"] as? Bool == false && json["max_output_tokens"] as? Int == 16_384)
        precondition(json["model"] as? String == AIModel.catalog[1].id)
        precondition((json["reasoning"] as? [String:String])?["effort"] == "low")
        precondition(Set(json.keys) == ["model","store","max_output_tokens","reasoning","instructions","input"])
        precondition(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-rewrite-key")
        let data = try! JSONSerialization.data(withJSONObject: ["status":"completed","output":[["type":"message","content":[["type":"output_text","text":"Hi [[VIBECHAR_KEEP_123_0]]"]]]]])
        return .init(body: data)
    }
    let result = try! rewriteAwait { try await client.rewrite(key: "synthetic-rewrite-key",model: AIModel.catalog[1],instruction: "Shorter",text: requestText) }
    precondition(result == "Hi [[VIBECHAR_KEEP_123_0]]")
    let empty = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":""}]}]}"#.utf8)
    precondition((try! OpenAIClient.responseText(empty)).isEmpty)
}

@MainActor
func rewriteSnapshot(_ controller: RewriteWindowController, name: String) {
    guard let path = ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"], let window = controller.window, let root = window.contentView else { return }
    try! FileManager.default.createDirectory(atPath: path,withIntermediateDirectories: true)
    func invalidate(_ view: NSView) { view.needsDisplay = true; view.needsLayout = true; view.subviews.forEach(invalidate) }
    for (label,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
        window.appearance = NSAppearance(named: appearance); invalidate(root); root.layoutSubtreeIfNeeded()
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds,to: bitmap)
            try! bitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent("rewrite-\(name)-\(label).png"))
        }
    }
}

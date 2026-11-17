import AppKit

private final class AIFixtureVault: AICredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var failSave = false
    private(set) var loads = 0
    init(_ key: String? = nil) { self.key = key }
    func load() throws -> String? { lock.withLock { loads += 1; return key } }
    func save(_ value: String) throws {
        try lock.withLock { if failSave { throw AIConnectionError.keychain }; key = value }
    }
    func remove() throws { lock.withLock { key = nil } }
    func failWrites(_ fail: Bool) { lock.withLock { failSave = fail } }
}

private actor AIFixtureService: AIService {
    var tests = 0
    var lists = 0
    var failure: AIConnectionError?
    var suspended = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func configure(failure: AIConnectionError? = nil, suspended: Bool = false) {
        self.failure = failure; self.suspended = suspended
    }
    func counts() -> (Int, Int) { (tests, lists) }
    func finish() { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    func models(key: String) async throws -> Set<String> {
        lists += 1
        if let failure { throw failure }
        return [AIModel.defaultModel.id]
    }
    func test(key: String, model: AIModel) async throws {
        tests += 1
        if suspended { await withCheckedContinuation { waiters.append($0) } }
        if let failure { throw failure }
        // Deliberately ignores cancellation: the coordinator must reject stale results.
    }
}

final class AIHTTPFixture: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var body: Data; var error: URLError?; var hold = false }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var started = 0
    private static var stopped = 0
    static var counts: (Int, Int) { lock.withLock { (started, stopped) } }
    static func respond(_ handler: @escaping (URLRequest) -> Reply) { lock.withLock { self.handler = handler; started = 0; stopped = 0 } }
    static func reset() { lock.withLock { handler = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.started += 1 }
        guard let handler = Self.lock.withLock({ Self.handler }) else { preconditionFailure("Unexpected AI fixture request") }
        let reply = handler(request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                                           httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        if reply.hold { return }
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.stopped += 1 } }
}

@MainActor
private func aiWait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    precondition(condition(), "AI fixture timed out")
}

@MainActor
private func aiAwait<T>(_ operation: @escaping () async throws -> T) throws -> T {
    var result: Result<T, Error>?
    Task { do { result = .success(try await operation()) } catch { result = .failure(error) } }
    aiWait { result != nil }
    return try result!.get()
}

@MainActor
func aiSettingsSmokeTest() {
    _ = NSApplication.shared
    let suite = "dev.vibechar.ai-smoke.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let vault = AIFixtureVault("synthetic-old-key")
    let service = AIFixtureService()
    let model = AISettingsModel(vault: vault, service: service, defaults: defaults)
    precondition(vault.loads == 0, "Creating Settings must not read Keychain")
    model.open(); aiWait { model.phase == .idle }
    precondition(model.hasSavedKey && model.draftKey.isEmpty)
    precondition(model.savedKeyPreview == "…-key")
    precondition(AISettingsModel.maskedKeyPreview("sk-proj-synthetic-Ab12") == "sk-…Ab12")
    precondition(AISettingsModel.maskedKeyPreview("arbitrary-secret-CD34") == "…CD34")
    for key in ["", "sk-", "sk-Ab12", "12345678901"] {
        precondition(AISettingsModel.maskedKeyPreview(key) == "••••••••")
    }
    precondition(try! aiAwait { await service.counts() } == (0, 0), "Opening Settings must not contact OpenAI")

    model.editKey("synthetic-new-key"); model.select(AIModel.catalog[1])
    try! aiAwait { await service.configure(failure: .authentication) }
    model.testAndSave(); aiWait { model.phase == .idle }
    precondition(model.tone == .error && (try! vault.load()) == "synthetic-old-key")
    precondition(defaults.string(forKey: AISettingsModel.modelPreference) == nil)
    try! aiAwait { await service.configure() }
    vault.failWrites(true)
    model.testAndSave(); aiWait { model.phase == .idle }
    precondition(model.tone == .error && (try! vault.load()) == "synthetic-old-key")
    precondition(defaults.string(forKey: AISettingsModel.modelPreference) == nil)
    vault.failWrites(false)
    model.testAndSave(); aiWait { model.phase == .idle }
    precondition(model.tone == .success && model.draftKey.isEmpty)
    precondition((try! vault.load()) == "synthetic-new-key")
    precondition(defaults.string(forKey: AISettingsModel.modelPreference) == AIModel.catalog[1].id)
    precondition(!String(describing: defaults.persistentDomain(forName: suite)).contains("synthetic-"))
    model.close(); precondition(!model.hasSavedKey && model.draftKey.isEmpty && model.savedKeyPreview == nil)
    model.open(); aiWait { model.phase == .idle }
    precondition(model.hasSavedKey && model.selectedModel == AIModel.catalog[1])

    try! aiAwait { await service.configure(failure: .modelListDenied) }
    model.refresh(); aiWait { model.phase == .idle }
    precondition(model.canConnect && model.status == AIConnectionError.modelListDenied.localizedDescription)
    try! aiAwait { await service.configure() }
    model.refresh(); aiWait { model.phase == .idle }
    precondition(model.availableModels == [AIModel.defaultModel.id] && model.selectedModel == AIModel.catalog[1])
    model.close(); precondition(model.availableModels == nil)
    model.open(); aiWait { model.phase == .idle }
    model.testAndSave(); aiWait { model.phase == .idle }; precondition(model.tone == .success)

    // A late successful response may neither save the old draft nor show Connected.
    try! aiAwait { await service.configure(suspended: true) }
    model.editKey("synthetic-stale-key"); model.testAndSave()
    aiWait { (try! aiAwait { await service.counts() }).0 == 5 }
    model.editKey("synthetic-current-key")
    try! aiAwait { await service.finish() }
    precondition(model.phase == .idle && model.tone == .neutral && model.draftKey == "synthetic-current-key")
    precondition((try! vault.load()) == "synthetic-new-key")
    model.testAndSave()
    aiWait { (try! aiAwait { await service.counts() }).0 == 6 }
    model.select(AIModel.defaultModel); try! aiAwait { await service.finish() }
    precondition(defaults.string(forKey: AISettingsModel.modelPreference) == AIModel.catalog[1].id)
    model.testAndSave()
    aiWait { (try! aiAwait { await service.counts() }).0 == 7 }
    model.cancel(); try! aiAwait { await service.finish() }
    precondition(model.phase == .idle && model.tone == .neutral)
    model.testAndSave()
    aiWait { (try! aiAwait { await service.counts() }).0 == 8 }
    model.close(); try! aiAwait { await service.finish() }
    precondition(!model.hasSavedKey && model.draftKey.isEmpty && (try! vault.load()) == "synthetic-new-key")
    model.open(); aiWait { model.phase == .idle }
    model.testAndSave()
    aiWait { (try! aiAwait { await service.counts() }).0 == 9 }
    model.removeKey(); aiWait { model.phase == .idle }; try! aiAwait { await service.finish() }
    precondition(!model.hasSavedKey && !model.canConnect && (try! vault.load()) == nil)
    model.close()

    aiHTTPClientSmokeTest()
    aiKeychainSmokeTest()
    let uiService = AIFixtureService()
    let uiVault = AIFixtureVault()
    let controller = AISettingsWindowController(model: AISettingsModel(vault: uiVault, service: uiService, defaults: defaults))
    controller.model.open(); aiWait { controller.model.phase == .idle }
    precondition(controller.keyField.stringValue.isEmpty)
    precondition(controller.testButton.keyEquivalentModifierMask == [.command])
    controller.searchField.stringValue = "no-matching-model"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.searchField))
    precondition(controller.table.numberOfRows == 0)
    controller.searchField.stringValue = "terra"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.searchField))
    precondition(controller.table.numberOfRows == 1)
    _ = controller.control(controller.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    precondition(controller.model.selectedModel.id == "gpt-6.1-terra")
    precondition(try! aiAwait { await uiService.counts() } == (0, 0))
    controller.searchField.stringValue = ""
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.searchField))
    controller.keyField.stringValue = "sk-proj-synthetic-ui-key-Ab12"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.keyField))
    aiSettingsSnapshot(controller, name: "ready")
    try! aiAwait { await uiService.configure(failure: .quota) }
    controller.testButton.performClick(nil); aiWait { controller.model.phase == .idle }
    precondition(controller.model.tone == .error && controller.keyField.stringValue == "sk-proj-synthetic-ui-key-Ab12")
    aiSettingsSnapshot(controller, name: "error")
    try! aiAwait { await uiService.configure() }
    controller.testButton.performClick(nil); aiWait { controller.model.phase == .idle }
    precondition(controller.model.tone == .success && controller.keyField.stringValue.isEmpty)
    precondition(controller.keyField.isHidden && !controller.savedKeyField.isHidden)
    precondition(controller.savedKeyField.stringValue == "sk-…Ab12")
    controller.refreshButton.performClick(nil); aiWait { controller.model.phase == .idle }
    aiSettingsSnapshot(controller, name: "connected")

    // Replacement has a blank secure input; the visible mask never becomes a candidate.
    controller.replaceButton.performClick(nil)
    precondition(!controller.keyField.isHidden && controller.savedKeyField.isHidden)
    precondition(controller.keyField.stringValue.isEmpty && !controller.testButton.isEnabled)
    controller.keyField.stringValue = "sk-proj-synthetic-replacement-CD34"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.keyField))
    try! aiAwait { await uiService.configure(failure: .quota) }
    controller.testButton.performClick(nil); aiWait { controller.model.phase == .idle }
    precondition(controller.model.savedKeyPreview == "sk-…Ab12")
    controller.replaceButton.performClick(nil)
    precondition(controller.keyField.isHidden && controller.keyField.stringValue.isEmpty)
    precondition(controller.savedKeyField.stringValue == "sk-…Ab12" && controller.testButton.isEnabled)
    precondition((try! uiVault.load()) == "sk-proj-synthetic-ui-key-Ab12")
    controller.replaceButton.performClick(nil)
    controller.keyField.stringValue = "sk-proj-synthetic-replacement-CD34"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.keyField))
    try! aiAwait { await uiService.configure() }
    controller.testButton.performClick(nil); aiWait { controller.model.phase == .idle }
    precondition(controller.keyField.isHidden && controller.savedKeyField.stringValue == "sk-…CD34")
    controller.shutdown()
    precondition(controller.savedKeyField.stringValue.isEmpty && controller.model.savedKeyPreview == nil)
    controller.model.open(); aiWait { controller.model.phase == .idle }
    precondition(!controller.savedKeyField.isHidden && controller.savedKeyField.stringValue == "sk-…CD34")
    precondition(controller.keyField.stringValue.isEmpty)
    aiSettingsSnapshot(controller, name: "reopened")
    controller.removeButton.performClick(nil); aiWait { controller.model.phase == .idle }
    precondition(!controller.keyField.isHidden && controller.savedKeyField.stringValue.isEmpty && controller.replaceButton.isHidden)
    precondition((try! uiVault.load()) == nil)
    controller.keyField.stringValue = "synthetic-ui-close"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.keyField))
    AppDelegate.aiSettingsMenuSmokeTest(controller: controller)
    precondition(controller.keyField.stringValue.isEmpty && controller.model.draftKey.isEmpty)
    precondition(try! aiAwait { await uiService.counts() } == (4, 1))
    controller.shutdown()
    print("AI settings native smoke passed: isolated Keychain, HTTP fixtures, safe failures, replacement, stale checks, cancellation, model search and menu routing")
}

@MainActor
private func aiKeychainSmokeTest() {
    let vault = KeychainAIStore(service: "dev.vibechar.ai-smoke.\(UUID().uuidString)")
    defer { try! vault.remove() }
    precondition((try! vault.load()) == nil)
    try! vault.save("synthetic-keychain-a"); precondition((try! vault.load()) == "synthetic-keychain-a")
    try! vault.save("synthetic-keychain-b"); precondition((try! vault.load()) == "synthetic-keychain-b")
    try! vault.remove(); precondition((try! vault.load()) == nil)
    try! vault.remove()
}

@MainActor
private func aiHTTPClientSmokeTest() {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPFixture.self]
    let client = OpenAIClient(configuration: config)
    defer { AIHTTPFixture.reset() }
    let completed = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#.utf8)
    AIHTTPFixture.respond { request in
        precondition(request.url?.absoluteString == "https://api.openai.com/v1/responses" && request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-http-key")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count)) }
        }
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        precondition(json["input"] as? String == OpenAIClient.testPrompt && json["store"] as? Bool == false)
        precondition(json["max_output_tokens"] as? Int == 128 && json["model"] as? String == AIModel.defaultModel.id)
        precondition(Set(json.keys) == ["model", "input", "store", "max_output_tokens", "reasoning"])
        return .init(body: completed)
    }
    try! aiAwait { try await client.test(key: "synthetic-http-key", model: .defaultModel) }
    AIHTTPFixture.respond { request in
        precondition(request.url?.path == "/v1/models" && request.httpMethod == "GET")
        return .init(body: Data(#"{"data":[{"id":"gpt-6-luna"},{"id":"unrelated-audio-model"}]}"#.utf8))
    }
    precondition(try! aiAwait { try await client.models(key: "synthetic-http-key") } == [AIModel.defaultModel.id])
    let cases: [(Int, String, AIConnectionError)] = [
        (401, "{}", .authentication), (403, "{}", .modelAccess), (404, "{}", .modelUnavailable),
        (429, #"{"error":{"code":"insufficient_quota","message":"synthetic-http-key"}}"#, .quota),
        (429, "{}", .rateLimit), (503, "{}", .unavailable), (400, "{}", .requestRejected),
        (200, "not json", .invalidResponse), (200, #"{"status":"incomplete","output":[]}"#, .invalidResponse),
        (200, #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal"}]}]}"#, .refused),
        (302, "{}", .requestRejected),
    ]
    for (status, body, expected) in cases {
        AIHTTPFixture.respond { _ in .init(status: status, body: Data(body.utf8)) }
        do { try aiAwait { try await client.test(key: "synthetic-http-key", model: .defaultModel) }; preconditionFailure("Expected safe API error") }
        catch { precondition(error as? AIConnectionError == expected && !error.localizedDescription.contains("synthetic-http-key")) }
    }
    AIHTTPFixture.respond { _ in .init(status: 403, body: Data("{}".utf8)) }
    do { _ = try aiAwait { try await client.models(key: "synthetic-http-key") }; preconditionFailure() }
    catch { precondition(error as? AIConnectionError == .modelListDenied) }
    for (code, expected) in [(URLError.timedOut, AIConnectionError.timeout), (.notConnectedToInternet, .network)] {
        AIHTTPFixture.respond { _ in .init(body: Data(), error: URLError(code)) }
        do { try aiAwait { try await client.test(key: "synthetic-http-key", model: .defaultModel) }; preconditionFailure() }
        catch { precondition(error as? AIConnectionError == expected) }
    }
    AIHTTPFixture.respond { _ in .init(body: Data(repeating: 32, count: OpenAIClient.responseLimit + 1)) }
    do { try aiAwait { try await client.test(key: "synthetic-http-key", model: .defaultModel) }; preconditionFailure() }
    catch { precondition(error as? AIConnectionError == .invalidResponse) }
    AIHTTPFixture.respond { _ in .init(body: Data(), hold: true) }
    var cancelled = false
    let pending = Task {
        do { try await client.test(key: "synthetic-http-key", model: .defaultModel); preconditionFailure() }
        catch is CancellationError { cancelled = true }
        catch { preconditionFailure("Cancellation must stay distinct from a connection failure") }
    }
    aiWait { AIHTTPFixture.counts.0 == 1 }
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    pending.cancel(); aiWait { cancelled && AIHTTPFixture.counts.1 > 0 }
    precondition((try! normalizedAIKey(" \nsynthetic-key\n")) == "synthetic-key")
    for key in ["", "key with spaces", "key\r\ninjection", "ключ", String(repeating: "x", count: 4097)] {
        do { _ = try normalizedAIKey(key); preconditionFailure() } catch { precondition(error as? AIConnectionError == .invalidKey) }
    }
    // Exercise the actual production redirect policy without contacting either host.
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: URL(string: "https://api.openai.com/v1/models")!)
    let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
    AIRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                 newRequest: URLRequest(url: URL(string: "https://example.com")!)) { precondition($0 == nil) }
    task.cancel()
}

@MainActor
private func aiSettingsSnapshot(_ controller: AISettingsWindowController, name: String) {
    guard let directory = ProcessInfo.processInfo.environment["VIBECHAR_INTERFACE_SNAPSHOTS"], let root = controller.window?.contentView else { return }
    try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        controller.window?.appearance = NSAppearance(named: appearance)
        (root as? PocketSurface)?.invalidateAppearance(in: root)
        root.layoutSubtreeIfNeeded()
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ai-\(name)-\(label).png"))
        }
    }
}

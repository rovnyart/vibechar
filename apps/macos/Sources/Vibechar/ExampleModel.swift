import Foundation
import CVibechar

func recipeSchema() -> String {
    let count = vc_recipe_schema(nil,0)
    var bytes = [UInt8](repeating: 0,count: count)
    precondition(bytes.withUnsafeMutableBufferPointer { vc_recipe_schema($0.baseAddress,$0.count) } == count)
    return String(decoding: bytes,as: UTF8.self)
}

@MainActor
final class RustExample {
    struct Frame: Decodable {
        struct Stats: Decodable {
            struct Issue: Decodable { let line: Int; let reason: String }
            let matched: Int; let changed: Int; let skipped: Int; let blank: Int; let issues: [Issue]
        }
        let source: String; let before: String; let example_line: Int; let records: Int
        let result: String?; let stats: Stats?; let rule: String?; let summary: String?; let explanation: String?; let error: String
    }
    private let handle: OpaquePointer
    private(set) var frame: Frame!
    let target: NSRange
    init(session: RustSession, target: NSRange, replay: Bool = false) throws {
        guard target.location != NSNotFound, target.location >= 0, target.length > 0,
              let handle = replay ? vc_recipe_new(session.handle,target.location,target.length) : vc_example_new(session.handle,target.location,target.length)
        else { throw RewriteFailure(message: "Select complete rows.") }
        self.handle = handle; self.target = target; refresh()
        if !frame.error.isEmpty { throw RewriteFailure(message: frame.error) }
    }
    deinit { vc_example_free(handle) }
    func isCurrent(_ session: RustSession) -> Bool { vc_example_valid(handle,session.handle) }
    private func refresh() {
        let count = vc_example_json(handle,nil,0)
        var bytes = [UInt8](repeating: 0,count: count)
        precondition(bytes.withUnsafeMutableBufferPointer { vc_example_json(handle,$0.baseAddress,$0.count) } == count)
        frame = try! JSONDecoder().decode(Frame.self,from: Data(bytes))
    }
    func clear() {
        vc_example_clear(handle)
        // Capture metadata is immutable. Editing After need not serialize/copy the
        // entire selected block on every keystroke merely to discard a preview.
        frame = Frame(source: frame.source,before: frame.before,example_line: frame.example_line,records: frame.records,
                      result: nil,stats: nil,rule: nil,summary: nil,explanation: nil,error: "")
    }
    func start(_ rule: String, after: String, session: RustSession) throws {
        let rule = Array(rule.utf8), after = Array(after.utf8)
        let ok = rule.withUnsafeBufferPointer { r in after.withUnsafeBufferPointer { a in
            vc_example_start(handle,session.handle,r.baseAddress,r.count,a.baseAddress,a.count)
        } }
        refresh(); if !ok { throw RewriteFailure(message: frame.error) }
    }
    func replay(_ rule: String, session: RustSession) throws {
        let rule = Array(rule.utf8)
        let ok = rule.withUnsafeBufferPointer { vc_recipe_start(handle,session.handle,$0.baseAddress,$0.count) }
        refresh(); if !ok { throw RewriteFailure(message: frame.error) }
    }
    func poll() -> Int32 { let state = vc_example_poll(handle); if state != 0 { refresh() }; return state }
    func apply(_ session: RustSession) throws -> (Bool,NSRange) {
        var start = 0, length = 0
        let state = vc_example_apply(handle,session.handle,&start,&length)
        refresh(); guard state != 0 else { throw RewriteFailure(message: frame.error) }
        return (state == 1,NSRange(location: start,length: length))
    }
}

@MainActor
final class ExampleModel {
    enum Phase { case ready, learning, planning, preview, error, stale, closed }
    private let session: RustSession
    private let service: AIExampleLearning?
    private let vault: AICredentialStore
    private let defaults: UserDefaults
    private var capture: RustExample?
    private var task: Task<Void,Never>?
    private var timer: Timer?
    private var generation: UInt = 0
    private(set) var after: String
    private(set) var phase: Phase = .ready
    private(set) var status = "Edit After to show the change. Your tab stays untouched until Apply."
    private(set) var usedModel: AIModel
    let savedRecipe: SavedRecipe?
    var isReplay: Bool { savedRecipe != nil }
    var onChange: (() -> Void)?
    var onApplied: ((NSRange,Bool,NSRange,String) -> Void)?
    var frame: RustExample.Frame? { capture?.frame }
    var busy: Bool { phase == .learning || phase == .planning }
    var validAfter: Bool { !after.isEmpty && after.utf8.count <= 4096 && !after.contains("\n") && !after.contains("\r") && after != frame?.before }
    var canLearn: Bool { !isReplay && phase != .closed && phase != .stale && validAfter }
    var canApply: Bool { phase == .preview && (frame?.stats?.matched ?? 0) >= (isReplay ? 1 : 2) && (frame?.stats?.changed ?? 0) > 0 }
    var canSave: Bool { !isReplay && phase == .preview && canApply && frame?.rule != nil }
    init(session: RustSession, target: NSRange, vault: AICredentialStore = KeychainAIStore(),
         service: AIExampleLearning? = nil, defaults: UserDefaults = .standard, savedRecipe: SavedRecipe? = nil) throws {
        let capture = try RustExample(session: session,target: target,replay: savedRecipe != nil)
        self.capture = capture; self.session = session; self.vault = vault
        self.service = service ?? (savedRecipe == nil ? OpenAIClient() : nil); self.defaults = defaults
        self.savedRecipe = savedRecipe; after = savedRecipe == nil ? capture.frame.before : ""
        usedModel = savedRecipe == nil ? AIModel.catalog.first { $0.id == defaults.string(forKey: AISettingsModel.modelPreference) } ?? .defaultModel : .defaultModel
        if let savedRecipe {
            try capture.replay(savedRecipe.rule,session: session)
            phase = .planning; status = "Running locally. No AI request or API key needed."
            startPolling()
        }
    }
    func editAfter(_ text: String) {
        guard !isReplay, phase != .closed, after != text else { return }
        stop(); capture?.clear(); after = text; sourceChanged()
        guard phase != .stale else { changed(); return }
        phase = .ready; status = validAfter ? "Ready. We'll learn from this pair, then run the rule locally." : "Show a changed, nonempty single row (up to 4 KiB)."
        changed()
    }
    func sourceChanged() {
        guard phase != .closed, phase != .stale, capture?.isCurrent(session) == false else { return }
        stop(); capture?.clear(); phase = .stale; status = "Text changed. Select the rows again to make a new preview."; changed()
    }
    func learn() {
        sourceChanged(); guard canLearn, let capture, let service else { return }
        stop(); capture.clear(); phase = .learning
        usedModel = AIModel.catalog.first { $0.id == defaults.string(forKey: AISettingsModel.modelPreference) } ?? .defaultModel
        status = "Asking \(usedModel.title) for a rule. Only this before/after pair is sent."; changed()
        let current = generation, before = capture.frame.before, after = after, vault = vault, model = usedModel
        task = Task { [weak self] in
            do {
                let key = try await Task.detached { try vault.load() }.value
                guard let self, self.generation == current else { return }
                self.sourceChanged(); guard self.phase == .learning else { return }
                guard let key else { throw RewriteFailure(message: "Connect OpenAI in Settings first.") }
                let rule = try await service.inferRecipe(key: key,model: model,before: before,after: after)
                guard self.generation == current else { return }
                self.sourceChanged(); guard self.phase == .learning else { return }
                try self.capture?.start(rule,after: after,session: self.session)
                self.task = nil; self.phase = .planning; self.status = "Checking the example and applying the rule locally…"; self.changed()
                self.startPolling()
            } catch {
                guard let self, self.generation == current, self.phase != .closed else { return }
                self.sourceChanged(); guard self.phase != .stale else { return }
                self.task = nil; self.report(error); self.changed()
            }
        }
    }
    func poll() {
        sourceChanged(); guard phase == .planning, let capture else { return }
        let state = capture.poll(); guard state != 0 else { return }
        timer?.invalidate(); timer = nil
        if state < 0 { report(RewriteFailure(message: capture.frame.error)) }
        else {
            phase = .preview
            let stats = capture.frame.stats!
            if isReplay && stats.matched == 0 { status = "No rows matched this recipe. Your selection is unchanged." }
            else if !isReplay && stats.matched < 2 { status = "Only the example matched. Adjust the example or selection; Apply needs at least one other matching row." }
            else { status = "\(stats.changed) changed · \(stats.skipped) skipped · \(stats.matched-stats.changed) unchanged. Review before Apply · one Undo." }
        }
        changed()
    }
    func cancel() { guard busy else { return }; stop(); capture?.clear(); phase = .ready; status = "Cancelled. Your tab is unchanged."; changed() }
    func apply() {
        sourceChanged(); guard canApply, let capture, let text = capture.frame.result else { return }
        do { let (changed,range) = try capture.apply(session); let target = capture.target; close(); onApplied?(range,changed,target,text) }
        catch { report(error); changed() }
    }
    func close() { stop(); capture = nil; after = ""; phase = .closed; status = ""; changed() }
    func recipeToSave() throws -> String {
        sourceChanged()
        guard canSave, let rule = frame?.rule else { throw RewriteFailure(message: "Make a current, validated preview before saving its rule.") }
        return rule
    }
    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.02,repeats: true) { [weak self] timer in
            MainActor.assumeIsolated { guard let self else { timer.invalidate(); return }; self.poll() }
        }
    }
    private func stop() { generation &+= 1; task?.cancel(); task = nil; timer?.invalidate(); timer = nil }
    private func report(_ error: Error) { phase = .error; status = (error as? RewriteFailure)?.message ?? AIConnectionError.safe(error).localizedDescription }
    private func changed() { onChange?() }
}

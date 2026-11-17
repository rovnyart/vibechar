import Foundation
import CVibechar

struct RewriteFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class RustRewrite {
    struct Frame: Decodable {
        struct Kept: Decodable { let start: Int; let length: Int; var range: NSRange { NSRange(location: start, length: length) } }
        let source: String; let request: String; let result: String?; let protected: [Kept]; let error: String
    }
    private let handle: OpaquePointer
    private(set) var frame: Frame!
    let target: NSRange
    init(session: RustSession, target: NSRange) throws {
        guard target.location != NSNotFound, target.location >= 0, target.length > 0,
              let handle = vc_rewrite_new(session.handle, target.location, target.length) else {
            throw RewriteFailure(message: "Select some text to rewrite.")
        }
        self.handle = handle; self.target = target
        refresh()
        if !frame.error.isEmpty { throw RewriteFailure(message: frame.error) }
    }
    deinit { vc_rewrite_free(handle) }
    func isCurrent(_ session: RustSession) -> Bool { vc_rewrite_valid(handle, session.handle) }
    private func refresh() {
        let count = vc_rewrite_json(handle, nil, 0)
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(bytes.withUnsafeMutableBufferPointer { vc_rewrite_json(handle, $0.baseAddress, $0.count) } == count)
        frame = try! JSONDecoder().decode(Frame.self, from: Data(bytes))
    }
    func protect(_ range: NSRange) throws {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0 else { throw RewriteFailure(message: "Select a fragment in Source first.") }
        let ok = vc_rewrite_protect(handle, range.location, range.length); refresh()
        if !ok { throw RewriteFailure(message: frame.error) }
    }
    func clear(protection: Bool = false) { vc_rewrite_clear(handle, protection); refresh() }
    func propose(_ text: String) throws {
        let ok = text.utf8.withContiguousStorageIfAvailable { vc_rewrite_result(handle, $0.baseAddress, $0.count) }
            ?? Array(text.utf8).withUnsafeBufferPointer { vc_rewrite_result(handle, $0.baseAddress, $0.count) }
        refresh()
        if !ok { throw RewriteFailure(message: frame.error) }
    }
    func apply(_ session: RustSession) throws -> (Bool, NSRange) {
        var start = 0, length = 0
        let result = vc_rewrite_apply(handle, session.handle, &start, &length)
        refresh()
        guard result != 0 else { throw RewriteFailure(message: frame.error) }
        return (result == 1, NSRange(location: start, length: length))
    }
}

@MainActor
final class RewriteModel {
    enum Phase { case ready, generating, preview, error, stale, closed }
    private let session: RustSession
    private let vault: AICredentialStore
    private let service: AIRewriting
    private let defaults: UserDefaults
    private var capture: RustRewrite?
    private var task: Task<Void, Never>?
    private var generation: UInt = 0
    private(set) var phase: Phase = .ready
    private(set) var instruction = ""
    private(set) var status = "Describe the change. You'll review it before applying."
    private(set) var usedModel: AIModel
    var onChange: (() -> Void)?
    var onApplied: ((NSRange, Bool, NSRange, String) -> Void)?
    var source: String { capture?.frame.source ?? "" }
    var result: String? { capture?.frame.result }
    var protected: [RustRewrite.Frame.Kept] { capture?.frame.protected ?? [] }
    var busy: Bool { phase == .generating }
    var canGenerate: Bool { phase != .stale && phase != .closed && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && instruction.utf8.count <= 4096 }

    init(session: RustSession, target: NSRange, vault: AICredentialStore = KeychainAIStore(),
         service: AIRewriting = OpenAIClient(), defaults: UserDefaults = .standard) throws {
        capture = try RustRewrite(session: session, target: target)
        self.session = session; self.vault = vault; self.service = service; self.defaults = defaults
        usedModel = AIModel.catalog.first { $0.id == defaults.string(forKey: AISettingsModel.modelPreference) } ?? .defaultModel
    }
    func sourceChanged() {
        guard phase != .closed, phase != .stale, capture?.isCurrent(session) == false else { return }
        cancelTask(); capture?.clear(); phase = .stale
        status = "Text changed. Select it again to make a new preview."; changed()
    }
    func editInstruction(_ text: String) {
        guard phase != .closed, text != instruction else { return }
        cancelTask(); capture?.clear(); instruction = text
        sourceChanged(); guard phase != .stale else { changed(); return }
        phase = .ready
        status = text.utf8.count > 4096 ? "Keep your instruction under 4 KiB." : "Ready to preview. Your text stays unchanged until Apply."
        changed()
    }
    func protect(_ range: NSRange) {
        sourceChanged(); guard !busy, phase != .stale, phase != .closed else { return }
        do { try capture?.protect(range); phase = .ready; status = "Kept fragments stay local and must remain unchanged." }
        catch { report(error) }
        changed()
    }
    func clearProtection() {
        guard !busy, phase != .closed, phase != .stale else { return }
        capture?.clear(protection: true); phase = .ready; status = "Kept fragments cleared."; changed()
    }
    func generate() {
        sourceChanged(); guard canGenerate, let capture else { return }
        cancelTask(); capture.clear(); phase = .generating
        usedModel = AIModel.catalog.first { $0.id == defaults.string(forKey: AISettingsModel.modelPreference) } ?? .defaultModel
        status = "Asking \(usedModel.title)… You can keep editing your tab."; changed()
        let current = generation, vault = vault, service = service, request = capture.frame.request
        let instruction = instruction, model = usedModel
        task = Task { [weak self] in
            do {
                let key = try await Task.detached { try vault.load() }.value
                guard let self, self.generation == current else { return }
                self.sourceChanged(); guard self.phase == .generating else { return }
                guard let key else { throw RewriteFailure(message: "Connect OpenAI in Settings first.") }
                let output = try await service.rewrite(key: key, model: model, instruction: instruction, text: request)
                guard self.generation == current else { return }
                self.sourceChanged(); guard self.phase == .generating else { return }
                try self.capture?.propose(output)
                self.phase = .preview; self.task = nil
                self.status = self.result == self.source ? "No changes proposed." : "Review the changes. Apply replaces only your original selection · one Undo."
                self.changed()
            } catch {
                guard let self, self.generation == current, self.phase != .closed else { return }
                self.sourceChanged(); guard self.phase != .stale else { return }
                self.task = nil; self.report(error); self.changed()
            }
        }
    }
    func cancel() {
        guard busy else { return }
        cancelTask(); capture?.clear(); phase = .ready; status = "Cancelled. Your text is unchanged."; changed()
    }
    func apply() {
        sourceChanged(); guard phase == .preview, let capture, let output = capture.frame.result else { return }
        do {
            let (changed,range) = try capture.apply(session)
            let target = capture.target
            close(); onApplied?(range, changed, target, output)
        } catch { report(error); changed() }
    }
    func close() {
        cancelTask(); capture = nil; instruction = ""; phase = .closed; status = ""; changed()
    }
    private func cancelTask() { generation &+= 1; task?.cancel(); task = nil }
    private func report(_ error: Error) {
        phase = .error
        status = (error as? RewriteFailure)?.message ?? AIConnectionError.safe(error).localizedDescription
    }
    private func changed() { onChange?() }
}

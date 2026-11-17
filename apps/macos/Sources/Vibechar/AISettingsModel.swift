import Foundation

@MainActor
final class AISettingsModel {
    enum Phase { case idle, loading, refreshing, testing, saving, deleting }
    enum Tone { case neutral, success, error }
    static let modelPreference = "OpenAIModel"
    private let vault: AICredentialStore
    private let service: AIService
    private let defaults: UserDefaults
    private var savedKey: String?
    private var task: Task<Void, Never>?
    private var generation: UInt = 0
    private var isOpen = false
    private(set) var phase: Phase = .idle
    private(set) var draftKey = ""
    private(set) var selectedModel: AIModel
    private(set) var availableModels: Set<String>?
    private(set) var status = "Your key stays in this Mac's Keychain."
    private(set) var tone: Tone = .neutral
    var onChange: (() -> Void)?
    var hasSavedKey: Bool { savedKey != nil }
    var savedKeyPreview: String? { savedKey.map(Self.maskedKeyPreview) }

    static func maskedKeyPreview(_ key: String) -> String {
        // Never expose a whole short/malformed value, or an arbitrary secret prefix.
        guard key.count >= 12 else { return "••••••••" }
        return (key.hasPrefix("sk-") ? "sk-" : "") + "…" + key.suffix(4)
    }
    var committing: Bool { phase == .saving || phase == .deleting }
    var requesting: Bool { phase == .refreshing || phase == .testing }
    var editable: Bool { !committing && phase != .loading }
    var canConnect: Bool { editable && (!draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasSavedKey) }

    init(vault: AICredentialStore = KeychainAIStore(), service: AIService = OpenAIClient(),
         defaults: UserDefaults = .standard) {
        self.vault = vault; self.service = service; self.defaults = defaults
        selectedModel = AIModel.catalog.first { $0.id == defaults.string(forKey: Self.modelPreference) } ?? .defaultModel
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        if committing { changed(); return }
        invalidate()
        selectedModel = AIModel.catalog.first { $0.id == defaults.string(forKey: Self.modelPreference) } ?? .defaultModel
        phase = .loading; status = "Opening Keychain…"; tone = .neutral; changed()
        let current = generation, vault = vault
        task = Task { [weak self] in
            let result = await Task.detached { Result { try vault.load() } }.value
            guard let self, self.generation == current, self.isOpen else { return }
            self.phase = .idle; self.task = nil
            switch result {
            case .success(let key):
                self.savedKey = key
                self.status = key == nil ? "Add a key to connect your OpenAI account." : "Key stored. Test the model whenever you're ready."
            case .failure: self.status = AIConnectionError.keychain.localizedDescription; self.tone = .error
            }
            self.changed()
        }
    }

    func close() {
        isOpen = false
        if !committing { invalidate(); phase = .idle; savedKey = nil }
        draftKey = ""; availableModels = nil; changed()
    }

    func editKey(_ key: String) {
        guard editable else { return }
        invalidate(); phase = .idle; draftKey = key; availableModels = nil
        status = key.isEmpty ? "Choose a model, then Test & Save." : "New key ready to test. Your saved key is unchanged."
        tone = .neutral; changed()
    }

    func select(_ model: AIModel) {
        guard editable, model != selectedModel else { return }
        invalidate(); phase = .idle; selectedModel = model
        status = "Choose a model, then Test & Save."; tone = .neutral; changed()
    }

    func cancel() {
        guard requesting else { return }
        invalidate(); phase = .idle; status = "Cancelled. Your saved configuration is unchanged."; tone = .neutral; changed()
    }

    func refresh() {
        guard canConnect else { return }
        let key: String
        do { key = try candidate() } catch { show(error); return }
        invalidate(); phase = .refreshing; status = "Checking model availability…"; tone = .neutral; changed()
        let current = generation, service = service
        task = Task { [weak self] in
            do {
                let models = try await service.models(key: key)
                guard let self, self.generation == current, self.isOpen else { return }
                self.availableModels = models; self.phase = .idle; self.task = nil
                self.status = models.isEmpty ? "No supported models listed. You can still test the chosen model." : "Availability updated. Test & Save verifies the chosen model."
                self.tone = .neutral; self.changed()
            } catch {
                guard let self, self.generation == current, self.isOpen else { return }
                self.phase = .idle; self.task = nil; self.show(error)
            }
        }
    }

    func testAndSave() {
        guard canConnect else { return }
        let key: String
        do { key = try candidate() } catch { show(error); return }
        invalidate(); phase = .testing; status = "Testing \(selectedModel.title)…"; tone = .neutral; changed()
        let current = generation, service = service, vault = vault, model = selectedModel
        let replacing = !draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        task = Task { [weak self] in
            do {
                try await service.test(key: key, model: model)
                guard let self, self.generation == current, self.isOpen, !Task.isCancelled else { return }
                self.phase = .saving; self.status = "Saving connection…"; self.changed()
                if replacing { try await Task.detached { try vault.save(key) }.value }
                self.defaults.set(model.id, forKey: Self.modelPreference)
                self.savedKey = self.isOpen ? key : nil; self.draftKey = ""
                self.phase = .idle; self.task = nil
                self.status = "Connected to \(model.title). Saved on this Mac."; self.tone = .success; self.changed()
            } catch {
                guard let self, self.generation == current else { return }
                let wasSaving = self.phase == .saving
                self.phase = .idle; self.task = nil
                if !self.isOpen { self.savedKey = nil }
                self.show(wasSaving ? AIConnectionError.keychain : error)
            }
        }
    }

    func removeKey() {
        guard editable, hasSavedKey else { return }
        invalidate(); phase = .deleting; status = "Removing key…"; tone = .neutral; changed()
        let vault = vault
        task = Task { [weak self] in
            let result = await Task.detached { Result { try vault.remove() } }.value
            guard let self else { return }
            self.phase = .idle; self.task = nil
            switch result {
            case .success:
                self.savedKey = nil; self.draftKey = ""; self.availableModels = nil
                self.status = "Key removed from Keychain."; self.tone = .neutral
            case .failure:
                if !self.isOpen { self.savedKey = nil }
                self.status = AIConnectionError.keychain.localizedDescription; self.tone = .error
            }
            self.changed()
        }
    }

    private func candidate() throws -> String { try normalizedAIKey(draftKey.isEmpty ? savedKey ?? "" : draftKey) }
    private func invalidate() { generation &+= 1; task?.cancel(); task = nil }
    private func show(_ error: Error) { status = AIConnectionError.safe(error).localizedDescription; tone = .error; changed() }
    private func changed() { onChange?() }
}

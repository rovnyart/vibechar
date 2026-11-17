import AppKit
import Sparkle

/// Sparkle owns scheduling, signature verification, replacement and relaunch.
/// This driver owns only Pocket's quiet, one-button presentation.
@MainActor
final class UpdateController: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    enum Phase: Equatable {
        case idle, checking, available(String), downloading(Int), verifying, ready, restarting, failed
        var title: String? {
            switch self {
            case .idle: return nil
            case .checking: return "Checking…"
            case .available: return "Update"
            case .downloading(let percent): return "\(percent)%"
            case .verifying: return "Verifying…"
            case .ready: return "Restart"
            case .restarting: return "Restarting…"
            case .failed: return "Retry update"
            }
        }
        var actionable: Bool {
            switch self { case .available, .ready, .failed: return true; default: return false }
        }
    }
    private(set) var phase: Phase = .idle { didSet { onChange?(phase) } }
    private(set) var availableVersion = ""
    var onChange: ((Phase) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var canRestart: (() -> Bool)?
    var restartRequested = false
    var onTestAvailable: (() -> Void)?
    private(set) var engine: SPUUpdater?
    private var action: (() -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var userRequestedInstallation = false
    private let feedOverride: String?

    init(bundle: Bundle = .main, testing: Bool = false, feedOverride: String? = nil) {
        self.feedOverride = feedOverride
        super.init()
        if !testing { engine = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self) }
    }
    func start() {
        do { try engine?.start() }
        catch { onStatus?("Updates unavailable · Check for Updates to retry", true) }
    }
    var automaticallyChecks: Bool { engine?.automaticallyChecksForUpdates ?? false }
    func toggleAutomaticChecks() { if let engine { engine.automaticallyChecksForUpdates.toggle() } }
    var canCheck: Bool { engine?.canCheckForUpdates ?? false }
    func check() {
        if case .available = phase { onStatus?("Vibechar \(availableVersion) is ready · click Update",false); return }
        if phase == .ready { onStatus?("Update is ready · click Restart",false); return }
        guard let engine, engine.canCheckForUpdates else { return }
        engine.checkForUpdates()
    }
    func activate() {
        switch phase {
        case .available:
            guard canRestart?() ?? true else { return }
            userRequestedInstallation = true
            let next = action; action = nil; next?()
        case .ready:
            attemptRestart()
        case .failed:
            check()
        default: break
        }
    }
    private func attemptRestart() {
        guard canRestart?() ?? true else { phase = .ready; return }
        restartRequested = true
        phase = .restarting
        let next = action; action = nil; next?()
    }
    func feedURLString(for updater: SPUUpdater) -> String? { feedOverride }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate else {
            onStatus?("A new version is available · see GitHub Releases",false)
            reply(.dismiss); return
        }
        availableVersion = appcastItem.displayVersionString
        action = { reply(.install) }
        phase = .available(availableVersion)
        onTestAvailable?()
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .idle; onStatus?("You're up to date",false); acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        action = nil; restartRequested = false; userRequestedInstallation = false
        phase = .failed
        onStatus?("Couldn't update · your current version is unchanged",true)
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        receivedBytes = 0; expectedBytes = 0; phase = .downloading(0)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes &+= length
        if expectedBytes > 0 { phase = .downloading(min(99,Int(Double(receivedBytes)/Double(expectedBytes)*100))) }
    }
    func showDownloadDidStartExtractingUpdate() { phase = .verifying }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        action = { reply(.install) }; phase = .ready
        if userRequestedInstallation { attemptRestart() }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if !applicationTerminated {
            action = retryTerminatingApplication
            if !restartRequested { phase = .ready }
        }
    }
    func terminationCancelled() { restartRequested = false; phase = .ready }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }
    func dismissUpdateInstallation() {
        action = nil; restartRequested = false; userRequestedInstallation = false
        if phase != .failed { phase = .idle }
    }
    func showUpdateInFocus() { onChange?(phase) }

    // No engine/network/defaults are touched by UI and lifecycle fixtures.
    func simulateAvailable(_ version: String, install: @escaping () -> Void) {
        availableVersion = version; action = install; phase = .available(version)
    }
    func simulateReady(install: @escaping () -> Void) {
        action = install; phase = .ready
    }
}

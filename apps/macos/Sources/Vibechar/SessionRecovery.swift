import Darwin
import Foundation

enum RecoveryError: LocalizedError {
    case alreadyOpen
    case invalidSnapshot
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyOpen: return "Another vibechar window is already using the saved session."
        case .invalidSnapshot: return "The saved session could not be restored. Its recovery file has been left untouched."
        case .storageUnavailable: return "Local session storage is unavailable."
        }
    }
}

@MainActor
final class SessionRecovery {
    let fileURL: URL
    private let lock: Int32
    private let writer = DispatchQueue(label: "dev.vibechar.recovery", qos: .utility)

    init(directory: URL? = nil) throws {
        let manager = FileManager.default
        let folder = try directory ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.vibechar.app", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        fileURL = folder.appendingPathComponent("session.json")
        let descriptor = Darwin.open(folder.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw RecoveryError.storageUnavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw RecoveryError.alreadyOpen
        }
        lock = descriptor
    }

    deinit { Darwin.close(lock) }

    func save(_ checkpoint: RustCheckpoint, completion: @escaping @MainActor (Bool) -> Void) {
        let url = fileURL
        writer.async {
            let saved = checkpoint.save(to: url)
            DispatchQueue.main.async { completion(saved) }
        }
    }

    func flush(_ checkpoint: RustCheckpoint) -> Bool {
        let url = fileURL
        return writer.sync { checkpoint.save(to: url) }
    }
}

import AppCore
import Foundation

/// Persists small, non-canonical UI state in Application Support. A corrupt or older file is
/// treated as disposable preferences and never prevents a vault from opening.
public final class FileVaultWorkspaceStateStore: VaultWorkspaceStateStoring, @unchecked Sendable {
    private struct StoredState: Codable {
        static let currentVersion = 1

        let version: Int
        var vaults: [String: VaultWorkspaceState]
    }

    private let lock = NSLock()
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.fileURL = directory.appendingPathComponent("workspace-state.json")
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func load(vaultID: VaultID) -> VaultWorkspaceState {
        lock.withLock {
            guard let state = loadAll().vaults[vaultID.rawValue.uuidString] else {
                return VaultWorkspaceState()
            }
            return normalized(state)
        }
    }

    public func save(_ state: VaultWorkspaceState, vaultID: VaultID) {
        lock.withLock {
            var stored = loadAll()
            stored.vaults[vaultID.rawValue.uuidString] = normalized(state)
            guard let data = try? encoder.encode(stored) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func normalized(_ state: VaultWorkspaceState) -> VaultWorkspaceState {
        VaultWorkspaceState(
            sidebarWidth: state.sidebarWidth,
            inspectorWidth: state.inspectorWidth,
            showsInspector: state.showsInspector,
            expandedFolderIDs: state.expandedFolderIDs,
            lastOpenNotePath: state.lastOpenNotePath,
            dailyNoteConfiguration: state.dailyNoteConfiguration
        )
    }

    private func loadAll() -> StoredState {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? decoder.decode(StoredState.self, from: data),
              stored.version == StoredState.currentVersion
        else {
            return StoredState(version: StoredState.currentVersion, vaults: [:])
        }
        return stored
    }
}

/// Test and fallback store. It has the same synchronization contract as the file-backed store.
public final class InMemoryVaultWorkspaceStateStore: VaultWorkspaceStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [VaultID: VaultWorkspaceState]

    public init(storage: [VaultID: VaultWorkspaceState] = [:]) {
        self.storage = storage
    }

    public func load(vaultID: VaultID) -> VaultWorkspaceState {
        lock.withLock { storage[vaultID] ?? VaultWorkspaceState() }
    }

    public func save(_ state: VaultWorkspaceState, vaultID: VaultID) {
        lock.withLock { storage[vaultID] = state }
    }
}

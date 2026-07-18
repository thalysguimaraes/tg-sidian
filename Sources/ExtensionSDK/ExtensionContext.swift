import AppCore
import Foundation

public protocol VaultReading: Sendable {
    func listMarkdownFiles() async throws -> [RelativePath]
    func read(_ path: RelativePath) async throws -> VaultFileSnapshot
    /// Reads a bounded vault-relative configuration file without exposing the vault root URL.
    func readData(atVaultRelativePath path: RelativePath) async throws -> Data
}

@MainActor
public protocol NoteOpening: AnyObject, Sendable {
    func openNote(id: NoteID)
}

@MainActor
public protocol DailyNoteContext: AnyObject, Sendable {
    var visibleDate: Date? { get }
    var visibleNotePath: RelativePath? { get }
}

public protocol SecretsStore: Sendable {
    func data(forKey key: String) async throws -> Data?
    func setData(_ data: Data?, forKey key: String) async throws
}

/// Host-managed access to a plugin-configuration folder that lives outside the vault's own
/// sandbox grant (for example, Obsidian opening a parent folder of this vault). The host owns
/// the folder picker and the security-scoped bookmark; an extension only ever receives file
/// bytes and the vault's position inside the linked root, never the folder URL itself.
@MainActor
public protocol ExternalConfigFolderAccessing: AnyObject, Sendable {
    var hasLinkedFolder: Bool { get }
    /// Reads `relativePath` under the linked folder, returning the bytes and the vault's path
    /// prefix inside that folder ("" when the vault is the linked root itself), or nil when
    /// nothing is linked or the file is unreadable.
    func readLinkedConfig(relativePath: String) -> (data: Data, vaultSubtreePrefix: String)?
    /// Presents the host's link-folder UI; `completion` runs only after a grant is stored.
    func presentLinkFolderPanel(completion: @escaping @MainActor () -> Void)
    func unlinkFolder()
}

/// Services made available to an extension. Capability-gated services are omitted unless the
/// extension declared the corresponding capability in its manifest.
public struct ExtensionContext: Sendable {
    public let extensionID: String
    public let vault: (any VaultReading)?
    public let noteOpening: (any NoteOpening)?
    public let dailyNote: (any DailyNoteContext)?
    public let secrets: (any SecretsStore)?
    public let externalConfig: (any ExternalConfigFolderAccessing)?
    /// Lets an extension ask the host to redraw capability consumers after asynchronously
    /// loaded, value-only provider data changes. The callback exposes no host internals.
    public let refreshUI: (@MainActor @Sendable () -> Void)?

    public init(
        manifest: ExtensionManifest,
        vault: (any VaultReading)? = nil,
        noteOpening: (any NoteOpening)? = nil,
        dailyNote: (any DailyNoteContext)? = nil,
        secrets: (any SecretsStore)? = nil,
        externalConfig: (any ExternalConfigFolderAccessing)? = nil,
        refreshUI: (@MainActor @Sendable () -> Void)? = nil
    ) {
        extensionID = manifest.id
        self.vault = manifest.capabilities.contains(.vaultRead) ? vault : nil
        self.noteOpening = noteOpening
        self.dailyNote = dailyNote
        self.secrets = manifest.capabilities.contains(.keychain)
            ? secrets.map { NamespacedSecretsStore(extensionID: manifest.id, base: $0) }
            : nil
        self.externalConfig = manifest.capabilities.contains(.vaultRead) ? externalConfig : nil
        self.refreshUI = refreshUI
    }
}

private struct NamespacedSecretsStore: SecretsStore {
    let extensionID: String
    let base: any SecretsStore

    func data(forKey key: String) async throws -> Data? {
        try await base.data(forKey: namespaced(key))
    }

    func setData(_ data: Data?, forKey key: String) async throws {
        try await base.setData(data, forKey: namespaced(key))
    }

    private func namespaced(_ key: String) -> String {
        "\(extensionID).\(key)"
    }
}

import AppCore
import ExtensionSDK
import Foundation
import GraphKit
import IndexKit
import InstrumentationKit
import Observation
import SecurityKit
import VaultKit

public struct VaultAccessHooks: Sendable {
    public let start: @Sendable (URL) -> Bool
    public let stop: @Sendable (URL) -> Void

    public init(
        start: @escaping @Sendable (URL) -> Bool,
        stop: @escaping @Sendable (URL) -> Void
    ) {
        self.start = start
        self.stop = stop
    }

    public static let securityScoped = VaultAccessHooks(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )

    public static let unrestricted = VaultAccessHooks(start: { _ in true }, stop: { _ in })
}

private final class VaultAccessLease: @unchecked Sendable {
    private let url: URL
    private let stop: @Sendable (URL) -> Void
    let isActive: Bool

    init(url: URL, hooks: VaultAccessHooks) {
        self.url = url
        self.stop = hooks.stop
        self.isActive = hooks.start(url)
    }

    deinit {
        if isActive { stop(url) }
    }
}

public enum VaultLaunchState {
    case needsVault
    case restoring(displayName: String)
    case permissionLost(bookmark: VaultBookmark, reason: String)
    case failed(message: String)
    case ready(VaultSessionModel)
}

/// Coordinates vault authorization, bookmark restoration, and construction of one window's
/// design-backed service graph. UI code supplies the folder URL; this model never invokes a
/// panel, which keeps restoration and permission recovery testable.
@Observable
@MainActor
public final class VaultLaunchModel {
    public private(set) var state: VaultLaunchState = .needsVault
    public private(set) var hasAttemptedRestore = false

    public var activeSession: VaultSessionModel? {
        if case let .ready(session) = state { return session }
        return nil
    }

    private let bookmarkStore: any VaultBookmarkStoring
    private let applicationSupportDirectory: URL
    private let accessHooks: VaultAccessHooks
    private let workspaceStateStore: any VaultWorkspaceStateStoring
    private let preferencesStore: AppPreferencesStore
    private let extensionTypes: [any TGSidianExtension.Type]
    private var accessLease: VaultAccessLease?

    public init(
        bookmarkStore: any VaultBookmarkStoring,
        applicationSupportDirectory: URL,
        accessHooks: VaultAccessHooks = .securityScoped,
        workspaceStateStore: (any VaultWorkspaceStateStoring)? = nil,
        preferencesStore: AppPreferencesStore = AppPreferencesStore(),
        extensionTypes: [any TGSidianExtension.Type] = []
    ) {
        self.bookmarkStore = bookmarkStore
        self.preferencesStore = preferencesStore
        self.extensionTypes = extensionTypes
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.accessHooks = accessHooks
        self.workspaceStateStore = workspaceStateStore
            ?? (try? FileVaultWorkspaceStateStore(directory: applicationSupportDirectory))
            ?? InMemoryVaultWorkspaceStateStore()
    }

    public func restoreMostRecentVault() async {
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true
        guard let bookmark = bookmarkStore.bookmarks().first else {
            state = .needsVault
            return
        }

        state = .restoring(displayName: bookmark.displayName)
        switch bookmarkStore.resolve(bookmark) {
        case let .permissionLost(reason):
            state = .permissionLost(bookmark: bookmark, reason: reason)
        case let .resolved(url, isStale):
            await activate(url: url, bookmark: bookmark, refreshBookmark: isStale)
        }
    }

    public func selectVault(_ url: URL) async {
        let replacingBookmark: VaultBookmark? = {
            if case let .permissionLost(bookmark, _) = state { return bookmark }
            return nil
        }()
        let vaultID = replacingBookmark?.vaultID ?? VaultID()
        let provisional = VaultBookmark(
            vaultID: vaultID,
            displayName: url.lastPathComponent,
            bookmarkData: Data()
        )
        await activate(url: url, bookmark: provisional, refreshBookmark: true)
    }

    public func chooseAnotherVault() {
        state = .needsVault
    }

    public func retryRestoration() async {
        hasAttemptedRestore = false
        await restoreMostRecentVault()
    }

    private func activate(
        url: URL,
        bookmark: VaultBookmark,
        refreshBookmark: Bool
    ) async {
        let previousSession: VaultSessionModel? = {
            if case let .ready(session) = state { return session }
            return nil
        }()
        if let previousSession {
            await previousSession.document.flushPendingSave()
            guard previousSession.document.canReplaceBuffer else {
                previousSession.reportFileOperationError(
                    "Resolve or recover the current unsaved note before changing vaults"
                )
                state = .ready(previousSession)
                return
            }
        }

        state = .restoring(displayName: url.lastPathComponent)
        let lease = VaultAccessLease(url: url, hooks: accessHooks)

        guard lease.isActive else {
            state = .permissionLost(
                bookmark: bookmark,
                reason: "The vault authorization could not be activated. Select the folder again."
            )
            return
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            state = .permissionLost(
                bookmark: bookmark,
                reason: "The vault folder is not readable. Select it again to restore access."
            )
            return
        }

        do {
            if refreshBookmark {
                _ = try bookmarkStore.store(url: url, vaultID: bookmark.vaultID)
            }

            let session = try makeSession(
                rootURL: url,
                vaultID: bookmark.vaultID,
                displayName: url.lastPathComponent
            )
            accessLease = lease
            bookmarkStore.markOpened(vaultID: bookmark.vaultID)
            state = .ready(session)
            await session.load()
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    private func makeSession(
        rootURL: URL,
        vaultID: VaultID,
        displayName: String
    ) throws -> VaultSessionModel {
        let vaultSupport = applicationSupportDirectory
            .appendingPathComponent("Vaults", isDirectory: true)
            .appendingPathComponent(vaultID.rawValue.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaultSupport,
            withIntermediateDirectories: true
        )

        let instrument = SystemPerformanceInstrument()
        let preferences = preferencesStore.preferences
        let ignoredDirectories = Set([
            ".git", ".trash", "node_modules", ".build", "build", "DerivedData", "Pods", "Carthage"
        ]).union(preferences.ignorePatterns)
        let vault = try VaultActor(
            rootURL: rootURL,
            vaultID: vaultID,
            ignoredDirectoryNames: ignoredDirectories,
            instrument: instrument
        )
        // PENTA-138 replaces the foundation JSON snapshot with a disposable SQLite/FTS5 DB.
        // Removing the legacy derived snapshot never touches canonical Markdown in the vault.
        try? FileManager.default.removeItem(at: vaultSupport.appendingPathComponent("index.json"))
        let index = IndexActor(
            storageURL: vaultSupport.appendingPathComponent("index.sqlite"),
            instrument: instrument
        )
        let graph = LocalGraphEngine(index: index, instrument: instrument)
        let workspaceState = workspaceStateStore.load(vaultID: vaultID)
        let dailyNotes = DailyNoteService(
            vault: vault,
            configuration: workspaceState.dailyNoteConfiguration
        )
        let journal = try RecoveryJournal(
            directory: vaultSupport.appendingPathComponent("Recovery", isDirectory: true)
        )
        let saveCoordinator = SaveCoordinator(vault: vault, journal: journal)

        let linkedFolders = try? LinkedFolderBookmarkStore(
            directory: applicationSupportDirectory.appendingPathComponent(
                "Bookmarks",
                isDirectory: true
            )
        )

        let session = VaultSessionModel(
            vaultID: vaultID,
            displayName: displayName,
            vault: vault,
            index: index,
            graphEngine: graph,
            dailyNotes: dailyNotes,
            saveCoordinator: saveCoordinator,
            preferences: preferences,
            onPreferencesChange: { [weak preferencesStore] preferences in
                preferencesStore?.preferences = preferences
            },
            workspaceState: workspaceState,
            workspaceStateStore: workspaceStateStore,
            linkedFolders: linkedFolders
        )
        session.installExtensions(extensionTypes)
        return session
    }
}

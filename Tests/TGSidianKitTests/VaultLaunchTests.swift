import AppCore
import FeatureUI
import Foundation
import SecurityKit
import TestSupport
import Testing

@Suite("Vault launch and restoration", .serialized)
@MainActor
struct VaultLaunchTests {
    @Test("most recently opened bookmark restores and indexes its vault")
    func restoresMostRecentVault() async throws {
        let fixture = try makeFixture()
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = InMemoryBookmarkStore()
        let vaultID = VaultID()
        _ = try store.store(url: fixture.rootURL, vaultID: vaultID)

        let launcher = VaultLaunchModel(
            bookmarkStore: store,
            applicationSupportDirectory: support,
            accessHooks: .unrestricted
        )
        await launcher.restoreMostRecentVault()

        guard case let .ready(session) = launcher.state else {
            Issue.record("Expected a restored vault session")
            return
        }
        #expect(session.vaultID == vaultID)
        #expect(session.displayName == fixture.rootURL.lastPathComponent)
        #expect(!session.sidebar.isEmpty)
        #expect(session.status == .idle(noteCount: session.notes.count))
    }

    @Test("selecting a vault persists authorization and replaces the active access lease")
    func selectsAndReplacesVault() async throws {
        let first = try makeFixture()
        let second = try makeFixture()
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = InMemoryBookmarkStore()
        let counter = AccessCounter()
        let hooks = VaultAccessHooks(
            start: { url in counter.start(url); return true },
            stop: { url in counter.stop(url) }
        )
        let launcher = VaultLaunchModel(
            bookmarkStore: store,
            applicationSupportDirectory: support,
            accessHooks: hooks
        )

        await launcher.selectVault(first.rootURL)
        guard case let .ready(firstSession) = launcher.state else {
            Issue.record("Expected the first selected vault to open")
            return
        }
        await launcher.selectVault(second.rootURL)
        guard case let .ready(secondSession) = launcher.state else {
            Issue.record("Expected the second selected vault to open")
            return
        }

        #expect(firstSession.vaultID != secondSession.vaultID)
        #expect(store.bookmarks().count == 2)
        #expect(counter.started == 2)
        #expect(counter.stopped == 1)
    }

    @Test("repeated New Note commands create collision-safe canonical Markdown")
    func collisionSafeUntitledNotes() async throws {
        let fixture = try makeFixture()
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let launcher = VaultLaunchModel(
            bookmarkStore: InMemoryBookmarkStore(),
            applicationSupportDirectory: support,
            accessHooks: .unrestricted
        )
        await launcher.selectVault(fixture.rootURL)
        guard case let .ready(session) = launcher.state else {
            Issue.record("Expected selected vault to open")
            return
        }

        let first = await session.createNote(named: "Untitled", in: nil)
        let second = await session.createNote(named: "Untitled", in: nil)

        let expectedFirst = try RelativePath("Untitled.md")
        let expectedSecond = try RelativePath("Untitled 2.md")
        #expect(first == expectedFirst)
        #expect(second == expectedSecond)
        #expect(session.notes.contains(where: { $0.path == first }))
        #expect(session.notes.contains(where: { $0.path == second }))
        #expect(session.document.path == second)
        #expect(session.document.text == "# Untitled\n")
    }

    @Test("Files and Links preferences drive note location, vault trash, links, and templates")
    func filesAndLinksPreferencesDriveRuntimeBehavior() async throws {
        let fixture = try makeFixture()
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let preferenceStore = AppPreferencesStore(
            defaults: try #require(UserDefaults(suiteName: "FilesLinks-\(UUID().uuidString)")),
            key: "preferences"
        )
        preferenceStore.preferences = AppPreferences(
            newNoteLocation: .chosenFolder(try RelativePath("Inbox")),
            deletedNoteDestination: .vaultTrash,
            internalLinkFormat: .wikiLink,
            shortestLinkPaths: true,
            templatesFolder: try RelativePath("Templates")
        )
        let launcher = VaultLaunchModel(
            bookmarkStore: InMemoryBookmarkStore(),
            applicationSupportDirectory: support,
            accessHooks: .unrestricted,
            preferencesStore: preferenceStore
        )
        await launcher.selectVault(fixture.rootURL)
        guard case let .ready(session) = launcher.state else {
            Issue.record("Expected selected vault to open")
            return
        }

        let created = await session.createNote(named: "Inbox note")
        let expectedCreated = try RelativePath("Inbox/Inbox note.md")
        #expect(created == expectedCreated)
        let createdPath = try #require(created)
        await session.deleteNote(at: createdPath)
        #expect(try await !fixture.vault.exists(createdPath))
        #expect(try await fixture.vault.exists(try RelativePath(".trash/Inbox/Inbox note.md")))

        #expect(session.linkInsertion(for: "Notes/Architecture") == "[[Architecture]]")
        session.preferences.internalLinkFormat = .markdown
        #expect(session.linkInsertion(for: "Notes/Architecture") == "[Architecture](Architecture.md)")
        session.preferences.shortestLinkPaths = false
        #expect(session.linkInsertion(for: "Notes/Architecture") == "[Architecture](Notes/Architecture.md)")

        await session.presentTemplatePicker()
        let expectedTemplate = try RelativePath("Templates/Daily.md")
        #expect(session.templatePicker?.choices.map(\.path) == [expectedTemplate])
    }

    @Test("search focus requests are observable without adding a product route")
    func searchFocusRequest() async throws {
        let fixture = try makeFixture()
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let launcher = VaultLaunchModel(
            bookmarkStore: InMemoryBookmarkStore(),
            applicationSupportDirectory: support,
            accessHooks: .unrestricted
        )
        await launcher.selectVault(fixture.rootURL)
        guard case let .ready(session) = launcher.state else {
            Issue.record("Expected selected vault to open")
            return
        }

        let before = session.searchFocusRevision
        session.requestSearchFocus()
        #expect(session.searchFocusRevision == before + 1)
        #expect(session.route == .empty)
    }

    @Test("failed bookmark resolution exposes an explicit reselect state")
    func permissionLoss() async throws {
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let bookmark = VaultBookmark(
            vaultID: VaultID(),
            displayName: "Moved Vault",
            bookmarkData: Data("missing".utf8)
        )
        let launcher = VaultLaunchModel(
            bookmarkStore: PermissionLostBookmarkStore(bookmark: bookmark),
            applicationSupportDirectory: support,
            accessHooks: .unrestricted
        )

        await launcher.restoreMostRecentVault()

        guard case let .permissionLost(resolvedBookmark, reason) = launcher.state else {
            Issue.record("Expected permission loss to request vault reselection")
            return
        }
        #expect(resolvedBookmark.vaultID == bookmark.vaultID)
        #expect(reason.localizedCaseInsensitiveContains("select"))
    }

    @Test("failed security-scope activation exposes permission recovery")
    func accessLeaseFailure() async throws {
        let fixture = try makeFixture()
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let launcher = VaultLaunchModel(
            bookmarkStore: InMemoryBookmarkStore(),
            applicationSupportDirectory: support,
            accessHooks: VaultAccessHooks(start: { _ in false }, stop: { _ in }),
            workspaceStateStore: InMemoryVaultWorkspaceStateStore()
        )

        await launcher.selectVault(fixture.rootURL)

        guard case let .permissionLost(_, reason) = launcher.state else {
            Issue.record("Expected failed security scope to request vault reselection")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("authorization"))
        #expect(reason.localizedCaseInsensitiveContains("select"))
    }

    @Test("security-scoped bookmark metadata survives a disk-backed store restart")
    func persistentBookmarkRoundTrip() throws {
        let fixture = try makeFixture()
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let directory = support.appendingPathComponent("Bookmarks", isDirectory: true)
        let vaultID = VaultID()

        let firstStore = try VaultBookmarkStore(directory: directory)
        _ = try firstStore.store(url: fixture.rootURL, vaultID: vaultID)
        let reopenedStore = try VaultBookmarkStore(directory: directory)
        let bookmark = try #require(reopenedStore.bookmarks().first)

        #expect(bookmark.vaultID == vaultID)
        #expect(bookmark.displayName == fixture.rootURL.lastPathComponent)
        switch reopenedStore.resolve(bookmark) {
        case let .resolved(url, _):
            #expect(url.resolvingSymlinksInPath() == fixture.rootURL.resolvingSymlinksInPath())
        case let .permissionLost(reason):
            Issue.record("Expected bookmark resolution, got: \(reason)")
        }
    }

    @Test("split widths, folder disclosures, inspector visibility, and last note restore")
    func restoresPerVaultWorkspaceState() async throws {
        let fixture = try makeFixture()
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let bookmarkStore = InMemoryBookmarkStore()
        let workspaceStore = InMemoryVaultWorkspaceStateStore()
        let vaultID = VaultID()
        _ = try bookmarkStore.store(url: fixture.rootURL, vaultID: vaultID)
        let homePath = try RelativePath("Home.md")
        let architecturePath = try RelativePath("Notes/Architecture.md")
        workspaceStore.save(
            VaultWorkspaceState(
                sidebarWidth: 318,
                inspectorWidth: 344,
                showsInspector: false,
                expandedFolderIDs: ["folder:Notes"],
                lastOpenNotePath: homePath
            ),
            vaultID: vaultID
        )

        let firstLaunch = VaultLaunchModel(
            bookmarkStore: bookmarkStore,
            applicationSupportDirectory: support,
            accessHooks: .unrestricted,
            workspaceStateStore: workspaceStore
        )
        await firstLaunch.restoreMostRecentVault()
        guard case let .ready(firstSession) = firstLaunch.state else {
            Issue.record("Expected first restored session")
            return
        }
        #expect(firstSession.document.path == homePath)
        #expect(firstSession.route == .note(NoteID(path: homePath)))
        #expect(firstSession.sidebarWidth == 318)
        #expect(firstSession.inspectorWidth == 344)
        #expect(!firstSession.showsInspector)
        #expect(firstSession.isFolderExpanded("folder:Notes"))

        firstSession.toggleFolderExpansion("folder:Projects")
        firstSession.setSplitWidths(sidebar: 336, inspector: 340)
        firstSession.showsInspector = true
        await firstSession.openNote(at: architecturePath)

        let relaunched = VaultLaunchModel(
            bookmarkStore: bookmarkStore,
            applicationSupportDirectory: support,
            accessHooks: .unrestricted,
            workspaceStateStore: workspaceStore
        )
        await relaunched.restoreMostRecentVault()
        guard case let .ready(restoredSession) = relaunched.state else {
            Issue.record("Expected relaunched session")
            return
        }
        #expect(restoredSession.document.path == architecturePath)
        #expect(restoredSession.sidebarWidth == 336)
        #expect(restoredSession.inspectorWidth == 340)
        #expect(restoredSession.showsInspector)
        #expect(restoredSession.isFolderExpanded("folder:Notes"))
        #expect(restoredSession.isFolderExpanded("folder:Projects"))
    }

    @Test("file-backed workspace state round-trips and corrupt state safely resets")
    func fileWorkspaceStateStore() throws {
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let vaultID = VaultID()
        let expected = VaultWorkspaceState(
            sidebarWidth: 301,
            inspectorWidth: 355,
            showsInspector: false,
            expandedFolderIDs: ["folder:Archive"],
            lastOpenNotePath: try RelativePath("Archive/Duplicate.md")
        )

        try FileVaultWorkspaceStateStore(directory: support).save(expected, vaultID: vaultID)
        let reopened = try FileVaultWorkspaceStateStore(directory: support)
        #expect(reopened.load(vaultID: vaultID) == expected)

        let unsafeState = """
        {
          "version": 1,
          "vaults": {
            "\(vaultID.rawValue.uuidString)": {
              "sidebarWidth": -100,
              "inspectorWidth": 9000,
              "showsInspector": true,
              "expandedFolderIDs": ["folder:Safe", "note:NotDisclosure"],
              "lastOpenNotePath": null
            }
          }
        }
        """
        try Data(unsafeState.utf8).write(to: support.appendingPathComponent("workspace-state.json"))
        let sanitized = reopened.load(vaultID: vaultID)
        #expect(sanitized.sidebarWidth == 220)
        #expect(sanitized.inspectorWidth == 360)
        #expect(sanitized.expandedFolderIDs == ["folder:Safe"])

        try Data("not json".utf8).write(to: support.appendingPathComponent("workspace-state.json"))
        #expect(reopened.load(vaultID: vaultID) == VaultWorkspaceState())
    }

    @Test("invalid UTF-8 Markdown remains visible as an accessible unreadable row")
    func unreadableFileState() async throws {
        let fixture = try makeFixture()
        let support = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let unreadablePath = try RelativePath("Unreadable.md")
        try Data([0xFF, 0xFE, 0xFD]).write(
            to: fixture.rootURL.appendingPathComponent(unreadablePath.rawValue)
        )
        let launcher = VaultLaunchModel(
            bookmarkStore: InMemoryBookmarkStore(),
            applicationSupportDirectory: support,
            accessHooks: .unrestricted,
            workspaceStateStore: InMemoryVaultWorkspaceStateStore()
        )

        await launcher.selectVault(fixture.rootURL)
        guard case let .ready(session) = launcher.state else {
            Issue.record("Expected selected vault to open with a degraded index")
            return
        }
        let row = try #require(session.sidebar.first(where: { node in
            if case .unreadable = node.kind { return true }
            return false
        }))
        #expect(row.path == unreadablePath)
        #expect(row.accessibilityValue(isExpanded: false) == "unreadable file")
        #expect(session.unreadablePaths == [unreadablePath])
        guard case let .degraded(message) = session.status else {
            Issue.record("Expected unreadable file to produce degraded status")
            return
        }
        #expect(message.contains("1 files"))

        session.reportUnreadableFile(unreadablePath)
        #expect(session.status.text.localizedCaseInsensitiveContains("UTF-8"))
    }

    private func makeFixture() throws -> TemporaryVault {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/AcceptanceVault", isDirectory: true)
        return try TemporaryVault(copying: url)
    }

    private func temporarySupport() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class AccessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [URL] = []
    private var stops: [URL] = []

    var started: Int {
        lock.withLock { starts.count }
    }

    var stopped: Int {
        lock.withLock { stops.count }
    }

    func start(_ url: URL) {
        lock.withLock { starts.append(url) }
    }

    func stop(_ url: URL) {
        lock.withLock { stops.append(url) }
    }
}

private final class PermissionLostBookmarkStore: VaultBookmarkStoring, @unchecked Sendable {
    private let bookmark: VaultBookmark

    init(bookmark: VaultBookmark) {
        self.bookmark = bookmark
    }

    func bookmarks() -> [VaultBookmark] { [bookmark] }
    func store(url: URL, vaultID: VaultID) throws -> VaultBookmark { bookmark }
    func resolve(_ bookmark: VaultBookmark) -> BookmarkResolution {
        .permissionLost(reason: "Select the vault folder again to restore access.")
    }
    func remove(vaultID: VaultID) {}
    func markOpened(vaultID: VaultID) {}
}

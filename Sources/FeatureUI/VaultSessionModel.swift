import AppCore
import ExtensionSDK
import Foundation
import GraphKit
import IndexKit
import MarkdownKit
import Observation
import SecurityKit
import SwiftUI
import VaultKit

/// The sortable facts about a note. Kept separate from `NoteSummary` so ordering can be tested
/// without constructing index records.
public struct SidebarSortKey: Hashable, Sendable {
    /// The filename without its extension. This is what the sidebar displays and sorts on —
    /// never the front-matter title, which is frequently identical across a whole folder (every
    /// daily note titled "Daily Journal") and would collapse the rows into indistinguishable
    /// duplicates in an arbitrary order.
    public let name: String
    public let modifiedAt: Date

    public init(name: String, modifiedAt: Date) {
        self.name = name
        self.modifiedAt = modifiedAt
    }

    /// The leading `YYYY-MM-DD` of a date-named note, as a sortable string. Compared lexically
    /// rather than parsed: ISO-8601 dates already sort correctly as text, and a real parse would
    /// invite time-zone drift into what is purely a filename convention.
    public var datePrefix: String? {
        let characters = Array(name.prefix(10))
        guard characters.count == 10 else { return nil }
        let isDigit: (Int) -> Bool = { characters[$0].isASCII && characters[$0].isNumber }
        let shape = (0...3).allSatisfy(isDigit)
            && characters[4] == "-"
            && (5...6).allSatisfy(isDigit)
            && characters[7] == "-"
            && (8...9).allSatisfy(isDigit)
        return shape ? String(characters) : nil
    }
}

public enum SidebarSorting {
    /// Orders notes within one folder. Ties fall back to a name comparison so the result is a
    /// total order and the tree never reshuffles between identical rebuilds.
    public static func compare(_ lhs: SidebarSortKey, _ rhs: SidebarSortKey, using order: SidebarSortOrder) -> Bool {
        switch order {
        case .dateAwareNewestFirst:
            switch (lhs.datePrefix, rhs.datePrefix) {
            case let (left?, right?) where left != right:
                return left > right
            // A date-named note sorts above undated siblings sharing the folder.
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return ascendingByName(lhs, rhs)
            }
        case .nameAscending:
            return ascendingByName(lhs, rhs)
        case .nameDescending:
            return ascendingByName(rhs, lhs)
        case .modifiedNewestFirst:
            return lhs.modifiedAt == rhs.modifiedAt
                ? ascendingByName(lhs, rhs)
                : lhs.modifiedAt > rhs.modifiedAt
        case .modifiedOldestFirst:
            return lhs.modifiedAt == rhs.modifiedAt
                ? ascendingByName(lhs, rhs)
                : lhs.modifiedAt < rhs.modifiedAt
        }
    }

    private static func ascendingByName(_ lhs: SidebarSortKey, _ rhs: SidebarSortKey) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// A folder or note row in the sidebar tree (SPEC §3.1: browse folders and notes with counts
/// and disclosure state).
public struct SidebarNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case folder
        case note(NoteID)
        /// SPEC §19: an unreadable file stays visible with an error badge.
        case unreadable
    }

    public let id: String
    public let name: String
    public let path: RelativePath?
    public let kind: Kind
    public var children: [SidebarNode]
    /// Recursive note count shown next to folders.
    public var noteCount: Int

    public init(
        id: String,
        name: String,
        path: RelativePath?,
        kind: Kind,
        children: [SidebarNode] = [],
        noteCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.children = children
        self.noteCount = noteCount
    }

    public var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    /// SPEC §17: VoiceOver value for a row, including disclosure state for folders.
    public func accessibilityValue(isExpanded: Bool) -> String {
        switch kind {
        case .folder:
            "\(noteCount) notes, \(isExpanded ? "expanded" : "collapsed")"
        case .note:
            "note"
        case .unreadable:
            "unreadable file"
        }
    }
}

extension SidebarNode {
    /// Builds the folder/note hierarchy from indexed paths. Pure and synchronous so it is
    /// testable without a filesystem.
    public static func tree(
        from notes: [NoteSummary],
        unreadable: [RelativePath] = [],
        order: SidebarSortOrder = .default
    ) -> [SidebarNode] {
        final class Builder {
            var folders: [String: Builder] = [:]
            var notes: [(key: SidebarSortKey, path: RelativePath, id: NoteID)] = []
            var unreadable: [(name: String, path: RelativePath)] = []
        }

        let root = Builder()
        for note in notes {
            var cursor = root
            let components = note.path.components
            for folder in components.dropLast() {
                if cursor.folders[folder] == nil { cursor.folders[folder] = Builder() }
                cursor = cursor.folders[folder]!
            }
            cursor.notes.append((
                key: SidebarSortKey(name: note.path.nameWithoutExtension, modifiedAt: note.modifiedAt),
                path: note.path,
                id: note.id
            ))
        }
        for path in unreadable {
            var cursor = root
            for folder in path.components.dropLast() {
                if cursor.folders[folder] == nil { cursor.folders[folder] = Builder() }
                cursor = cursor.folders[folder]!
            }
            cursor.unreadable.append((name: path.lastComponent, path: path))
        }

        func materialize(_ builder: Builder, prefix: String) -> [SidebarNode] {
            var result: [SidebarNode] = []
            for name in builder.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let child = builder.folders[name]!
                let childPrefix = prefix.isEmpty ? name : prefix + "/" + name
                let children = materialize(child, prefix: childPrefix)
                let count = children.reduce(0) { total, node in
                    total + (node.isFolder ? node.noteCount : 1)
                }
                result.append(SidebarNode(
                    id: "folder:" + childPrefix,
                    name: name,
                    path: try? RelativePath(childPrefix),
                    kind: .folder,
                    children: children,
                    noteCount: count
                ))
            }
            for note in builder.notes.sorted(by: { SidebarSorting.compare($0.key, $1.key, using: order) }) {
                result.append(SidebarNode(
                    id: "note:" + note.path.rawValue,
                    name: note.key.name,
                    path: note.path,
                    kind: .note(note.id)
                ))
            }
            for file in builder.unreadable.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                result.append(SidebarNode(
                    id: "unreadable:" + file.path.rawValue,
                    name: file.name,
                    path: file.path,
                    kind: .unreadable
                ))
            }
            return result
        }

        return materialize(root, prefix: "")
    }
}

/// Design-backed states for the central note workspace.
public enum Route: Hashable, Sendable {
    case empty
    case note(NoteID)
    case searchResults
    /// The whole-vault graph, full-size in the center region.
    case graph
}

/// SPEC §19: the status footer is where degraded state is explained. Every case carries text.
public enum IndexStatus: Hashable, Sendable {
    case idle(noteCount: Int)
    case indexing(completed: Int, total: Int?)
    case rebuilding
    case degraded(message: String)
    case permissionLost(reason: String)

    public var text: String {
        switch self {
        case let .idle(count):
            "\(count) notes · synced"
        case let .indexing(completed, total):
            if let total {
                "Indexing \(completed) / \(total)"
            } else {
                "Indexing \(completed)…"
            }
        case .rebuilding:
            "Rebuilding index…"
        case let .degraded(message):
            message
        case let .permissionLost(reason):
            "Vault access lost — \(reason)"
        }
    }

    /// SPEC §5.5: never colour alone.
    public var glyph: String {
        switch self {
        case .idle: "◔"
        case .indexing, .rebuilding: "◐"
        case .degraded, .permissionLost: "⚠"
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .idle, .indexing, .rebuilding: false
        case .degraded, .permissionLost: true
        }
    }

    public var isBusy: Bool {
        switch self {
        case .indexing, .rebuilding: true
        case .idle, .degraded, .permissionLost: false
        }
    }
}

/// SPEC §6.3: ambiguous wiki links show a disambiguation UI rather than silently choosing.
public struct LinkDisambiguation: Identifiable, Hashable, Sendable {
    public let id: String
    public let rawTarget: String
    public let candidates: [NoteSummary]

    public init(rawTarget: String, candidates: [NoteSummary]) {
        self.id = rawTarget
        self.rawTarget = rawTarget
        self.candidates = candidates
    }
}

public struct TemplateChoice: Identifiable, Hashable, Sendable {
    public let path: RelativePath
    public var id: String { path.rawValue }
    public var title: String { path.nameWithoutExtension }
}

public struct TemplatePickerState: Identifiable, Sendable {
    public let id = UUID()
    public let choices: [TemplateChoice]
}

public struct TemplateInsertion: Identifiable, Sendable {
    public let id = UUID()
    public let content: String
}

/// One open vault per window context (SPEC §7.3). Owns the actors and exposes main-actor state
/// for the views. Nothing here assumes a singleton window (SPEC §5.2).
@Observable
@MainActor
public final class VaultSessionModel {
    public let vaultID: VaultID
    public let displayName: String
    public private(set) var route: Route = .empty
    public private(set) var sidebar: [SidebarNode] = []
    public private(set) var notes: [NoteSummary] = []
    public private(set) var status: IndexStatus = .idle(noteCount: 0)
    public private(set) var backlinks: [Backlink] = []
    public private(set) var graph: GraphSnapshot?
    public private(set) var searchResults: [SearchHit] = []
    public private(set) var selectedSearchResultID: NoteID?
    public private(set) var searchResultsFocusRevision = 0
    public private(set) var indexDiagnostics: Int = 0
    public private(set) var documentDiagnostics: [MarkdownDiagnostic] = []
    public private(set) var unreadablePaths: [RelativePath] = []
    public private(set) var recoverableFileOperations: [FileOperationRecoveryRecord] = []
    public private(set) var extensionRegistry = ExtensionRegistry()

    public var searchQuery: String = ""
    public private(set) var searchFocusRevision = 0
    public var preferences: AppPreferences {
        didSet {
            guard preferences != oldValue else { return }
            onPreferencesChange(preferences)
        }
    }
    public var pendingDisambiguation: LinkDisambiguation?
    public var templatePicker: TemplatePickerState?
    public var templateInsertion: TemplateInsertion?
    public private(set) var dailyNoteConfiguration: DailyNoteConfiguration
    public var showsInspector: Bool {
        didSet { persistWorkspaceState() }
    }
    /// SPEC §3.1: the sidebar's note ordering, persisted per vault.
    public var sidebarSortOrder: SidebarSortOrder {
        didSet {
            guard sidebarSortOrder != oldValue else { return }
            rebuildSidebar()
            persistWorkspaceState()
        }
    }
    public private(set) var expandedFolderIDs: Set<String>
    /// Folder IDs the user hid from the sidebar. A view preference only — hidden folders stay
    /// indexed and their notes stay searchable and linkable.
    public private(set) var hiddenFolderIDs: Set<String>
    /// Per-folder custom icon/color, keyed by folder ID.
    public private(set) var folderAppearances: [String: FolderAppearance]
    public private(set) var sidebarWidth: Double
    public private(set) var inspectorWidth: Double

    public let document: EditorDocumentModel

    private let vault: VaultActor
    private let index: IndexActor
    private let graphEngine: LocalGraphEngine
    private let dailyNotes: DailyNoteService
    private let saveCoordinator: SaveCoordinator
    private let workspaceStateStore: any VaultWorkspaceStateStoring
    private let linkedFolders: (any LinkedFolderBookmarkStoring)?
    private var lastOpenNotePath: RelativePath?
    private let parser = MarkdownParser()
    private var searchTask: Task<Void, Never>?
    private var graphTask: Task<GraphSnapshot?, Never>?
    /// Guards against a superseded graph build publishing its result after a newer one.
    private var graphRevision = 0
    /// The note set the current graph was built from, so idle refreshes skip a rebuild.
    private var lastGraphSignature: [NoteID] = []
    private var contextRevision: UInt = 0
    private var history: [Route] = []
    private var forwardStack: [Route] = []
    private let onPreferencesChange: (AppPreferences) -> Void

    public init(
        vaultID: VaultID,
        displayName: String,
        vault: VaultActor,
        index: IndexActor,
        graphEngine: LocalGraphEngine,
        dailyNotes: DailyNoteService,
        saveCoordinator: SaveCoordinator,
        preferences: AppPreferences = AppPreferences(),
        onPreferencesChange: @escaping (AppPreferences) -> Void = { _ in },
        workspaceState: VaultWorkspaceState,
        workspaceStateStore: any VaultWorkspaceStateStoring,
        linkedFolders: (any LinkedFolderBookmarkStoring)? = nil
    ) {
        self.linkedFolders = linkedFolders
        self.vaultID = vaultID
        self.displayName = displayName
        self.vault = vault
        self.index = index
        self.graphEngine = graphEngine
        self.dailyNotes = dailyNotes
        self.saveCoordinator = saveCoordinator
        self.preferences = preferences
        self.onPreferencesChange = onPreferencesChange
        self.dailyNoteConfiguration = workspaceState.dailyNoteConfiguration
        self.workspaceStateStore = workspaceStateStore
        self.showsInspector = workspaceState.showsInspector
        self.sidebarSortOrder = workspaceState.sidebarSortOrder
        self.expandedFolderIDs = workspaceState.expandedFolderIDs
        self.hiddenFolderIDs = workspaceState.hiddenFolderIDs
        self.folderAppearances = workspaceState.folderAppearances
        self.sidebarWidth = workspaceState.sidebarWidth
        self.inspectorWidth = workspaceState.inspectorWidth
        self.lastOpenNotePath = workspaceState.lastOpenNotePath
        self.document = EditorDocumentModel(vault: vault, saveCoordinator: saveCoordinator)
        // A save must refresh the index, sidebar counts, and backlinks (SPEC §11.1).
        self.document.onSaved = { [weak self] snapshot in
            guard let self else { return }
            Task { await self.noteDidSave(snapshot) }
        }
    }

    // MARK: - Loading

    public func load() async {
        status = .indexing(completed: 0, total: nil)
        do {
            let report = try await index.restoreOrRebuild(from: vault, progress: progressHandler())
            indexDiagnostics = report.diagnosticCount
            unreadablePaths = report.skippedPaths
            await refreshDerivedState()
            if report.skippedCount > 0 {
                // SPEC §19: unreadable files stay visible and explain themselves.
                status = .degraded(message: "\(report.skippedCount) files could not be read")
            } else {
                status = .idle(noteCount: report.indexedCount)
            }
            await document.loadPendingRecovery()
            recoverableFileOperations = (try? await saveCoordinator.pendingFileOperations()) ?? []
            await restoreLastOpenNoteIfAvailable()
            try await startIndexWatcher()
        } catch is CancellationError {
            status = .idle(noteCount: notes.count)
        } catch {
            status = .degraded(message: "Index unavailable: \(error.localizedDescription)")
        }
    }

    public func installExtensions(_ types: [any TGSidianExtension.Type]) {
        extensionRegistry = ExtensionRegistry(extensionTypes: types) { [weak self] manifest in
            ExtensionContext(
                manifest: manifest,
                vault: self,
                dailyNote: self,
                externalConfig: self,
                refreshUI: { [weak self] in self?.extensionRegistry.invalidate() }
            )
        }
    }

    public func dailyNoteHeader(for date: Date) -> AnyView? {
        let headers = extensionRegistry.enabledExtensions.compactMap {
            ($0 as? any DailyNoteHeaderProviding)?.dailyNoteHeader(for: date)
        }
        guard !headers.isEmpty else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                header
            }
        })
    }

    /// The first enabled tree decorator that recognizes a path wins. The result is a neutral
    /// rendering value, so FeatureUI remains independent from extension-specific icon packs.
    public func treeDecoration(for path: RelativePath?) -> TreeDecoration? {
        guard let path else { return nil }
        for extensionInstance in extensionRegistry.enabledExtensions {
            if let decorator = extensionInstance as? any TreeDecorating,
               let decoration = decorator.decoration(for: path) {
                return decoration
            }
        }
        return nil
    }

    /// Collects value-only inline token instructions from enabled decorators. Live preview
    /// validates range invariants before applying them to TextKit.
    public func inlineTokenDecorations(
        in text: String,
        excluding excludedRanges: [NSRange]
    ) -> [InlineTokenDecoration] {
        extensionRegistry.enabledExtensions.flatMap { extensionInstance in
            (extensionInstance as? any InlineTokenConcealing)?
                .decorations(in: text, excluding: excludedRanges) ?? []
        }
    }

    /// SPEC §14 Vault: "Rebuild index".
    public func rebuildIndex() async {
        status = .rebuilding
        await index.stopWatching()
        do {
            let report = try await index.rebuild(from: vault, progress: progressHandler())
            indexDiagnostics = report.diagnosticCount
            unreadablePaths = report.skippedPaths
            await refreshDerivedState()
            status = report.skippedCount > 0
                ? .degraded(message: "\(report.skippedCount) files could not be read")
                : .idle(noteCount: report.indexedCount)
            try await startIndexWatcher()
        } catch is CancellationError {
            status = .idle(noteCount: notes.count)
            try? await startIndexWatcher()
        } catch {
            status = .degraded(message: "Rebuild failed: \(error.localizedDescription)")
            try? await startIndexWatcher()
        }
    }

    public func cancelIndexing() {
        Task { await index.cancelCurrentOperation() }
    }

    private func progressHandler() -> @Sendable (IndexProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = .indexing(completed: progress.completed, total: progress.total)
            }
        }
    }

    private func startIndexWatcher() async throws {
        try await index.startWatching(vault: vault) { [weak self] update in
            Task { @MainActor [weak self] in
                await self?.indexDidUpdate(update)
            }
        }
    }

    private func indexDidUpdate(_ update: IndexEventReport) async {
        await refreshOpenDocumentForExternalChange(update)
        if let message = update.failureMessage {
            status = .degraded(message: message)
            return
        }
        indexDiagnostics = update.diagnosticCount
        await refreshDerivedState()
        if case let .note(id) = route { await refreshContext(for: id) }
        status = .idle(noteCount: update.noteCount)
    }

    private func refreshOpenDocumentForExternalChange(_ update: IndexEventReport) async {
        guard let path = document.path else { return }
        let mayAffectOpenDocument = update.reconciledAfterGap
            || update.changedPaths.contains(path)
            || update.removedPaths.contains(path)
        guard mayAffectOpenDocument else { return }

        if let snapshot = try? await vault.read(path) {
            await document.externalChangeDetected(snapshot)
        } else if update.removedPaths.contains(path) || update.reconciledAfterGap {
            await document.externalDeletionDetected(at: path)
        }
    }

    private func refreshDerivedState() async {
        notes = await index.allNotes()
        rebuildSidebar()
        await refreshVaultGraph()
    }

    /// The graph shows the whole vault, so it is derived from the index rather than the open
    /// note, and survives closing or deleting whatever happens to be on screen.
    ///
    /// Derived state is refreshed on every filesystem tick, but a full-vault layout takes long
    /// enough that cancelling and restarting it on each tick can starve it indefinitely. So a
    /// tick that leaves the note set unchanged — the common idle case — is a no-op, and only a
    /// real change supersedes the in-flight build. The revision guard then keeps a superseded
    /// build from publishing its (possibly cancelled, nil) result over a newer one.
    private func refreshVaultGraph() async {
        let signature = notes.map(\.id).sorted()
        guard signature != lastGraphSignature else { return }
        lastGraphSignature = signature

        graphTask?.cancel()
        graphRevision &+= 1
        let revision = graphRevision
        let task = Task { [graphEngine] () -> GraphSnapshot? in
            // SPEC §19: graph failure must not break the editor; it explains its own degraded state.
            try? await graphEngine.vaultGraph(maxNodes: 5_000, maxEdges: 20_000)
        }
        graphTask = task
        let snapshot = await task.value
        guard revision == graphRevision, snapshot != nil else { return }
        graph = snapshot
    }

    /// Re-materializes the tree from the notes already in memory, so changing the sort order does
    /// not re-query the index.
    private func rebuildSidebar() {
        sidebar = SidebarNode.tree(
            from: notes,
            unreadable: unreadablePaths,
            order: sidebarSortOrder
        )
    }

    private func restoreLastOpenNoteIfAvailable() async {
        guard let lastOpenNotePath else { return }
        guard notes.contains(where: { $0.path == lastOpenNotePath }) else {
            self.lastOpenNotePath = nil
            persistWorkspaceState()
            return
        }
        await openNote(at: lastOpenNotePath)
    }

    // MARK: - Navigation

    public func navigate(to route: Route) {
        guard route != self.route else { return }
        history.append(self.route)
        forwardStack.removeAll()
        self.route = route
    }

    /// The note currently open, if any. The vault graph has no root, so this is what the graph
    /// highlights and focuses on.
    public var currentNoteID: NoteID? {
        if case let .note(id) = route { return id }
        return nil
    }

    /// Opens the whole-vault graph in the center region, as a history-participating route.
    public func openGraph() {
        navigate(to: .graph)
    }

    public var canGoBack: Bool { !history.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public func goBack() {
        guard let previous = history.popLast() else { return }
        forwardStack.append(route)
        route = previous
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        history.append(route)
        route = next
    }

    // MARK: - Notes

    public func openNote(_ id: NoteID) async {
        guard let summary = notes.first(where: { $0.id == id }) else { return }
        await openNote(at: summary.path)
    }

    public func openNote(at path: RelativePath) async {
        await document.flushPendingSave()
        guard document.canReplaceBuffer else {
            status = .degraded(
                message: "Resolve, reload, or recover the current unsaved note before opening another note"
            )
            return
        }
        do {
            let snapshot = try await vault.read(path)
            document.open(snapshot)
            navigate(to: .note(NoteID(path: path)))
            lastOpenNotePath = path
            persistWorkspaceState()
            await refreshContext(for: NoteID(path: path))
        } catch {
            status = .degraded(message: "Could not open \(path.lastComponent): \(error.localizedDescription)")
        }
    }

    /// SPEC §11.1/§11.2: backlinks and the bounded local graph for the current note.
    /// A revision token and cancelled child task prevent stale layout work from replacing context
    /// after the user quickly opens another note or changes depth.
    public func refreshContext(for id: NoteID) async {
        contextRevision &+= 1
        let revision = contextRevision
        graphTask?.cancel()

        let refreshedBacklinks = await index.backlinks(to: id)
        let refreshedDiagnostics: [MarkdownDiagnostic]
        if let indexed = await index.indexedNote(id: id) {
            var diagnostics = indexed.parsed.diagnostics
            let connections = await index.connections().filter { $0.source == id }
            for (offset, link) in indexed.parsed.links.enumerated()
            where offset < connections.count && connections[offset].status != .resolved {
                let status = connections[offset].status == .ambiguous ? "Ambiguous" : "Unresolved"
                diagnostics.append(MarkdownDiagnostic(
                    severity: .warning,
                    message: "\(status) wiki link [[\(link.rawTarget)]]",
                    line: link.line
                ))
            }
            refreshedDiagnostics = diagnostics
        } else {
            refreshedDiagnostics = []
        }
        guard revision == contextRevision else { return }
        backlinks = refreshedBacklinks
        documentDiagnostics = refreshedDiagnostics

    }

    /// Creates a note at the user's configured default location.
    @discardableResult
    public func createNote(named name: String) async -> RelativePath? {
        await createNote(named: name, in: defaultNewNoteFolder)
    }

    private var defaultNewNoteFolder: RelativePath? {
        switch preferences.newNoteLocation {
        case .vaultRoot: nil
        case .sameFolder: document.path?.deletingLastComponent
        case let .chosenFolder(folder): folder
        }
    }

    /// SPEC §3.1: create notes safely without overwriting an existing filename.
    @discardableResult
    public func createNote(named name: String, in folder: RelativePath?) async -> RelativePath? {
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = requestedName.isEmpty ? "Untitled" : requestedName
        let stem = safeName.hasSuffix(".md") ? String(safeName.dropLast(3)) : safeName
        do {
            var suffix = 1
            var path: RelativePath
            repeat {
                let candidate = suffix == 1 ? "\(stem).md" : "\(stem) \(suffix).md"
                path = try folder.map { try $0.appending(candidate) } ?? RelativePath(candidate)
                suffix += 1
            } while try await vault.exists(path)

            let snapshot = try await vault.atomicWrite("# \(stem)\n", to: path, expectedFingerprint: nil)
            try await index.upsert(snapshot)
            await refreshDerivedState()
            await openNote(at: path)
            return path
        } catch {
            status = .degraded(message: "Could not create note: \(error.localizedDescription)")
            return nil
        }
    }

    public func renameNote(
        at path: RelativePath,
        to newName: String,
        undoManager: UndoManager? = nil
    ) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\") else {
            status = .degraded(message: "Rename failed: enter a filename, not a path")
            return
        }
        let filename = trimmed.lowercased().hasSuffix(".md") ? trimmed : trimmed + ".md"
        do {
            try await prepareForFileOperation(at: path)
            let destination = try path.deletingLastComponent.map { try $0.appending(filename) }
                ?? RelativePath(filename)
            guard destination != path else { return }
            let outcome = try await saveCoordinator.move(path, to: destination)
            try await finishMove(from: path, outcome: outcome)
            registerUndo(outcome.recovery, actionName: "Rename Note", with: undoManager)
        } catch {
            status = .degraded(message: "Rename failed: \(error.localizedDescription)")
        }
    }

    public func moveNote(
        at path: RelativePath,
        toFolder folder: RelativePath?,
        undoManager: UndoManager? = nil
    ) async {
        do {
            try await prepareForFileOperation(at: path)
            let destination = try folder.map { try $0.appending(path.lastComponent) }
                ?? RelativePath(path.lastComponent)
            guard destination != path else { return }
            let outcome = try await saveCoordinator.move(path, to: destination)
            try await finishMove(from: path, outcome: outcome)
            registerUndo(outcome.recovery, actionName: "Move Note", with: undoManager)
        } catch {
            status = .degraded(message: "Move failed: \(error.localizedDescription)")
        }
    }

    public func deleteNote(at path: RelativePath, undoManager: UndoManager? = nil) async {
        do {
            try await prepareForFileOperation(at: path)
            let recovery: FileOperationRecoveryRecord?
            switch preferences.deletedNoteDestination {
            case .macOSTrash:
                _ = try await vault.moveToMacOSTrash(path)
                recovery = nil
            case .vaultTrash:
                let destination = try await nextVaultTrashPath(for: path)
                let outcome = try await saveCoordinator.move(path, to: destination)
                recovery = outcome.recovery
            }
            try await index.remove(path: path)
            if let recovery { recoverableFileOperations.append(recovery) }
            await refreshDerivedState()
            if document.path == path {
                document.close()
                documentDiagnostics = []
                backlinks = []
                navigate(to: .empty)
                lastOpenNotePath = nil
                persistWorkspaceState()
            }
            if let recovery { registerUndo(recovery, actionName: "Delete Note", with: undoManager) }
            status = .idle(noteCount: notes.count)
        } catch {
            status = .degraded(message: "Delete failed: \(error.localizedDescription)")
        }
    }

    private func nextVaultTrashPath(for path: RelativePath) async throws -> RelativePath {
        let base = try RelativePath(".trash").appending(path.rawValue)
        guard try await !vault.exists(base) else {
            let stem = base.deletingPathExtension.rawValue
            let extensionSuffix = base.pathExtension.isEmpty ? "" : ".\(base.pathExtension)"
            var suffix = 2
            while try await vault.exists(try RelativePath("\(stem) \(suffix)\(extensionSuffix)")) {
                suffix += 1
            }
            return try RelativePath("\(stem) \(suffix)\(extensionSuffix)")
        }
        return base
    }

    public func undoFileOperation(_ record: FileOperationRecoveryRecord) async {
        do {
            let snapshot = try await saveCoordinator.restore(record)
            if let destination = record.destinationPath { try? await index.remove(path: destination) }
            try await index.upsert(snapshot)
            recoverableFileOperations.removeAll { $0.id == record.id }
            await refreshDerivedState()
            await openNote(at: snapshot.path)
            status = .idle(noteCount: notes.count)
        } catch {
            status = .degraded(message: "Undo failed: \(error.localizedDescription)")
        }
    }

    public func dismissFileOperationRecovery(_ record: FileOperationRecoveryRecord) async {
        do {
            try await saveCoordinator.discardFileOperation(record)
            recoverableFileOperations.removeAll { $0.id == record.id }
        } catch {
            status = .degraded(message: "Could not dismiss recovery: \(error.localizedDescription)")
        }
    }

    private func prepareForFileOperation(at path: RelativePath) async throws {
        guard document.path == path else { return }
        await document.flushPendingSave()
        guard case .clean = document.state else {
            throw TGSidianError.invalidOperation("Resolve or retry the open note before changing its path")
        }
    }

    private func finishMove(from source: RelativePath, outcome: FileOperationOutcome) async throws {
        try await index.remove(path: source)
        try await index.upsert(outcome.snapshot)
        recoverableFileOperations.append(outcome.recovery)
        await refreshDerivedState()
        if document.path == source {
            document.open(outcome.snapshot)
            navigate(to: .note(NoteID(path: outcome.snapshot.path)))
            lastOpenNotePath = outcome.snapshot.path
            persistWorkspaceState()
            await refreshContext(for: NoteID(path: outcome.snapshot.path))
        }
        status = .idle(noteCount: notes.count)
    }

    private func registerUndo(
        _ record: FileOperationRecoveryRecord,
        actionName: String,
        with undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { session in
            Task { @MainActor in await session.undoFileOperation(record) }
        }
        undoManager.setActionName(actionName)
    }

    /// After a save, the index must reflect the new content (SPEC §11.1: forward links and
    /// backlinks refresh together).
    public func noteDidSave(_ snapshot: VaultFileSnapshot) async {
        try? await index.upsert(snapshot)
        await refreshDerivedState()
        await refreshContext(for: NoteID(path: snapshot.path))
    }

    // MARK: - Search

    public func requestSearchFocus() {
        searchFocusRevision &+= 1
    }

    /// SPEC §10.4: stream results quickly and cancel stale queries.
    public func search(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            selectedSearchResultID = nil
            if route == .searchResults { goBack() }
            return
        }
        searchTask = Task { [index] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let hits = await index.search(SearchRequest(query: query))
            guard !Task.isCancelled else { return }
            self.searchResults = hits
            if !hits.contains(where: { $0.note.id == self.selectedSearchResultID }) {
                self.selectedSearchResultID = hits.first?.note.id
            }
            if self.route != .searchResults { self.navigate(to: .searchResults) }
        }
    }

    public func selectSearchResult(_ id: NoteID) {
        guard searchResults.contains(where: { $0.note.id == id }) else { return }
        selectedSearchResultID = id
    }

    public func focusSearchResults() {
        if selectedSearchResultID == nil { selectedSearchResultID = searchResults.first?.note.id }
        searchResultsFocusRevision &+= 1
    }

    public func moveSearchSelection(by offset: Int) {
        guard !searchResults.isEmpty else { return }
        let current = selectedSearchResultID.flatMap { id in
            searchResults.firstIndex(where: { $0.note.id == id })
        } ?? (offset >= 0 ? -1 : searchResults.count)
        selectedSearchResultID = searchResults[min(searchResults.count - 1, max(0, current + offset))].note.id
    }

    public func openSelectedSearchResult() async {
        guard let id = selectedSearchResultID,
              let hit = searchResults.first(where: { $0.note.id == id })
        else { return }
        await openNote(at: hit.note.path)
    }

    // MARK: - Links

    /// SPEC §6.3: deterministic resolution; ambiguity surfaces a picker instead of guessing.
    public func followWikiLink(_ rawTarget: String) async {
        let candidates = await resolveCandidates(rawTarget)
        switch candidates.count {
        case 0:
            status = .degraded(message: "No note matches [[\(rawTarget)]]")
        case 1:
            await openNote(at: candidates[0].path)
        default:
            pendingDisambiguation = LinkDisambiguation(rawTarget: rawTarget, candidates: candidates)
        }
    }

    public func wikiLinkCompletions(matching prefix: String) -> [String] {
        let normalizedPrefix = prefix.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        var seen = Set<String>()
        return notes.compactMap { note in
            let candidate = note.path.deletingPathExtension.rawValue
            let normalized = candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).lowercased()
            guard normalizedPrefix.isEmpty || normalized.hasPrefix(normalizedPrefix) else { return nil }
            guard seen.insert(candidate).inserted else { return nil }
            return candidate
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Converts a completion candidate into the configured source syntax. The editor passes the
    /// candidate's canonical vault-relative path, keeping menu completion and typed completion
    /// on the same preference-backed path.
    public func linkInsertion(for candidate: String) -> String {
        let note = notes.first { $0.path.deletingPathExtension.rawValue == candidate }
        let path = note?.path ?? (try? RelativePath(candidate + ".md"))
        let title = note?.path.nameWithoutExtension ?? (path?.nameWithoutExtension ?? candidate)
        let target = path.map(linkTarget(for:)) ?? candidate
        switch preferences.internalLinkFormat {
        case .wikiLink:
            return "[[\((target as NSString).deletingPathExtension)]]"
        case .markdown:
            return "[\(title)](\(target))"
        }
    }

    private func linkTarget(for target: RelativePath) -> String {
        guard preferences.shortestLinkPaths else { return target.rawValue }
        let matchingNameCount = notes.filter {
            NotePathIdentity.key($0.path.nameWithoutExtension) == NotePathIdentity.key(target.nameWithoutExtension)
        }.count
        if matchingNameCount == 1 { return target.lastComponent }
        return target.rawValue
    }

    public func presentTemplatePicker() async {
        guard let folder = preferences.templatesFolder else {
            status = .degraded(message: "Choose a templates folder in Files & Links first")
            return
        }
        let choices = notes
            .filter { $0.path.rawValue.hasPrefix(folder.rawValue + "/") }
            .map { TemplateChoice(path: $0.path) }
            .sorted { $0.path < $1.path }
        guard !choices.isEmpty else {
            status = .degraded(message: "No Markdown templates found in \(folder.rawValue)")
            return
        }
        templatePicker = TemplatePickerState(choices: choices)
    }

    public func insertTemplate(at path: RelativePath) async {
        do {
            let snapshot = try await vault.read(path)
            templatePicker = nil
            templateInsertion = TemplateInsertion(content: snapshot.content)
        } catch {
            status = .degraded(message: "Could not read template: \(error.localizedDescription)")
        }
    }

    private func resolveCandidates(_ rawTarget: String) async -> [NoteSummary] {
        var targetValue = rawTarget.replacingOccurrences(of: "\\", with: "/")
        if targetValue.lowercased().hasSuffix(".md") { targetValue.removeLast(3) }
        let target = NotePathIdentity.key(targetValue)
        let hasFolder = target.contains("/")
        return notes.filter { note in
            if NotePathIdentity.key(note.path.deletingPathExtension.rawValue) == target { return true }
            guard !hasFolder else { return false }
            return NotePathIdentity.key(note.path.nameWithoutExtension) == target
                || NotePathIdentity.key(note.title) == target
        }
    }

    // MARK: - Daily notes

    public var currentDailyNoteDate: Date? {
        guard case let .note(id) = route,
              let note = notes.first(where: { $0.id == id }),
              note.path.deletingLastComponent?.rawValue == dailyNoteConfiguration.folder.rawValue
        else { return nil }
        return dailyNoteConfiguration.date(fromFilename: note.path.lastComponent)
    }

    /// Existing notes matching the configured folder and filename pattern. The sidebar uses this
    /// canonical list rather than inventing product destinations or filesystem aliases.
    public var recentDailyNotes: [NoteSummary] {
        let folder = dailyNoteConfiguration.folder.rawValue
        return notes.compactMap { note -> (Date, NoteSummary)? in
            guard note.path.deletingLastComponent?.rawValue == folder,
                  let date = dailyNoteConfiguration.date(fromFilename: note.path.lastComponent)
            else { return nil }
            return (date, note)
        }
        .sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            return lhs.1.path < rhs.1.path
        }
        .prefix(7)
        .map { $0.1 }
    }

    public func updateDailyNoteConfiguration(_ configuration: DailyNoteConfiguration) async {
        dailyNoteConfiguration = configuration
        await dailyNotes.updateConfiguration(configuration)
        persistWorkspaceState()
    }

    /// SPEC §12.1: idempotent creation; the calendar opens or creates a date.
    public func openDailyNote(for date: Date) async {
        await document.flushPendingSave()
        guard document.canReplaceBuffer else {
            status = .degraded(
                message: "Resolve, reload, or recover the current unsaved note before opening a daily note"
            )
            return
        }
        do {
            let snapshot = try await dailyNotes.openOrCreate(date: date)
            try? await index.upsert(snapshot)
            await refreshDerivedState()
            document.open(snapshot)
            navigate(to: .note(NoteID(path: snapshot.path)))
            lastOpenNotePath = snapshot.path
            persistWorkspaceState()
            await refreshContext(for: NoteID(path: snapshot.path))
        } catch {
            status = .degraded(message: "Daily note failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Restorable workspace state

    public func isFolderExpanded(_ id: String) -> Bool {
        expandedFolderIDs.contains(id)
    }

    public func toggleFolderExpansion(_ id: String) {
        guard id.hasPrefix("folder:") else { return }
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
        } else {
            expandedFolderIDs.insert(id)
        }
        persistWorkspaceState()
    }

    public func isFolderHidden(_ id: String) -> Bool {
        hiddenFolderIDs.contains(id)
    }

    public func setFolderHidden(_ id: String, hidden: Bool) {
        guard id.hasPrefix("folder:") else { return }
        let changed = hidden ? hiddenFolderIDs.insert(id).inserted : (hiddenFolderIDs.remove(id) != nil)
        guard changed else { return }
        persistWorkspaceState()
    }

    public func folderAppearance(_ id: String) -> FolderAppearance? {
        folderAppearances[id]
    }

    /// Sets or clears a folder's custom icon/color. Passing nil restores the default folder look.
    public func setFolderAppearance(_ id: String, _ appearance: FolderAppearance?) {
        guard id.hasPrefix("folder:") else { return }
        if let appearance {
            guard folderAppearances[id] != appearance else { return }
            folderAppearances[id] = appearance
        } else {
            guard folderAppearances[id] != nil else { return }
            folderAppearances[id] = nil
        }
        persistWorkspaceState()
    }

    public func setSplitWidths(sidebar: Double, inspector: Double) {
        let clampedSidebar = min(420, max(220, sidebar))
        let clampedInspector = min(420, max(250, inspector))
        guard clampedSidebar != sidebarWidth || clampedInspector != inspectorWidth else { return }
        sidebarWidth = clampedSidebar
        inspectorWidth = clampedInspector
        persistWorkspaceState()
    }

    public func reportUnreadableFile(_ path: RelativePath) {
        status = .degraded(message: "\(path.lastComponent) could not be read. Check its permissions and UTF-8 encoding.")
    }

    public func reportFileOperationError(_ message: String) {
        status = .degraded(message: message)
    }

    private func persistWorkspaceState() {
        workspaceStateStore.save(
            VaultWorkspaceState(
                sidebarWidth: sidebarWidth,
                inspectorWidth: inspectorWidth,
                showsInspector: showsInspector,
                expandedFolderIDs: expandedFolderIDs,
                lastOpenNotePath: lastOpenNotePath,
                dailyNoteConfiguration: dailyNoteConfiguration,
                sidebarSortOrder: sidebarSortOrder,
                hiddenFolderIDs: hiddenFolderIDs,
                folderAppearances: folderAppearances
            ),
            vaultID: vaultID
        )
    }

    // MARK: - Recovery

    /// SPEC §19: permission loss prompts a reselect rather than failing silently.
    public func reportPermissionLost(reason: String) {
        status = .permissionLost(reason: reason)
    }
}

extension VaultSessionModel: DailyNoteContext {
    public var visibleDate: Date? { currentDailyNoteDate }
    public var visibleNotePath: RelativePath? { document.path }
}

/// The Obsidian-folder grant for extensions reading plugin config from a parent of this vault.
/// The sandbox scopes reads to the picked vault folder, so `.obsidian/` in an ancestor needs
/// its own user-granted bookmark; the extension only ever sees bytes and a subtree prefix.
extension VaultSessionModel: ExternalConfigFolderAccessing {
    private var obsidianConfigLinkKey: String { "obsidian-config:\(vaultID.rawValue.uuidString)" }

    public var hasLinkedFolder: Bool {
        linkedFolders?.resolveLinkedFolder(forKey: obsidianConfigLinkKey) != nil
    }

    public func readLinkedConfig(relativePath: String) -> (data: Data, vaultSubtreePrefix: String)? {
        guard let linked = linkedFolders?.resolveLinkedFolder(forKey: obsidianConfigLinkKey) else {
            return nil
        }
        let rootComponents = linked.standardizedFileURL.pathComponents
        let vaultComponents = vault.rootURL.standardizedFileURL.pathComponents
        guard vaultComponents.count >= rootComponents.count,
              Array(vaultComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }
        let prefix = vaultComponents.dropFirst(rootComponents.count).joined(separator: "/")
        let accessing = linked.startAccessingSecurityScopedResource()
        defer { if accessing { linked.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: linked.appendingPathComponent(relativePath)) else {
            return nil
        }
        return (data, prefix)
    }

    public func presentLinkFolderPanel(completion: @escaping @MainActor () -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Link Obsidian Vault Folder"
        panel.message = "Choose the folder Obsidian opens — the one containing .obsidian."
        panel.prompt = "Link Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = vault.rootURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? linkedFolders?.storeLinkedFolder(url, forKey: obsidianConfigLinkKey)
        completion()
    }

    public func unlinkFolder() {
        linkedFolders?.removeLinkedFolder(forKey: obsidianConfigLinkKey)
    }
}

extension VaultSessionModel: VaultReading {
    public func listMarkdownFiles() async throws -> [RelativePath] {
        try await vault.listMarkdownFiles()
    }

    public func read(_ path: RelativePath) async throws -> VaultFileSnapshot {
        try await vault.read(path)
    }

    public func readData(atVaultRelativePath path: RelativePath) async throws -> Data {
        try await vault.readData(atVaultRelativePath: path)
    }
}

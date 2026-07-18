import AppCore
import Foundation
import GRDB
import MarkdownKit
import VaultKit

public struct IndexedNote: Hashable, Sendable, Codable {
    public let id: NoteID
    public let path: RelativePath
    public let parsed: ParsedNote
    public let fingerprint: FileFingerprint

    public init(id: NoteID, path: RelativePath, parsed: ParsedNote, fingerprint: FileFingerprint) {
        self.id = id
        self.path = path
        self.parsed = parsed
        self.fingerprint = fingerprint
    }

    public var summary: NoteSummary {
        NoteSummary(
            id: id,
            path: path,
            title: parsed.title,
            tags: parsed.tags,
            type: parsed.frontMatter["type"]?.stringValue,
            modifiedAt: fingerprint.modificationDate
        )
    }
}

public struct IndexProgress: Hashable, Sendable {
    public enum Phase: String, Hashable, Sendable {
        case initialReconciliation
        case reconciliation
        case rebuild
    }

    public let phase: Phase
    public let completed: Int
    public let total: Int

    public init(phase: Phase, completed: Int, total: Int) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }
}

public struct IndexRebuildReport: Hashable, Sendable, Codable {
    public let indexedCount: Int
    public let skippedPaths: [RelativePath]
    public let diagnosticCount: Int
    public let rebuiltFromCorruption: Bool

    public var skippedCount: Int { skippedPaths.count }

    public init(
        indexedCount: Int,
        skippedPaths: [RelativePath],
        diagnosticCount: Int,
        rebuiltFromCorruption: Bool
    ) {
        self.indexedCount = indexedCount
        self.skippedPaths = skippedPaths
        self.diagnosticCount = diagnosticCount
        self.rebuiltFromCorruption = rebuiltFromCorruption
    }
}

public struct IndexEventReport: Hashable, Sendable {
    public let changedCount: Int
    public let noteCount: Int
    public let reconciledAfterGap: Bool
    public let lastEventID: UInt64?
    public let failureMessage: String?
    public let changedPaths: [RelativePath]
    public let removedPaths: [RelativePath]
    public let diagnosticCount: Int

    public init(
        changedCount: Int,
        noteCount: Int,
        reconciledAfterGap: Bool,
        lastEventID: UInt64?,
        failureMessage: String? = nil,
        changedPaths: [RelativePath] = [],
        removedPaths: [RelativePath] = [],
        diagnosticCount: Int = 0
    ) {
        self.changedCount = changedCount
        self.noteCount = noteCount
        self.reconciledAfterGap = reconciledAfterGap
        self.lastEventID = lastEventID
        self.failureMessage = failureMessage
        self.changedPaths = changedPaths
        self.removedPaths = removedPaths
        self.diagnosticCount = diagnosticCount
    }
}

/// Actor-isolated disposable SQLite/FTS5 index. Markdown remains canonical: every recovery path
/// quarantines or deletes only `storageURL`, then reconstructs rows from `VaultActor` snapshots.
public actor IndexActor: IndexQuerying {
    public static let schemaVersion = 2

    private let storageURL: URL?
    private let parser: MarkdownParser
    private let instrument: any PerformanceInstrumenting
    private let fileManager = FileManager.default
    private var databaseQueue: DatabaseQueue?
    private var quarantinedOnOpen = false
    private var cancellationGeneration: UInt64 = 0
    private var watcher: FSEventsVaultWatcher?

    public init(
        storageURL: URL? = nil,
        parser: MarkdownParser = MarkdownParser(),
        instrument: any PerformanceInstrumenting = NoopPerformanceInstrument()
    ) {
        self.storageURL = storageURL
        self.parser = parser
        self.instrument = instrument
    }

    // MARK: - Lifecycle and reconciliation

    public func cancelCurrentOperation() {
        cancellationGeneration &+= 1
    }

    @discardableResult
    public func rebuild(
        from vault: VaultActor,
        rebuiltFromCorruption: Bool = false,
        progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> IndexRebuildReport {
        _ = try database()
        return try await performRebuild(
            from: vault,
            phase: .rebuild,
            rebuiltFromCorruption: rebuiltFromCorruption || quarantinedOnOpen,
            progress: progress
        )
    }

    @discardableResult
    public func restoreOrRebuild(
        from vault: VaultActor,
        progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> IndexRebuildReport {
        let queue = try database()
        let noteCount = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0 }
        if quarantinedOnOpen || noteCount == 0 {
            return try await performRebuild(
                from: vault,
                phase: .initialReconciliation,
                rebuiltFromCorruption: quarantinedOnOpen,
                progress: progress
            )
        }
        return try await reconcile(from: vault, progress: progress)
    }

    @discardableResult
    public func reconcile(
        from vault: VaultActor,
        progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> IndexRebuildReport {
        instrument.begin(.initialIndexComplete)
        defer { instrument.end(.initialIndexComplete) }

        let queue = try database()
        try establishEventBaselineIfNeeded(in: queue)
        let token = cancellationGeneration
        let paths = try await vault.listMarkdownFiles()
        progress?(IndexProgress(phase: .reconciliation, completed: 0, total: paths.count))
        let existing = try await queue.read {
            db -> [NoteID: (path: RelativePath, fingerprint: FileFingerprint)] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, path, byte_count, modified_at, content_hash FROM notes"
            )
            return Dictionary(uniqueKeysWithValues: try rows.map { row in
                let id = NoteID(rawValue: row["id"])
                let value = (
                    path: try RelativePath(row["path"] as String),
                    fingerprint: FileFingerprint(
                        byteCount: row["byte_count"],
                        modificationDate: Date(timeIntervalSince1970: row["modified_at"]),
                        contentHash: row["content_hash"]
                    )
                )
                return (id, value)
            })
        }

        var seen = Set<NoteID>()
        var changed: [IndexedNote] = []
        var skipped: [RelativePath] = []
        for (offset, path) in paths.enumerated() {
            try checkCancellation(token)
            let id = NoteID(path: path)
            seen.insert(id)
            do {
                let snapshot = try await vault.read(path)
                if existing[id]?.path != path || existing[id]?.fingerprint != snapshot.fingerprint {
                    let parsed = parser.parse(snapshot.content, path: path)
                    changed.append(IndexedNote(id: id, path: path, parsed: parsed, fingerprint: snapshot.fingerprint))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped.append(path)
            }
            emitProgress(progress, phase: .reconciliation, completed: offset + 1, total: paths.count)
        }
        try checkCancellation(token)

        let changedNotes = changed
        let seenIDs = seen
        try await queue.write { db in
            let encoder = Self.makeJSONEncoder()
            for note in changedNotes {
                _ = try Self.upsert(note, in: db, encoder: encoder)
            }
            let storedIDs = try String.fetchAll(db, sql: "SELECT id FROM notes")
            for rawID in storedIDs where !seenIDs.contains(NoteID(rawValue: rawID)) {
                try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [rawID])
            }
            try Self.refreshLinkResolutions(in: db)
        }

        let totals = try Self.databaseTotals(queue)
        return IndexRebuildReport(
            indexedCount: totals.notes,
            skippedPaths: skipped.sorted(),
            diagnosticCount: totals.diagnostics,
            rebuiltFromCorruption: false
        )
    }

    private func performRebuild(
        from vault: VaultActor,
        phase: IndexProgress.Phase,
        rebuiltFromCorruption: Bool,
        progress: (@Sendable (IndexProgress) -> Void)?
    ) async throws -> IndexRebuildReport {
        instrument.begin(.initialIndexComplete)
        defer { instrument.end(.initialIndexComplete) }

        let queue = try database()
        try establishEventBaselineIfNeeded(in: queue)
        let token = cancellationGeneration
        let paths = try await vault.listMarkdownFiles()
        progress?(IndexProgress(phase: phase, completed: 0, total: paths.count))
        instrument.event(.initialIndexProgress)

        var rebuilt: [IndexedNote] = []
        rebuilt.reserveCapacity(paths.count)
        var skipped: [RelativePath] = []
        for (offset, path) in paths.enumerated() {
            try checkCancellation(token)
            do {
                let snapshot = try await vault.read(path)
                let parsed = parser.parse(snapshot.content, path: path)
                rebuilt.append(IndexedNote(
                    id: NoteID(path: path),
                    path: path,
                    parsed: parsed,
                    fingerprint: snapshot.fingerprint
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped.append(path)
            }
            emitProgress(progress, phase: phase, completed: offset + 1, total: paths.count)
        }
        try checkCancellation(token)

        // Preserve the previous usable index if parsing is cancelled. The replacement itself is
        // one transaction, so observers never see a partially rebuilt database.
        let rebuiltNotes = rebuilt
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM links")
            try db.execute(sql: "DELETE FROM notes")
            let encoder = Self.makeJSONEncoder()
            for note in rebuiltNotes {
                _ = try Self.upsert(note, in: db, encoder: encoder)
            }
            try Self.refreshLinkResolutions(in: db)
        }
        quarantinedOnOpen = false

        let diagnostics = rebuilt.reduce(0) { $0 + $1.parsed.diagnostics.count }
        return IndexRebuildReport(
            indexedCount: rebuilt.count,
            skippedPaths: skipped.sorted(),
            diagnosticCount: diagnostics,
            rebuiltFromCorruption: rebuiltFromCorruption
        )
    }

    // MARK: - Incremental updates and FSEvents

    public func startWatching(
        vault: VaultActor,
        onChange: @escaping @Sendable (IndexEventReport) -> Void = { _ in }
    ) throws {
        let queue = try database()
        let lastID = try queue.read { db -> UInt64? in
            guard let value = try String.fetchOne(
                db,
                sql: "SELECT value FROM metadata WHERE key = 'last_fsevent_id'"
            ) else { return nil }
            return UInt64(value)
        }

        watcher?.stop()
        watcher = try FSEventsVaultWatcher(rootURL: vault.rootURL, since: lastID) { [weak self] events in
            Task {
                guard let self else { return }
                do {
                    onChange(try await self.process(events: events, from: vault))
                } catch is CancellationError {
                    return
                } catch {
                    let count = (try? await self.indexedNoteCount()) ?? 0
                    onChange(IndexEventReport(
                        changedCount: 0,
                        noteCount: count,
                        reconciledAfterGap: false,
                        lastEventID: events.map(\.eventID).max(),
                        failureMessage: "Incremental index update failed; reconciliation is available."
                    ))
                }
            }
        }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Releases SQLite/WAL handles so tests, diagnostics, or app teardown can safely inspect or
    /// remove the disposable files. Canonical Markdown handles are owned by `VaultActor`.
    public func close() {
        stopWatching()
        databaseQueue = nil
    }

    @discardableResult
    public func process(events: [VaultFileEvent], from vault: VaultActor) async throws -> IndexEventReport {
        let queue = try database()
        let lastEventID = events.map(\.eventID).filter { $0 > 0 }.max()
        if events.contains(where: { $0.kind == .eventGap || $0.kind == .rescanRequired }) {
            let report = try await reconcile(from: vault)
            try Self.storeLastEventID(lastEventID, in: queue)
            return IndexEventReport(
                changedCount: report.indexedCount,
                noteCount: report.indexedCount,
                reconciledAfterGap: true,
                lastEventID: lastEventID,
                changedPaths: events.compactMap(\.path),
                diagnosticCount: report.diagnosticCount
            )
        }

        instrument.begin(.incrementalIndex)
        defer { instrument.end(.incrementalIndex) }
        let paths = Set(events.compactMap(\.path)).sorted()
        var upserts: [IndexedNote] = []
        var removals: [RelativePath] = []
        for path in paths {
            try Task.checkCancellation()
            do {
                if try await vault.isIndexable(path) {
                    let snapshot = try await vault.read(path)
                    upserts.append(IndexedNote(
                        id: NoteID(path: path),
                        path: path,
                        parsed: parser.parse(snapshot.content, path: path),
                        fingerprint: snapshot.fingerprint
                    ))
                } else {
                    removals.append(path)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A file may still be mid-write. Keep the prior row until a later event or scan.
                continue
            }
        }

        let removedPaths = removals
        let upsertedNotes = upserts
        try await queue.write { db in
            for path in removedPaths {
                try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [NoteID(path: path).rawValue])
            }
            let encoder = Self.makeJSONEncoder()
            for note in upsertedNotes {
                _ = try Self.upsert(note, in: db, encoder: encoder)
            }
            try Self.refreshLinkResolutions(in: db)
        }
        try Self.storeLastEventID(lastEventID, in: queue)
        let totals = try Self.databaseTotals(queue)
        return IndexEventReport(
            changedCount: upserts.count + removals.count,
            noteCount: totals.notes,
            reconciledAfterGap: false,
            lastEventID: lastEventID,
            changedPaths: upserts.map(\.path),
            removedPaths: removals,
            diagnosticCount: totals.diagnostics
        )
    }

    public func upsert(_ snapshot: VaultFileSnapshot) throws {
        instrument.begin(.incrementalIndex)
        defer { instrument.end(.incrementalIndex) }
        let queue = try database()
        let note = IndexedNote(
            id: NoteID(path: snapshot.path),
            path: snapshot.path,
            parsed: parser.parse(snapshot.content, path: snapshot.path),
            fingerprint: snapshot.fingerprint
        )
        try queue.write { db in
            let preservesResolutionIdentity = try Self.upsert(
                note,
                in: db,
                encoder: Self.makeJSONEncoder()
            )
            if preservesResolutionIdentity {
                try Self.refreshLinkResolutions(forSourceID: note.id.rawValue, in: db)
            } else {
                try Self.refreshLinkResolutions(in: db)
            }
        }
    }

    public func remove(path: RelativePath) throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [NoteID(path: path).rawValue])
            try Self.refreshLinkResolutions(in: db)
        }
    }

    // MARK: - Search and graph queries

    public func search(_ request: SearchRequest) -> [SearchHit] {
        instrument.begin(.search)
        defer { instrument.end(.search) }
        guard !Task.isCancelled, request.limit > 0, let queue = try? database() else { return [] }

        let query = Self.searchKey(request.query.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let hits = query.isEmpty
                ? try Self.filteredNotes(request, queue: queue)
                : try Self.ftsSearch(request, normalizedQuery: query, queue: queue)
            return Task.isCancelled ? [] : hits
        } catch {
            return []
        }
    }

    public func note(id: NoteID) -> NoteSummary? {
        guard let queue = try? database() else { return nil }
        return try? queue.read { db in
            guard let row = try Row.fetchOne(db, sql: Self.summarySelect + " WHERE id = ?", arguments: [id.rawValue])
            else { return nil }
            return try Self.summary(from: row)
        }
    }

    public func indexedNote(id: NoteID) -> IndexedNote? {
        guard let queue = try? database() else { return nil }
        return try? queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT parsed_json FROM notes WHERE id = ?", arguments: [id.rawValue])
            else { return nil }
            return try JSONDecoder().decode(IndexedNote.self, from: data)
        }
    }

    public func allNotes() -> [NoteSummary] {
        guard let queue = try? database() else { return [] }
        return (try? queue.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(db, sql: Self.summarySelect + " ORDER BY path COLLATE NOCASE, path")
                .map { try Self.summary(from: $0, decoder: decoder) }
        }) ?? []
    }

    public func connections() -> [ResolvedConnection] {
        guard let queue = try? database() else { return [] }
        return (try? queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source_id, target_id, raw_target, status
                FROM links
                ORDER BY source_id, ordinal
                """).map { row in
                    ResolvedConnection(
                        source: NoteID(rawValue: row["source_id"]),
                        target: (row["target_id"] as String?).map(NoteID.init(rawValue:)),
                        rawTarget: row["raw_target"],
                        status: ResolvedConnection.Status(rawValue: row["status"]) ?? .unresolved
                    )
                }
        }) ?? []
    }

    public func backlinks(to noteID: NoteID) -> [Backlink] {
        guard let queue = try? database() else { return [] }
        return (try? queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.id, n.path, n.title, n.tags_json, n.note_type, n.modified_at,
                       n.parsed_json, l.raw_target, l.line
                FROM links l
                JOIN notes n ON n.id = l.source_id
                WHERE l.target_id = ? AND l.status = 'resolved'
                ORDER BY n.path COLLATE NOCASE, n.path, l.ordinal
            """, arguments: [noteID.rawValue])
            let decoder = JSONDecoder()
            return try rows.map { row in
                let source = try Self.summary(from: row, decoder: decoder)
                let data: Data = row["parsed_json"]
                let indexed = try decoder.decode(IndexedNote.self, from: data)
                let line: Int = row["line"]
                let heading = indexed.parsed.headings.filter { $0.line <= line }.last?.text
                let rawTarget: String = row["raw_target"]
                let excerpt = Self.surroundingExcerpt(
                    in: indexed.parsed,
                    sourceLine: line,
                    rawTarget: rawTarget
                )
                return Backlink(source: source, target: noteID, excerpt: excerpt, heading: heading)
            }
        }) ?? []
    }

    public func indexedNoteCount() throws -> Int {
        let queue = try database()
        return try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0 }
    }

    public func appliedSchemaMigrations() throws -> [String] {
        let queue = try database()
        return try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    // MARK: - Database

    private func database() throws -> DatabaseQueue {
        if let databaseQueue { return databaseQueue }
        do {
            let queue = try Self.openDatabase(at: storageURL)
            databaseQueue = queue
            return queue
        } catch {
            guard let storageURL, fileManager.fileExists(atPath: storageURL.path) else { throw error }
            try quarantineDerivedDatabase(at: storageURL)
            let queue = try Self.openDatabase(at: storageURL)
            databaseQueue = queue
            quarantinedOnOpen = true
            return queue
        }
    }

    private static func openDatabase(at url: URL?) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.label = "tg-sidian-derived-index"
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let queue = try url.map { try DatabaseQueue(path: $0.path, configuration: configuration) }
            ?? DatabaseQueue(configuration: configuration)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-core") { db in
            try db.execute(sql: """
                CREATE TABLE notes (
                    id TEXT NOT NULL PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    title TEXT NOT NULL,
                    normalized_title TEXT NOT NULL,
                    normalized_path TEXT NOT NULL,
                    tags TEXT NOT NULL,
                    normalized_tags TEXT NOT NULL,
                    tags_json TEXT NOT NULL,
                    headings TEXT NOT NULL,
                    normalized_headings TEXT NOT NULL,
                    front_matter TEXT NOT NULL,
                    normalized_front_matter TEXT NOT NULL,
                    body TEXT NOT NULL,
                    note_type TEXT,
                    normalized_type TEXT,
                    modified_at REAL NOT NULL,
                    byte_count INTEGER NOT NULL,
                    content_hash TEXT NOT NULL,
                    parsed_json BLOB NOT NULL,
                    diagnostic_count INTEGER NOT NULL,
                    has_unresolved_links INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX notes_path_index ON notes(normalized_path);
                CREATE INDEX notes_type_index ON notes(normalized_type);
                CREATE INDEX notes_modified_index ON notes(modified_at DESC);

                CREATE TABLE links (
                    source_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    raw_target TEXT NOT NULL,
                    heading TEXT,
                    line INTEGER NOT NULL,
                    target_id TEXT REFERENCES notes(id) ON DELETE SET NULL,
                    status TEXT NOT NULL DEFAULT 'unresolved',
                    PRIMARY KEY (source_id, ordinal)
                );
                CREATE INDEX links_target_index ON links(target_id, status);
                CREATE TABLE metadata (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
                """)
        }
        migrator.registerMigration("v2-fts5") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE note_fts USING fts5(
                    title, path, tags, headings, front_matter, body,
                    content='notes', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                );
                CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN
                    INSERT INTO note_fts(rowid, title, path, tags, headings, front_matter, body)
                    VALUES (new.rowid, new.title, new.path, new.tags, new.headings, new.front_matter, new.body);
                END;
                CREATE TRIGGER notes_fts_delete AFTER DELETE ON notes BEGIN
                    INSERT INTO note_fts(note_fts, rowid, title, path, tags, headings, front_matter, body)
                    VALUES ('delete', old.rowid, old.title, old.path, old.tags, old.headings, old.front_matter, old.body);
                END;
                CREATE TRIGGER notes_fts_update AFTER UPDATE OF title, path, tags, headings, front_matter, body ON notes BEGIN
                    INSERT INTO note_fts(note_fts, rowid, title, path, tags, headings, front_matter, body)
                    VALUES ('delete', old.rowid, old.title, old.path, old.tags, old.headings, old.front_matter, old.body);
                    INSERT INTO note_fts(rowid, title, path, tags, headings, front_matter, body)
                    VALUES (new.rowid, new.title, new.path, new.tags, new.headings, new.front_matter, new.body);
                END;
                INSERT INTO note_fts(note_fts) VALUES ('rebuild');
                """)
        }
        try migrator.migrate(queue)
        let check = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
        guard check == "ok" else { throw TGSidianError.indexCorrupt(check ?? "quick_check returned no result") }
        return queue
    }

    private func quarantineDerivedDatabase(at url: URL) throws {
        databaseQueue = nil
        watcher?.stop()
        watcher = nil
        let identifier = UUID().uuidString
        let quarantine = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(identifier)")
            .appendingPathExtension(url.pathExtension.isEmpty ? "sqlite" : url.pathExtension)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.moveItem(at: url, to: quarantine)
        }
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(
                    at: source,
                    to: URL(fileURLWithPath: quarantine.path + suffix)
                )
            }
        }
    }

    private struct LinkResolutionIdentity: Equatable {
        let path: String
        let filename: String
        let title: String
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    @discardableResult
    private static func upsert(
        _ note: IndexedNote,
        in db: Database,
        encoder: JSONEncoder
    ) throws -> Bool {
        let previousIdentity = try Row.fetchOne(
            db,
            sql: "SELECT path, title FROM notes WHERE id = ?",
            arguments: [note.id.rawValue]
        ).map { row in
            try linkResolutionIdentity(
                path: RelativePath(row["path"] as String),
                title: row["title"]
            )
        }
        let preservesResolutionIdentity = previousIdentity == linkResolutionIdentity(
            path: note.path,
            title: note.parsed.title
        )
        let parsedData = try encoder.encode(note)
        let tags = note.parsed.tags.sorted()
        let tagsJSON = String(decoding: try encoder.encode(tags), as: UTF8.self)
        let headings = note.parsed.headings.map(\.text)
        let frontMatter = note.parsed.frontMatter.keys.sorted().map { key in
            "\(key): \(note.parsed.frontMatter[key]?.stringValue ?? "")"
        }.joined(separator: "\n")
        let normalizedTags = "\n" + tags.map(searchKey).joined(separator: "\n") + "\n"
        let normalizedHeadings = "\n" + headings.map(searchKey).joined(separator: "\n") + "\n"
        let noteType = note.parsed.frontMatter["type"]?.stringValue

        let upsertStatement = try db.cachedStatement(sql: """
            INSERT INTO notes (
                id, path, title, normalized_title, normalized_path,
                tags, normalized_tags, tags_json,
                headings, normalized_headings,
                front_matter, normalized_front_matter, body,
                note_type, normalized_type,
                modified_at, byte_count, content_hash, parsed_json, diagnostic_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                path = excluded.path,
                title = excluded.title,
                normalized_title = excluded.normalized_title,
                normalized_path = excluded.normalized_path,
                tags = excluded.tags,
                normalized_tags = excluded.normalized_tags,
                tags_json = excluded.tags_json,
                headings = excluded.headings,
                normalized_headings = excluded.normalized_headings,
                front_matter = excluded.front_matter,
                normalized_front_matter = excluded.normalized_front_matter,
                body = excluded.body,
                note_type = excluded.note_type,
                normalized_type = excluded.normalized_type,
                modified_at = excluded.modified_at,
                byte_count = excluded.byte_count,
                content_hash = excluded.content_hash,
                parsed_json = excluded.parsed_json,
                diagnostic_count = excluded.diagnostic_count
            """)
        try upsertStatement.execute(arguments: [
                note.id.rawValue,
                note.path.rawValue,
                note.parsed.title,
                searchKey(note.parsed.title),
                searchKey(note.path.rawValue),
                tags.joined(separator: " "),
                normalizedTags,
                tagsJSON,
                headings.joined(separator: "\n"),
                normalizedHeadings,
                frontMatter,
                searchKey(frontMatter),
                note.parsed.body,
                noteType,
                noteType.map(searchKey),
                note.fingerprint.modificationDate.timeIntervalSince1970,
                note.fingerprint.byteCount,
                note.fingerprint.contentHash,
                parsedData,
                note.parsed.diagnostics.count
            ])
        try db.cachedStatement(sql: "DELETE FROM links WHERE source_id = ?")
            .execute(arguments: [note.id.rawValue])
        let insertLink = try db.cachedStatement(sql: """
            INSERT INTO links (source_id, ordinal, raw_target, heading, line)
            VALUES (?, ?, ?, ?, ?)
            """)
        for (ordinal, link) in note.parsed.links.enumerated() {
            try insertLink.execute(arguments: [
                note.id.rawValue,
                ordinal,
                link.rawTarget,
                link.heading,
                link.line
            ])
        }
        return preservesResolutionIdentity
    }

    private static func linkResolutionIdentity(
        path: RelativePath,
        title: String
    ) -> LinkResolutionIdentity {
        LinkResolutionIdentity(
            path: NotePathIdentity.key(path.deletingPathExtension.rawValue),
            filename: NotePathIdentity.key(path.nameWithoutExtension),
            title: NotePathIdentity.key(title)
        )
    }

    private struct LinkResolutionCandidate {
        let id: String
        let path: String
        let filename: String
        let title: String
    }

    private struct LinkResolutionIndex {
        let exactPaths: [String: String]
        let filenames: [String: [LinkResolutionCandidate]]
        let titles: [String: [LinkResolutionCandidate]]
    }

    private static func makeLinkResolutionIndex(in db: Database) throws -> LinkResolutionIndex {
        let candidates: [LinkResolutionCandidate] = try Row.fetchAll(
            db,
            sql: "SELECT id, path, title FROM notes"
        ).map { row in
            let path: String = row["path"]
            let relative = try RelativePath(path)
            return LinkResolutionCandidate(
                id: row["id"],
                path: NotePathIdentity.key(relative.deletingPathExtension.rawValue),
                filename: NotePathIdentity.key(relative.nameWithoutExtension),
                title: NotePathIdentity.key(row["title"] as String)
            )
        }
        // Discovery and NoteID use the same path key, so legal whitespace/diacritic pairs stay
        // distinct. The uniquing closure is a final safety net for a legacy or externally seeded
        // database: it is deterministic and can never trap the process.
        let exactPaths = Dictionary(
            candidates.map { ($0.path, $0.id) },
            uniquingKeysWith: { min($0, $1) }
        )
        return LinkResolutionIndex(
            exactPaths: exactPaths,
            filenames: Dictionary(grouping: candidates, by: \.filename),
            titles: Dictionary(grouping: candidates, by: \.title)
        )
    }

    private static func updateLinkResolutions(
        _ links: [Row],
        using index: LinkResolutionIndex,
        in db: Database
    ) throws {
        let update = try db.cachedStatement(sql: """
            UPDATE links SET target_id = ?, status = ?
            WHERE source_id = ? AND ordinal = ?
            """)
        for link in links {
            let rawTarget: String = link["raw_target"]
            var target = NotePathIdentity.key(rawTarget.replacingOccurrences(of: "\\", with: "/"))
            if target.hasSuffix(".md") { target.removeLast(3) }
            let targetID: String?
            let status: String
            if let exact = index.exactPaths[target] {
                targetID = exact
                status = "resolved"
            } else if !target.contains("/"),
                      let matches = index.filenames[target],
                      matches.count == 1 {
                targetID = matches[0].id
                status = "resolved"
            } else if !target.contains("/"),
                      let matches = index.titles[target],
                      matches.count == 1 {
                targetID = matches[0].id
                status = "resolved"
            } else {
                let ambiguous = !target.contains("/")
                    && ((index.filenames[target]?.count ?? 0) > 1
                        || (index.titles[target]?.count ?? 0) > 1)
                targetID = nil
                status = ambiguous ? "ambiguous" : "unresolved"
            }
            try update.execute(arguments: [
                targetID,
                status,
                link["source_id"] as String,
                link["ordinal"] as Int
            ])
        }
    }

    private static func refreshLinkResolutions(in db: Database) throws {
        let index = try makeLinkResolutionIndex(in: db)
        let links = try Row.fetchAll(
            db,
            sql: "SELECT source_id, ordinal, raw_target FROM links"
        )
        try updateLinkResolutions(links, using: index, in: db)
        try db.execute(sql: """
            UPDATE notes
            SET has_unresolved_links = EXISTS (
                SELECT 1 FROM links
                WHERE links.source_id = notes.id AND links.status != 'resolved'
            )
            """)
    }

    /// When a save keeps the note's path, filename, and title identities unchanged, no inbound
    /// link can resolve differently. Resolve only the replaced outgoing links and update this
    /// note's unresolved flag; identity-changing edits continue through the whole-vault path.
    private static func refreshLinkResolutions(
        forSourceID sourceID: String,
        in db: Database
    ) throws {
        let index = try makeLinkResolutionIndex(in: db)
        let links = try Row.fetchAll(
            db,
            sql: """
                SELECT source_id, ordinal, raw_target
                FROM links
                WHERE source_id = ?
                """,
            arguments: [sourceID]
        )
        try updateLinkResolutions(links, using: index, in: db)
        try db.execute(sql: """
            UPDATE notes
            SET has_unresolved_links = EXISTS (
                SELECT 1 FROM links
                WHERE links.source_id = notes.id AND links.status != 'resolved'
            )
            WHERE id = ?
            """, arguments: [sourceID])
    }

    private static let summarySelect = """
        SELECT id, path, title, tags_json, note_type, modified_at FROM notes
        """

    private static func summary(from row: Row) throws -> NoteSummary {
        try summary(from: row, decoder: JSONDecoder())
    }

    private static func summary(from row: Row, decoder: JSONDecoder) throws -> NoteSummary {
        let path = try RelativePath(row["path"] as String)
        let tagsJSON: String = row["tags_json"]
        let tags = Set(try decoder.decode([String].self, from: Data(tagsJSON.utf8)))
        return NoteSummary(
            id: NoteID(rawValue: row["id"]),
            path: path,
            title: row["title"],
            tags: tags,
            type: row["note_type"],
            modifiedAt: Date(timeIntervalSince1970: row["modified_at"])
        )
    }

    private static func ftsSearch(
        _ request: SearchRequest,
        normalizedQuery query: String,
        queue: DatabaseQueue
    ) throws -> [SearchHit] {
        guard let ftsQuery = ftsQuery(query) else { return [] }
        let prefix = escapedLike(query) + "%"
        let folder = request.folder.map { searchKey($0.rawValue) }
        let folderPattern = folder.map { escapedLike($0) + "/%" }
        let type = request.type.map(searchKey)
        let tag = request.tag.map(searchKey)
        let modified = request.modifiedAfter?.timeIntervalSince1970
        let unresolved = request.hasUnresolvedLinks.map { $0 ? 1 : 0 }
        let arguments: StatementArguments = [
            query, prefix, query, query, query, query, query, query,
            ftsQuery,
            folder, folderPattern,
            type, type,
            tag, tag,
            modified, modified,
            unresolved, unresolved,
            request.limit
        ]
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.id, n.path, n.title, n.tags_json, n.note_type, n.modified_at,
                       CASE
                         WHEN n.normalized_title = ? THEN 1000000
                         WHEN n.normalized_title LIKE ? ESCAPE '\\' THEN 700000
                         WHEN instr(n.normalized_title, ?) > 0 THEN 500000
                         WHEN instr(n.normalized_tags, char(10) || ? || char(10)) > 0 THEN 450000
                         WHEN instr(n.normalized_headings, char(10) || ? || char(10)) > 0 THEN 400000
                         WHEN instr(n.normalized_headings, ?) > 0 THEN 250000
                         WHEN instr(n.normalized_path, ?) > 0 THEN 150000
                         WHEN instr(n.normalized_front_matter, ?) > 0 THEN 100000
                         ELSE 50000
                       END AS score,
                       snippet(note_fts, 5, '', '', ' … ', 24) AS excerpt,
                       bm25(note_fts, 20.0, 10.0, 8.0, 6.0, 4.0, 1.0) AS fts_rank
                FROM note_fts
                JOIN notes n ON n.rowid = note_fts.rowid
                WHERE note_fts MATCH ?
                  AND (? IS NULL OR n.normalized_path LIKE ? ESCAPE '\\')
                  AND (? IS NULL OR n.normalized_type = ?)
                  AND (? IS NULL OR instr(n.normalized_tags, char(10) || ? || char(10)) > 0)
                  AND (? IS NULL OR n.modified_at >= ?)
                  AND (? IS NULL OR n.has_unresolved_links = ?)
                ORDER BY score DESC, fts_rank ASC, n.modified_at DESC, n.path COLLATE NOCASE, n.path
                LIMIT ?
                """, arguments: arguments)
        }
        return try rows.map { row in
            SearchHit(
                note: try summary(from: row),
                score: row["score"],
                excerpt: cleanExcerpt(row["excerpt"] as String)
            )
        }
    }

    private static func filteredNotes(_ request: SearchRequest, queue: DatabaseQueue) throws -> [SearchHit] {
        let folder = request.folder.map { searchKey($0.rawValue) }
        let folderPattern = folder.map { escapedLike($0) + "/%" }
        let type = request.type.map(searchKey)
        let tag = request.tag.map(searchKey)
        let modified = request.modifiedAfter?.timeIntervalSince1970
        let unresolved = request.hasUnresolvedLinks.map { $0 ? 1 : 0 }
        let arguments: StatementArguments = [
            folder, folderPattern,
            type, type,
            tag, tag,
            modified, modified,
            unresolved, unresolved,
            request.limit
        ]
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, path, title, tags_json, note_type, modified_at,
                       0 AS score, substr(body, 1, 240) AS excerpt
                FROM notes
                WHERE (? IS NULL OR normalized_path LIKE ? ESCAPE '\\')
                  AND (? IS NULL OR normalized_type = ?)
                  AND (? IS NULL OR instr(normalized_tags, char(10) || ? || char(10)) > 0)
                  AND (? IS NULL OR modified_at >= ?)
                  AND (? IS NULL OR has_unresolved_links = ?)
                ORDER BY modified_at DESC, path COLLATE NOCASE, path
                LIMIT ?
                """, arguments: arguments)
        }
        return try rows.map { row in
            SearchHit(
                note: try summary(from: row),
                score: 0,
                excerpt: cleanExcerpt(row["excerpt"] as String)
            )
        }
    }

    private static func ftsQuery(_ query: String) -> String? {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " AND ")
    }

    private static func escapedLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func cleanExcerpt(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= 240 ? clean : String(clean.prefix(237)) + "…"
    }

    private static func excerpt(_ body: String, query: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let selected = query.isEmpty
            ? lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            : lines.first(where: { searchKey($0).contains(query) })
        return cleanExcerpt(selected ?? "")
    }

    private static func surroundingExcerpt(
        in parsed: ParsedNote,
        sourceLine: Int,
        rawTarget: String
    ) -> String {
        let lines = parsed.body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let frontMatterLineCount: Int = {
            guard let raw = parsed.rawFrontMatter, !raw.isEmpty else { return 0 }
            return raw.split(separator: "\n", omittingEmptySubsequences: false).count
        }()
        let bodyOffset = parsed.rawFrontMatter == nil ? 0 : frontMatterLineCount + 2
        let reportedIndex = sourceLine - bodyOffset - 1
        let matchingIndex = lines.indices.contains(reportedIndex)
            && lines[reportedIndex].localizedCaseInsensitiveContains("[[\(rawTarget)")
            ? reportedIndex
            : lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("[[\(rawTarget)") })

        guard let matchingIndex else {
            return excerpt(parsed.body, query: searchKey(rawTarget))
        }
        let lowerBound = max(lines.startIndex, matchingIndex - 1)
        let upperBound = min(lines.endIndex, matchingIndex + 2)
        let context = lines[lowerBound..<upperBound]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: "  …  ")
        return cleanExcerpt(context.isEmpty ? lines[matchingIndex] : context)
    }

    private static func searchKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func databaseTotals(_ queue: DatabaseQueue) throws -> (notes: Int, diagnostics: Int) {
        try queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS note_count, COALESCE(SUM(diagnostic_count), 0) AS diagnostic_count FROM notes"
            )!
            return (row["note_count"], row["diagnostic_count"])
        }
    }

    private func establishEventBaselineIfNeeded(in queue: DatabaseQueue) throws {
        let hasBaseline = try queue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM metadata WHERE key = 'last_fsevent_id')"
            ) ?? false
        }
        if !hasBaseline {
            try Self.storeLastEventID(FSEventsVaultWatcher.currentEventID, in: queue)
        }
    }

    private static func storeLastEventID(_ eventID: UInt64?, in queue: DatabaseQueue) throws {
        guard let eventID else { return }
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO metadata(key, value) VALUES ('last_fsevent_id', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [String(eventID)])
        }
    }

    private func checkCancellation(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard token == cancellationGeneration else { throw CancellationError() }
    }

    private func emitProgress(
        _ handler: (@Sendable (IndexProgress) -> Void)?,
        phase: IndexProgress.Phase,
        completed: Int,
        total: Int
    ) {
        guard completed == total || completed == 1 || completed.isMultiple(of: 25) else { return }
        instrument.event(.initialIndexProgress)
        handler?(IndexProgress(phase: phase, completed: completed, total: total))
    }
}

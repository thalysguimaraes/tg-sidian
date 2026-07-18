import AppCore
import Foundation
import GRDB
import IndexKit
import TestSupport
import Testing

@Suite("Production SQLite and FSEvents index", .serialized)
struct IndexProductionTests {
    @Test("schema migrations create documented derived tables without changing Markdown")
    func documentedSchema() async throws {
        let fixture = try acceptanceFixture()
        let before = try markdownBytes(root: fixture.rootURL)
        let support = temporarySupport("schema")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = support.appendingPathComponent("index.sqlite")
        let index = IndexActor(storageURL: store)

        let report = try await index.rebuild(from: fixture.vault)
        #expect(report.indexedCount == before.count)
        #expect(try await index.appliedSchemaMigrations() == ["v1-core", "v2-fts5"])
        await index.close()

        let database = try DatabaseQueue(path: store.path)
        let objects = try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type IN ('table', 'view')
                ORDER BY name
                """)
        }
        #expect(objects.contains("notes"))
        #expect(objects.contains("links"))
        #expect(objects.contains("metadata"))
        #expect(objects.contains("note_fts"))
        #expect(try markdownBytes(root: fixture.rootURL) == before)
    }

    @Test("ranking tiers are exact title, title prefix, tag, heading, front matter, then body")
    func predictableRanking() async throws {
        let fixture = try TemporaryVault(emptyNamed: "ranking")
        try fixture.directWrite("---\ntitle: Quantum\n---\nUnrelated text.\n", to: "01-exact.md")
        try fixture.directWrite("---\ntitle: Quantum Mechanics\n---\nUnrelated text.\n", to: "02-prefix.md")
        try fixture.directWrite("---\ntitle: Tag Match\ntags: [quantum]\n---\nUnrelated text.\n", to: "03-tag.md")
        try fixture.directWrite("---\ntitle: Heading Match\n---\n## Quantum\nUnrelated text.\n", to: "04-heading.md")
        try fixture.directWrite("---\ntitle: Front Matter Match\ntopic: quantum\n---\nUnrelated text.\n", to: "05-front-matter.md")
        try fixture.directWrite("---\ntitle: Body Match\n---\nA paragraph about quantum systems.\n", to: "06-body.md")

        let index = IndexActor()
        _ = try await index.rebuild(from: fixture.vault)
        let hits = await index.search(SearchRequest(query: "quantum", limit: 10))

        #expect(hits.map(\.note.title) == [
            "Quantum", "Quantum Mechanics", "Tag Match", "Heading Match",
            "Front Matter Match", "Body Match"
        ])
        #expect(hits.map(\.score) == [1_000_000, 700_000, 450_000, 400_000, 100_000, 50_000])
        #expect(hits.allSatisfy { !$0.note.path.rawValue.isEmpty })
        #expect(hits.last?.excerpt.contains("quantum") == true)
    }

    @Test("create edit move rename delete and event gaps update canonical-path rows")
    func allIncrementalEventsAndGapReconciliation() async throws {
        let fixture = try TemporaryVault(emptyNamed: "events")
        let index = IndexActor()
        _ = try await index.rebuild(from: fixture.vault)

        try fixture.directWrite("---\ntitle: Created\ntags: [event]\n---\nFirst body.\n", to: "Created.md")
        _ = try await index.process(events: [
            VaultFileEvent(kind: .created, path: try RelativePath("Created.md"), eventID: 10)
        ], from: fixture.vault)
        #expect(await index.search(SearchRequest(query: "Created")).first?.note.path.rawValue == "Created.md")

        try fixture.directWrite("---\ntitle: Edited\ntags: [event]\n---\nSecond body.\n", to: "Created.md")
        _ = try await index.process(events: [
            VaultFileEvent(kind: .modified, path: try RelativePath("Created.md"), eventID: 11)
        ], from: fixture.vault)
        #expect(await index.search(SearchRequest(query: "Edited")).first?.note.path.rawValue == "Created.md")

        let movedURL = fixture.rootURL.appendingPathComponent("Moved/Edited.md")
        try FileManager.default.createDirectory(at: movedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.rootURL.appendingPathComponent("Created.md"),
            to: movedURL
        )
        _ = try await index.process(events: [
            VaultFileEvent(kind: .moved, path: try RelativePath("Created.md"), eventID: 12),
            VaultFileEvent(kind: .moved, path: try RelativePath("Moved/Edited.md"), eventID: 13)
        ], from: fixture.vault)
        #expect(await index.search(SearchRequest(query: "Edited")).first?.note.path.rawValue == "Moved/Edited.md")

        let renamedURL = fixture.rootURL.appendingPathComponent("Moved/Renamed.md")
        try FileManager.default.moveItem(at: movedURL, to: renamedURL)
        _ = try await index.process(events: [
            VaultFileEvent(kind: .renamed, path: try RelativePath("Moved/Edited.md"), eventID: 14),
            VaultFileEvent(kind: .renamed, path: try RelativePath("Moved/Renamed.md"), eventID: 15)
        ], from: fixture.vault)
        #expect(await index.search(SearchRequest(query: "Edited")).first?.note.path.rawValue == "Moved/Renamed.md")

        try FileManager.default.removeItem(at: renamedURL)
        _ = try await index.process(events: [
            VaultFileEvent(kind: .removed, path: try RelativePath("Moved/Renamed.md"), eventID: 16)
        ], from: fixture.vault)
        #expect(await index.search(SearchRequest(query: "Edited")).isEmpty)

        try fixture.directWrite("---\ntitle: Reconciled Gap\n---\nFound by a full scan.\n", to: "Gap.md")
        let gapReport = try await index.process(events: [
            VaultFileEvent(kind: .eventGap, eventID: 25)
        ], from: fixture.vault)
        #expect(gapReport.reconciledAfterGap)
        #expect(gapReport.lastEventID == 25)
        #expect(await index.search(SearchRequest(query: "Reconciled Gap")).first?.note.path.rawValue == "Gap.md")
    }

    @Test("cancelled rebuild preserves the previous complete index and reports progress")
    func rebuildCancellationAndProgress() async throws {
        let fixture = try TemporaryVault(emptyNamed: "cancel")
        try fixture.directWrite("---\ntitle: Stable\n---\nCanonical.\n", to: "Stable.md")
        let index = IndexActor()
        let progress = ProgressProbe()
        _ = try await index.rebuild(from: fixture.vault) { progress.append($0) }
        #expect(progress.values.first?.completed == 0)
        #expect(progress.values.last?.completed == 1)

        try FixtureVaultGenerator.generate(at: fixture.rootURL, noteCount: 1_000, seed: 138)
        let task = Task {
            try await index.rebuild(from: fixture.vault)
        }
        task.cancel()
        var wasCancelled = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            wasCancelled = true
        }
        #expect(wasCancelled)
        #expect(await index.allNotes().map(\.title) == ["Stable"])
    }

    @Test("migration failure quarantines only the derived database and rebuilds")
    func migrationFailureQuarantine() async throws {
        let fixture = try acceptanceFixture()
        let before = try markdownBytes(root: fixture.rootURL)
        let support = temporarySupport("migration")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = support.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        var incompatible: DatabaseQueue? = try DatabaseQueue(path: store.path)
        try await incompatible?.write { db in
            try db.execute(sql: "CREATE TABLE notes (incompatible TEXT NOT NULL)")
        }
        incompatible = nil

        let recovered = IndexActor(storageURL: store)
        let report = try await recovered.restoreOrRebuild(from: fixture.vault)
        #expect(report.rebuiltFromCorruption)
        #expect(report.indexedCount == before.count)
        let names = try FileManager.default.contentsOfDirectory(atPath: support.path)
        #expect(names.contains(where: { $0.contains("corrupt-") && $0.hasSuffix(".sqlite") }))
        #expect(try markdownBytes(root: fixture.rootURL) == before)
    }

    @Test("10k-note FTS5 exact-title search returns the first result within 100 ms")
    func tenThousandNoteFirstResultBudget() async throws {
        let fixture = try TemporaryVault(emptyNamed: "ten-thousand")
        try FixtureVaultGenerator.generate(at: fixture.rootURL, noteCount: 10_000, seed: 138)
        let support = temporarySupport("performance")
        defer { try? FileManager.default.removeItem(at: support) }
        let index = IndexActor(storageURL: support.appendingPathComponent("index.sqlite"))
        let report = try await index.rebuild(from: fixture.vault)
        #expect(report.indexedCount == 10_000)

        let clock = ContinuousClock()
        let start = clock.now
        let hits = await index.search(SearchRequest(query: "Note 9999", limit: 20))
        let elapsed = start.duration(to: clock.now)
        print("PENTA-138 10k first-result search: \(elapsed)")

        #expect(hits.first?.note.title == "Note 9999")
        #expect(elapsed < .milliseconds(100))
    }

    private func acceptanceFixture() throws -> TemporaryVault {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/AcceptanceVault", isDirectory: true)
        return try TemporaryVault(copying: url)
    }

    private func temporarySupport(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func markdownBytes(root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }
}

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IndexProgress] = []

    var values: [IndexProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: IndexProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}

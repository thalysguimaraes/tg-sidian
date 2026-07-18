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

    @Test("same-identity upserts refresh only outgoing links while identity changes refresh inbound links")
    func targetedAndFullLinkRefreshesAreEquivalent() async throws {
        let fixture = try TemporaryVault(emptyNamed: "targeted-link-refresh")
        try fixture.directWrite("---\ntitle: Friendly\n---\nTarget body.\n", to: "Opaque.md")
        try fixture.directWrite("---\ntitle: Other\n---\nOther body.\n", to: "Other.md")
        try fixture.directWrite("---\ntitle: Source\n---\n[[Friendly]]\n", to: "Source.md")

        let index = IndexActor()
        _ = try await index.rebuild(from: fixture.vault)
        let sourceID = NoteID(path: try RelativePath("Source.md"))
        let opaqueID = NoteID(path: try RelativePath("Opaque.md"))
        let otherID = NoteID(path: try RelativePath("Other.md"))

        var sourceConnection = await index.connections().first { $0.source == sourceID }
        #expect(sourceConnection?.target == opaqueID)
        #expect(sourceConnection?.status == .resolved)

        try fixture.directWrite("---\ntitle: Source\n---\n[[Other]]\n", to: "Source.md")
        try await index.upsert(fixture.vault.read(try RelativePath("Source.md")))
        sourceConnection = await index.connections().first { $0.source == sourceID }
        #expect(sourceConnection?.rawTarget == "Other")
        #expect(sourceConnection?.target == otherID)
        #expect(sourceConnection?.status == .resolved)
        #expect(await index.backlinks(to: otherID).map(\.source.id) == [sourceID])

        try fixture.directWrite("---\ntitle: Source\n---\n[[Friendly]]\n", to: "Source.md")
        try await index.upsert(fixture.vault.read(try RelativePath("Source.md")))
        try fixture.directWrite("---\ntitle: Away\n---\nTarget body changed.\n", to: "Opaque.md")
        try await index.upsert(fixture.vault.read(try RelativePath("Opaque.md")))

        sourceConnection = await index.connections().first { $0.source == sourceID }
        #expect(sourceConnection?.rawTarget == "Friendly")
        #expect(sourceConnection?.target == nil)
        #expect(sourceConnection?.status == .unresolved)
        #expect(await index.backlinks(to: opaqueID).isEmpty)
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

    @Test(
        "10k-note rebuild and same-identity upsert benchmark",
        .enabled(
            if: ProcessInfo.processInfo.environment["TG_PERFORMANCE_BENCHMARKS"] == "1",
            "Set TG_PERFORMANCE_BENCHMARKS=1 for explicit performance runs."
        )
    )
    func tenThousandNoteCorePerformance() async throws {
        let fixture = try TemporaryVault(emptyNamed: "ten-thousand-core-performance")
        try FixtureVaultGenerator.generate(at: fixture.rootURL, noteCount: 10_000, seed: 138)
        let support = temporarySupport("core-performance")
        defer { try? FileManager.default.removeItem(at: support) }
        let index = IndexActor(storageURL: support.appendingPathComponent("index.sqlite"))
        let clock = ContinuousClock()

        let discoveryStart = clock.now
        let paths = try await fixture.vault.listMarkdownFiles()
        let discovery = Self.milliseconds(discoveryStart.duration(to: clock.now))
        #expect(paths.count == 10_000)

        let rebuildStart = clock.now
        let report = try await index.rebuild(from: fixture.vault)
        let rebuild = Self.milliseconds(rebuildStart.duration(to: clock.now))
        #expect(report.indexedCount == 10_000)

        let searchStart = clock.now
        let hits = await index.search(SearchRequest(query: "Note 9999", limit: 20))
        let search = Self.milliseconds(searchStart.duration(to: clock.now))
        #expect(hits.first?.note.title == "Note 9999")

        let allNotesStart = clock.now
        let allNotes = await index.allNotes()
        let allNotesElapsed = Self.milliseconds(allNotesStart.duration(to: clock.now))
        #expect(allNotes.count == 10_000)

        let benchmarkPath = try RelativePath("Folder-19/Note-9999.md")
        var snapshots: [VaultFileSnapshot] = []
        snapshots.reserveCapacity(8)
        for sample in 0..<8 {
            let target = sample.isMultiple(of: 2) ? 0 : 1
            try fixture.directWrite(
                """
                ---
                title: Note 9999
                type: meeting
                tags: [fixture, tag-11]
                ---
                # Note 9999

                Incremental benchmark body \(sample).

                [[Note \(target)]]
                """,
                to: benchmarkPath.rawValue
            )
            snapshots.append(try await fixture.vault.read(benchmarkPath))
        }

        var upsertSamples: [Double] = []
        upsertSamples.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            let start = clock.now
            try await index.upsert(snapshot)
            upsertSamples.append(Self.milliseconds(start.duration(to: clock.now)))
        }

        let indexed = await index.indexedNote(id: NoteID(path: benchmarkPath))
        let sourceID = NoteID(path: benchmarkPath)
        let targetID = NoteID(path: try RelativePath("Folder-1/Note-1.md"))
        let previousTargetID = NoteID(path: try RelativePath("Folder-0/Note-0.md"))
        let sourceConnections = await index.connections().filter { $0.source == sourceID }
        let targetBacklinks = await index.backlinks(to: targetID)
        let previousTargetBacklinks = await index.backlinks(to: previousTargetID)
        #expect(indexed?.parsed.title == "Note 9999")
        #expect(indexed?.parsed.links.map(\.rawTarget) == ["Note 1"])
        #expect(try await index.indexedNoteCount() == 10_000)
        #expect(sourceConnections.count == 1)
        #expect(sourceConnections.first?.rawTarget == "Note 1")
        #expect(sourceConnections.first?.target == targetID)
        #expect(sourceConnections.first?.status == .resolved)
        #expect(targetBacklinks.contains { $0.source.id == sourceID })
        #expect(!previousTargetBacklinks.contains { $0.source.id == sourceID })
        #expect(await index.search(SearchRequest(query: "Incremental benchmark body 7")).first?.note.path == benchmarkPath)

        print(
            "TG-PERF 10k discovery_ms=\(Self.metric(discovery)) "
                + "rebuild_ms=\(Self.metric(rebuild)) "
                + "search_ms=\(Self.metric(search)) "
                + "all_notes_ms=\(Self.metric(allNotesElapsed)) "
                + "upsert_samples_ms=\(upsertSamples.map(Self.metric).joined(separator: ","))"
        )
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

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func metric(_ value: Double) -> String {
        String(format: "%.3f", value)
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

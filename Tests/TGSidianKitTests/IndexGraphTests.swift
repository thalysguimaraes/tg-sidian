import AppCore
import Foundation
import GraphKit
import IndexKit
import TestSupport
import Testing

@Suite("SQLite index, search, backlinks, and graph", .serialized)
struct IndexGraphTests {
    @Test("fixture rebuild produces ranked search and filters without changing Markdown")
    func rebuildAndSearch() async throws {
        let fixture = try makeFixture()
        let before = try markdownBytes(root: fixture.rootURL)
        let index = IndexActor()
        let report = try await index.rebuild(from: fixture.vault)
        #expect(report.indexedCount == before.count)
        #expect(report.skippedCount == 0)

        let exact = await index.search(SearchRequest(query: "Swift Concurrency"))
        #expect(exact.first?.note.title == "Swift Concurrency")
        #expect((exact.first?.score ?? 0) >= 1_000_000)

        let filtered = await index.search(SearchRequest(query: "", type: "tool", tag: "editor"))
        #expect(filtered.map(\.note.title) == ["Native Editor"])
        let malformed = await index.search(SearchRequest(query: "canonical"))
        #expect(malformed.contains(where: { $0.note.path.rawValue == "Broken.md" }))
        #expect(try markdownBytes(root: fixture.rootURL) == before)
    }

    @Test("restored snapshots reconcile external edits and deletions against canonical files")
    func restoredSnapshotReconciliation() async throws {
        let fixture = try makeFixture()
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = support.appendingPathComponent("index.sqlite")
        let initial = IndexActor(storageURL: store)
        _ = try await initial.rebuild(from: fixture.vault)
        await initial.close()

        try Data("---\ntitle: Changed Externally\ntype: idea\n---\nCanonical bytes win.\n".utf8)
            .write(to: fixture.rootURL.appendingPathComponent("Home.md"), options: .atomic)
        try FileManager.default.removeItem(at: fixture.rootURL.appendingPathComponent("Notes/Editor.md"))

        let restored = IndexActor(storageURL: store)
        _ = try await restored.restoreOrRebuild(from: fixture.vault)
        #expect(await restored.search(SearchRequest(query: "Changed Externally")).first?.note.title == "Changed Externally")
        let allNotes = await restored.allNotes()
        #expect(!allNotes.contains(where: { $0.title == "Native Editor" }))
    }

    @Test("resolved, unresolved, and ambiguous links remain distinguishable")
    func linkResolutionAndBacklinks() async throws {
        let fixture = try makeFixture()
        let index = IndexActor()
        _ = try await index.rebuild(from: fixture.vault)
        let connections = await index.connections()

        #expect(connections.contains(where: { $0.rawTarget == "Home" && $0.status == .resolved }))
        #expect(connections.contains(where: { $0.rawTarget == "Missing Note" && $0.status == .unresolved }))
        #expect(connections.contains(where: { $0.rawTarget == "Duplicate" && $0.status == .ambiguous }))

        let architectureID = NoteID(path: try RelativePath("Notes/Architecture.md"))
        let backlinks = await index.backlinks(to: architectureID)
        #expect(backlinks.contains(where: { $0.source.title == "Swift Concurrency" }))
        #expect(backlinks.contains(where: { $0.source.title == "Home" }))
    }

    @Test("local graph is bounded, connected, and deterministic")
    func localGraph() async throws {
        let fixture = try makeFixture()
        let index = IndexActor()
        _ = try await index.rebuild(from: fixture.vault)
        let graphEngine = LocalGraphEngine(index: index)
        let root = NoteID(path: try RelativePath("Home.md"))

        let first = try await graphEngine.graph(root: root, depth: 2, maxNodes: 150, maxEdges: 500)
        let second = try await graphEngine.graph(root: root, depth: 2, maxNodes: 150, maxEdges: 500)
        #expect(first.nodes.contains(where: { $0.note.title == "Architecture" }))
        #expect(first.nodes.contains(where: { $0.note.title == "Swift Concurrency" }))
        #expect(first.nodes.map(\.position) == second.nodes.map(\.position))
        #expect(first.nodes.count <= 150)
        #expect(first.edges.count <= 500)
    }

    /// The graph shows the whole vault, so it has no root and no depth bound: every indexed note
    /// appears whether or not anything links to it.
    @Test("the vault graph covers every indexed note and has no root")
    func vaultGraphCoversWholeVault() async throws {
        let fixture = try makeFixture()
        let index = IndexActor()
        _ = try await index.rebuild(from: fixture.vault)
        let graphEngine = LocalGraphEngine(index: index)

        let graph = try await graphEngine.vaultGraph()
        let indexed = await index.allNotes()

        #expect(graph.root == nil, "A whole-vault graph has no single origin")
        #expect(!graph.truncated)
        #expect(graph.nodes.count == indexed.count, "Every indexed note is a node")
        #expect(Set(graph.nodes.map(\.note.id)) == Set(indexed.map(\.id)))

        // Stable across identical requests, so refreshes do not reshuffle the layout.
        let second = try await graphEngine.vaultGraph()
        #expect(graph.nodes.map(\.position) == second.nodes.map(\.position))
    }

    /// Past the cap an arbitrary slice of a link graph is not a smaller link graph, so the
    /// most-connected notes are kept and the snapshot admits it is truncated.
    @Test("an over-cap vault graph keeps the most connected notes and reports truncation")
    func vaultGraphTruncatesToMostConnected() async throws {
        let fixture = try makeFixture()
        let index = IndexActor()
        _ = try await index.rebuild(from: fixture.vault)
        let graphEngine = LocalGraphEngine(index: index)

        let full = try await graphEngine.vaultGraph()
        try #require(full.nodes.count > 2, "Fixture needs enough notes to truncate")

        let capped = try await graphEngine.vaultGraph(maxNodes: 2, maxEdges: 20_000)
        #expect(capped.truncated)
        #expect(capped.nodes.count == 2)

        // Every retained edge connects two retained nodes; degree never counts absent notes.
        let retained = Set(capped.nodes.map(\.note.id))
        #expect(capped.edges.allSatisfy { retained.contains($0.source) && retained.contains($0.target) })
        for node in capped.nodes {
            let actual = capped.edges.count { $0.source == node.note.id || $0.target == node.note.id }
            #expect(node.degree == actual, "Degree counts only visible connections")
        }
    }

    @Test("corrupt derived snapshots are quarantined and rebuilt from Markdown")
    func corruptionRecovery() async throws {
        let fixture = try makeFixture()
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = support.appendingPathComponent("index.sqlite")

        let first = IndexActor(storageURL: store)
        _ = try await first.rebuild(from: fixture.vault)
        await first.close()
        try Data("not-a-sqlite-database".utf8).write(to: store, options: .atomic)

        let recovered = IndexActor(storageURL: store)
        let report = try await recovered.restoreOrRebuild(from: fixture.vault)
        #expect(report.rebuiltFromCorruption)
        #expect(await recovered.search(SearchRequest(query: "Home")).first?.note.title == "Home")
        let names = try FileManager.default.contentsOfDirectory(atPath: support.path)
        #expect(names.contains(where: { $0.contains("corrupt-") }))
    }

    private func makeFixture() throws -> TemporaryVault {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/AcceptanceVault", isDirectory: true)
        return try TemporaryVault(copying: url)
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

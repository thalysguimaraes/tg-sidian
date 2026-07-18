import AppCore
@testable import FeatureUI
import Foundation
import GraphKit
import IndexKit
import TestSupport
import Testing
import VaultKit

@Suite("PENTA-140 contextual navigation", .serialized)
struct PENTA140ContextualNavigationTests {
    /// Layout is all-pairs, so the per-pair cost is paid ~n²/2 times per iteration. Keying the
    /// inner loop by NoteID put a String hash on that path and made vault-scale layout take tens
    /// of seconds; the simulation runs over flat arrays instead. The budget is deliberately far
    /// above the measured time so it catches that class of regression, not normal variance.
    @Test("vault-scale layout stays within budget", .timeLimit(.minutes(1)))
    func vaultScaleLayoutBudget() async throws {
        let count = 800
        let ids = (0..<count).map { NoteID(rawValue: "note-\($0)") }
        let edges = (1..<count).map { GraphEdge(source: ids[$0], target: ids[$0 / 2]) }
        let layout = GraphLayoutActor()

        let started = Date()
        let positions = try await layout.layout(nodeIDs: ids, edges: edges)
        let elapsed = Date().timeIntervalSince(started) * 1_000

        print("PENTA-140 metric: \(count)-node layout = \(String(format: "%.0f", elapsed)) ms")
        #expect(positions.count == count)
        #expect(elapsed < 4_000, "800-node layout took \(elapsed) ms; expected well under 4 s")
        // Positions stay inside the simulation's clamp rather than flying apart. The clamp
        // scales with √n so whole-vault graphs spread instead of packing into a fixed box.
        let bound = max(500.0, 26.0 * Double(count).squareRoot())
        #expect(positions.values.allSatisfy { abs($0.x) <= bound && abs($0.y) <= bound })
    }

    @Test("fitting the local graph never magnifies a sparse graph")
    func graphFitOnlyZoomsOut() {
        let inspector = CGSize(width: 292, height: 176)

        // A single note collapses to the minimum content box. Fitting it must not zoom in.
        let sparse = LocalGraphCamera.fitScale(
            contentSize: CGSize(width: 36, height: 36),
            viewSize: inspector
        )
        #expect(sparse == 1, "A sparse graph renders at natural size, never magnified")

        // A graph larger than the inspector still zooms out far enough to fit both axes.
        let dense = LocalGraphCamera.fitScale(
            contentSize: CGSize(width: 1_460, height: 352),
            viewSize: inspector
        )
        #expect(dense == 5, "Fitting scales by the tighter axis")

        let enormous = LocalGraphCamera.fitScale(
            contentSize: CGSize(width: 100_000, height: 100_000),
            viewSize: inspector
        )
        #expect(enormous == LocalGraphCamera.maximumScale, "Fitting stays within the zoom ceiling")
    }

    @Test("custom daily-note paths, templates, locale, and time zone are idempotent under concurrency")
    func configurableDailyNotes() async throws {
        let temporary = try TemporaryVault(emptyNamed: "daily-configuration")
        try temporary.directWrite(
            "# {{title}}\n\nCreated for {{date}}.\n",
            to: "Templates/Journal.md"
        )
        let configuration = DailyNoteConfiguration(
            folder: try RelativePath("Journal"),
            filenamePattern: "yyyy-MM-dd",
            templatePath: try RelativePath("Templates/Journal.md"),
            localeIdentifier: "fr_FR",
            timeZoneIdentifier: "Europe/Paris",
            calendarIdentifier: "gregorian"
        )
        let service = DailyNoteService(vault: temporary.vault, configuration: configuration)
        let date = try #require(configuration.calendar.date(from: DateComponents(
            timeZone: configuration.calendar.timeZone,
            year: 2026,
            month: 3,
            day: 29,
            hour: 12
        )))

        let snapshots = try await withThrowingTaskGroup(of: VaultFileSnapshot.self) { group in
            for _ in 0..<12 {
                group.addTask { try await service.openOrCreate(date: date) }
            }
            var snapshots: [VaultFileSnapshot] = []
            for try await snapshot in group { snapshots.append(snapshot) }
            return snapshots
        }

        let expectedPath = try RelativePath("Journal/2026-03-29.md")
        #expect(Set(snapshots.map(\.path)) == [expectedPath])
        #expect(Set(snapshots.map(\.fingerprint)).count == 1)
        #expect(snapshots.first?.content == "# 2026-03-29\n\nCreated for 2026-03-29.\n")
        #expect(try await temporary.vault.listMarkdownFiles().filter { $0 == expectedPath }.count == 1)
    }

    @Test("daily-note preferences persist and recent canonical dates sort newest first")
    @MainActor
    func persistedConfigurationAndRecentDates() async throws {
        let temporary = try TemporaryVault(emptyNamed: "recent-daily-notes")
        try temporary.directWrite("# Older\n", to: "Journal/2026-03-27.md")
        try temporary.directWrite("# Newer\n", to: "Journal/2026-03-29.md")
        try temporary.directWrite("# Not daily\n", to: "Notes/2026-03-30.md")
        let configuration = DailyNoteConfiguration(
            folder: try RelativePath("Journal"),
            filenamePattern: "yyyy-MM-dd'.md'",
            localeIdentifier: "en_US_POSIX",
            timeZoneIdentifier: "UTC"
        )
        let workspace = VaultWorkspaceState(dailyNoteConfiguration: configuration)
        let store = InMemoryVaultWorkspaceStateStore(storage: [temporary.vault.vaultID: workspace])
        let index = IndexActor()
        _ = try await index.rebuild(from: temporary.vault)
        let session = try makeSession(
            temporary,
            index: index,
            workspaceState: workspace,
            stateStore: store
        )
        await session.load()

        #expect(session.recentDailyNotes.map(\.path.rawValue) == [
            "Journal/2026-03-29.md",
            "Journal/2026-03-27.md"
        ])
        await session.openNote(at: try RelativePath("Journal/2026-03-29.md"))
        #expect(session.currentDailyNoteDate.map(configuration.filename(for:)) == "2026-03-29.md")

        let updated = DailyNoteConfiguration(
            folder: try RelativePath("Log"),
            filenamePattern: "yyyyMMdd'.markdown'",
            templatePath: try RelativePath("Templates/Log.md"),
            localeIdentifier: "en_GB",
            timeZoneIdentifier: "Europe/London",
            calendarIdentifier: "iso8601"
        )
        await session.updateDailyNoteConfiguration(updated)
        #expect(store.load(vaultID: temporary.vault.vaultID).dailyNoteConfiguration == updated)
    }

    @Test("backlinks refresh after edits with source, heading, and surrounding excerpt")
    @MainActor
    func liveBacklinkContext() async throws {
        let temporary = try TemporaryVault(emptyNamed: "backlink-refresh")
        try temporary.directWrite("# Target\n", to: "Target.md")
        try temporary.directWrite(
            "# Source\n\n## Planning\nBefore context.\nConnects to [[Target]] here.\nAfter context.\n",
            to: "Source.md"
        )
        let index = IndexActor()
        _ = try await index.rebuild(from: temporary.vault)
        let targetID = NoteID(path: try RelativePath("Target.md"))

        var backlink = try #require(await index.backlinks(to: targetID).first)
        #expect(backlink.source.path.rawValue == "Source.md")
        #expect(backlink.heading == "Planning")
        #expect(backlink.excerpt.contains("Before context."))
        #expect(backlink.excerpt.contains("Connects to [[Target]] here."))
        #expect(backlink.excerpt.contains("After context."))

        let sourcePath = try RelativePath("Source.md")
        let previous = try await temporary.vault.read(sourcePath)
        let updated = try await temporary.vault.atomicWrite(
            "# Source\n\n## Updated heading\nNew before.\nA revised [[Target]] reference.\nNew after.\n",
            to: sourcePath,
            expectedFingerprint: previous.fingerprint
        )
        try await index.upsert(updated)
        backlink = try #require(await index.backlinks(to: targetID).first)
        #expect(backlink.heading == "Updated heading")
        #expect(backlink.excerpt.contains("New before."))
        #expect(backlink.excerpt.contains("A revised [[Target]] reference."))
        #expect(backlink.excerpt.contains("New after."))
        #expect(!backlink.excerpt.contains("Before context."))

        let session = try makeSession(temporary, index: index)
        await session.openNote(at: backlink.source.path)
        #expect(session.route == .note(backlink.source.id))
    }

    @Test("local graph enforces its production cap and lays out 150 nodes within budget")
    func boundedGraphPerformance() async throws {
        let temporary = try TemporaryVault(emptyNamed: "graph-budget")
        try temporary.directWrite("# Root\n", to: "Root.md")
        for index in 0..<239 {
            try temporary.directWrite(
                "# Node \(index)\n\n[[Root]]\n",
                to: "Nodes/Node-\(index).md"
            )
        }
        let index = IndexActor()
        _ = try await index.rebuild(from: temporary.vault)
        let engine = LocalGraphEngine(index: index)
        let root = NoteID(path: try RelativePath("Root.md"))
        let clock = ContinuousClock()

        let start = clock.now
        let graph = try await engine.graph(
            root: root,
            depth: 99,
            maxNodes: 10_000,
            maxEdges: 10_000
        )
        let elapsed = Self.milliseconds(start.duration(to: clock.now))
        print(
            "PENTA-140 metric: capped graph = \(graph.nodes.count) nodes / "
                + "\(graph.edges.count) edges in \(String(format: "%.2f", elapsed)) ms"
        )

        #expect(graph.nodes.count <= 150)
        #expect(graph.edges.count <= 500)
        #expect(graph.truncated)
        #expect(elapsed < 1_000, "Bounded graph took \(elapsed) ms")
    }

    @Test("layout cache is stable and cancellation stops stale spatial work")
    func layoutCacheAndCancellation() async throws {
        let layout = GraphLayoutActor()
        let ids = (0..<150).map { NoteID(rawValue: "node-\($0)") }
        let edges = (1..<ids.count).map { GraphEdge(source: ids[$0 - 1], target: ids[$0]) }
        let clock = ContinuousClock()

        let firstStart = clock.now
        let first = try await layout.layout(nodeIDs: ids, edges: edges, iterations: 80)
        let firstElapsed = Self.milliseconds(firstStart.duration(to: clock.now))
        let secondStart = clock.now
        let second = try await layout.layout(nodeIDs: ids, edges: edges, iterations: 80)
        let secondElapsed = Self.milliseconds(secondStart.duration(to: clock.now))
        print(
            "PENTA-140 metric: 150-node layout first \(String(format: "%.2f", firstElapsed)) ms, "
                + "cached \(String(format: "%.2f", secondElapsed)) ms"
        )

        #expect(first == second)
        #expect(secondElapsed < firstElapsed, "Cached \(secondElapsed) ms should beat first \(firstElapsed) ms")

        let cancellation = Task {
            try await layout.layout(
                nodeIDs: (0..<400).map { NoteID(rawValue: "cancel-\($0)") },
                edges: [],
                iterations: 10_000
            )
        }
        cancellation.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancellation.value
        }
    }

    @Test("SpriteKit graph has equivalent outline, native controls, and Reduce Motion cross-fade")
    func graphAccessibilityContract() throws {
        let root = repositoryRoot()
        let inspector = try String(
            contentsOf: root.appendingPathComponent("Packages/TGSidianKit/Sources/FeatureUI/InspectorView.swift"),
            encoding: .utf8
        )
        let sprite = try String(
            contentsOf: root.appendingPathComponent("Packages/TGSidianKit/Sources/FeatureUI/LocalGraphSpriteView.swift"),
            encoding: .utf8
        )

        #expect(sprite.contains("import SpriteKit"))
        #expect(sprite.contains("override func scrollWheel"))
        #expect(sprite.contains("override func magnify"))
        #expect(sprite.contains("override func mouseDragged"))
        #expect(sprite.contains("override func keyDown"))
        #expect(sprite.contains("fadeIn(withDuration: 0.12)"))
        #expect(inspector.contains("Visible graph connections"))
        #expect(inspector.contains("accessibilityConnectionSummary"))
        #expect(inspector.contains("nativeAccessibleButton"))
        #expect(!inspector.contains("Canvas {"))
    }

    /// The whole-vault graph must populate through the session's load path, the way the app
    /// reaches it — not only through a direct engine call.
    @MainActor
    @Test("loading a session publishes the vault graph")
    func sessionPublishesVaultGraph() async throws {
        let temporary = try TemporaryVault(emptyNamed: "session-vault-graph")
        try temporary.directWrite("# Home\n\n[[Architecture]]\n", to: "Home.md")
        try temporary.directWrite("# Architecture\n\n[[Home]]\n", to: "Architecture.md")
        try temporary.directWrite("# Orphan\n", to: "Orphan.md")
        let index = IndexActor()
        let session = try makeSession(temporary, index: index)

        await session.load()

        let graph = try #require(session.graph, "The session must publish a vault graph after load")
        #expect(graph.root == nil)
        #expect(graph.nodes.count == 3, "Every note appears, including the orphan")
        #expect(graph.edges.count == 1)
    }

    @MainActor
    private func makeSession(
        _ temporary: TemporaryVault,
        index: IndexActor,
        workspaceState: VaultWorkspaceState = VaultWorkspaceState(),
        stateStore: InMemoryVaultWorkspaceStateStore = InMemoryVaultWorkspaceStateStore()
    ) throws -> VaultSessionModel {
        let journal = try RecoveryJournal(
            directory: temporary.rootURL.appendingPathComponent(".recovery", isDirectory: true)
        )
        let saveCoordinator = SaveCoordinator(vault: temporary.vault, journal: journal)
        return VaultSessionModel(
            vaultID: temporary.vault.vaultID,
            displayName: "Test",
            vault: temporary.vault,
            index: index,
            graphEngine: LocalGraphEngine(index: index),
            dailyNotes: DailyNoteService(
                vault: temporary.vault,
                configuration: workspaceState.dailyNoteConfiguration
            ),
            saveCoordinator: saveCoordinator,
            workspaceState: workspaceState,
            workspaceStateStore: stateStore
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

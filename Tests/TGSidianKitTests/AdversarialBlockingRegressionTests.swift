import AppCore
@testable import FeatureUI
import Foundation
import GraphKit
import GRDB
import IndexKit
import TestSupport
import Testing
import VaultKit

@Suite("Final adversarial blocking regressions", .serialized)
@MainActor
struct AdversarialBlockingRegressionTests {
    @Test("B1 legal whitespace-distinct note paths never trap link resolution")
    func whitespaceDistinctPathsDoNotTrap() async throws {
        let temporary = try TemporaryVault(emptyNamed: "b1-whitespace")
        try temporary.directWrite("plain note", to: "Note.md")
        try temporary.directWrite("plain trailing note", to: "Note .md")
        try temporary.directWrite("plain leading note", to: " Note.md")
        try temporary.directWrite("[[Note]]\n[[Note ]]\n[[ Note]]\n", to: "Links.md")
        let index = IndexActor()

        let report = try await index.rebuild(from: temporary.vault)
        #expect(report.indexedCount == 4)
        #expect(try await temporary.vault.listMarkdownFiles().count == 4)
        #expect(await index.allNotes().map(\.path.rawValue).sorted() == [
            " Note.md", "Links.md", "Note .md", "Note.md"
        ])

        let connections = await index.connections().filter {
            $0.source == NoteID(path: try! RelativePath("Links.md"))
        }
        #expect(connections.count == 3)
        #expect(connections.allSatisfy { $0.status == .resolved })
        // Markdown syntax intentionally trims target-edge whitespace, so all three spellings
        // resolve to Note.md; the whitespace-distinct files still retain independent rows.
        #expect(Set(connections.compactMap(\.target)) == [NoteID(path: try RelativePath("Note.md"))])
        #expect(NotePathIdentity.key("Note") != NotePathIdentity.key("Note "))
        #expect(NotePathIdentity.key("Note") != NotePathIdentity.key(" Note"))
    }

    @Test("B2 accented filenames keep distinct stable rows across incremental and reconcile paths")
    func diacriticDistinctNoteIDsAndMigration() async throws {
        let temporary = try TemporaryVault(emptyNamed: "b2-diacritics")
        try temporary.directWrite("# Cafe\n", to: "Cafe.md")
        let storage = temporary.rootURL.appendingPathComponent("index.sqlite")
        let index = IndexActor(storageURL: storage)
        _ = try await index.rebuild(from: temporary.vault)
        #expect(try await index.indexedNoteCount() == 1)
        #expect(NoteID(path: try RelativePath("Cafe.md")).rawValue == "cafe")

        // This reproduces the legacy-database migration shape: the pre-existing unaccented row
        // keeps its historical id while a newly observed accented path gets a distinct id.
        try temporary.directWrite("# Café\n", to: "Café.md")
        let accentedPath = try RelativePath("Café.md")
        let incremental = try await index.process(
            events: [VaultFileEvent(kind: .created, path: accentedPath, eventID: 201)],
            from: temporary.vault
        )
        #expect(incremental.noteCount == 2)
        #expect(try await index.indexedNoteCount() == 2)
        #expect(NoteID(path: accentedPath).rawValue == "café")
        #expect(NoteID(path: try RelativePath("Cafe.md")) != NoteID(path: accentedPath))
        #expect(Set(await index.allNotes().map(\.path.rawValue)) == ["Cafe.md", "Café.md"])

        let reconciled = try await index.reconcile(from: temporary.vault)
        #expect(reconciled.indexedCount == 2)
        #expect(reconciled.skippedCount == 0)
        await index.close()

        // Seed the exact legacy collision shape: the historical `cafe` row was overwritten with
        // Café.md and the accented row did not exist. Matching fingerprints alone must not skip
        // correcting its stored path before the new `café` row is inserted.
        do {
            let legacy = try DatabaseQueue(path: storage.path)
            try await legacy.write { db in
                try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: ["café"])
                try db.execute(
                    sql: "UPDATE notes SET path = ? WHERE id = ?",
                    arguments: ["Café.md", "cafe"]
                )
            }
        }

        let reopened = IndexActor(storageURL: storage)
        let restored = try await reopened.restoreOrRebuild(from: temporary.vault)
        #expect(restored.indexedCount == 2)
        #expect(Set(await reopened.allNotes().map(\.id.rawValue)) == ["cafe", "café"])
        await reopened.close()
    }

    @Test("B3 conflicted navigation keeps the buffer and durably checkpoints latest edits")
    func conflictedNavigationIsBlockedAndJournaled() async throws {
        let temporary = try TemporaryVault(emptyNamed: "b3-navigation")
        try temporary.directWrite("note A\n", to: "A.md")
        try temporary.directWrite("note B\n", to: "B.md")
        let index = IndexActor()
        _ = try await index.rebuild(from: temporary.vault)
        let (session, coordinator) = try makeSession(vault: temporary.vault, index: index)
        let a = try RelativePath("A.md")
        let b = try RelativePath("B.md")
        await session.openNote(at: a)

        session.document.bufferDidChange(to: "PRECIOUS UNSAVED USER WORK\n")
        try temporary.directWrite("external rewrite\n", to: a.rawValue)
        await session.document.externalChangeDetected(try await temporary.vault.read(a))
        #expect(session.document.state.isConflicted)
        #expect(try await coordinator.pendingRecovery().map(\.attemptedContent) == [
            "PRECIOUS UNSAVED USER WORK\n"
        ])

        // Editing after the conflict and immediately navigating exercises flushPendingSave's
        // synchronous checkpoint-before-refusal path, not merely the initial conflict record.
        session.document.bufferDidChange(to: "LATEST PRECIOUS USER WORK\n")
        await session.openNote(at: b)
        #expect(session.document.path == a)
        #expect(session.document.text == "LATEST PRECIOUS USER WORK\n")
        #expect(session.document.state.isConflicted)
        #expect(session.route == .note(NoteID(path: a)))
        #expect(try await temporary.vault.read(a).content == "external rewrite\n")
        let pending = try await coordinator.pendingRecovery()
        #expect(pending.count == 1)
        #expect(pending.first?.path == a)
        #expect(pending.first?.attemptedContent == "LATEST PRECIOUS USER WORK\n")

        await session.document.resolveConflict(.reload)
        #expect(try await coordinator.pendingRecovery().isEmpty)
        await session.openNote(at: b)
        #expect(session.document.path == b)
        #expect(session.document.text == "note B\n")
    }

    @Test("B4 symlink vault discovery, clean reload, FSEvents, and status use the resolved root")
    func symlinkRootUsesRealDiscoveryAndWatcher() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-b4-\(UUID().uuidString)", isDirectory: true)
        let target = parent.appendingPathComponent("Real Vault", isDirectory: true)
        let link = parent.appendingPathComponent("Linked Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("# Seed\n".utf8).write(to: target.appendingPathComponent("Seed.md"))
        try Data("# Two\n".utf8).write(to: target.appendingPathComponent("Two.md"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let vault = try VaultActor(rootURL: link)
        #expect(vault.rootURL == target.resolvingSymlinksInPath().standardizedFileURL)
        #expect(try await vault.listMarkdownFiles().map(\.rawValue) == ["Seed.md", "Two.md"])

        let index = IndexActor(storageURL: parent.appendingPathComponent("index.sqlite"))
        let (session, _) = try makeSession(vault: vault, index: index)
        await session.load() // starts the production FSEventsVaultWatcher, not an injected event
        #expect(session.status == .idle(noteCount: 2))
        #expect(session.notes.count == 2)

        let seed = try RelativePath("Seed.md")
        await session.openNote(at: seed)
        try Data("# Seed externally changed\n".utf8).write(
            to: target.appendingPathComponent(seed.rawValue),
            options: .atomic
        )
        for _ in 0..<500 {
            if session.document.text == "# Seed externally changed\n" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.document.text == "# Seed externally changed\n")
        #expect(session.document.state == .clean)

        try Data("# External\n".utf8).write(
            to: target.appendingPathComponent("External.md"),
            options: .atomic
        )
        // The notes list and the status footer update in separate steps of the watcher
        // refresh, so poll for both rather than racing the second assertion.
        for _ in 0..<500 {
            if session.notes.contains(where: { $0.path.rawValue == "External.md" }),
               session.status == .idle(noteCount: 3) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.notes.contains { $0.path.rawValue == "External.md" })
        #expect(session.status == .idle(noteCount: 3))
        await index.stopWatching()
        await index.close()
    }

    @Test("B5 release workflow pins Xcode 26.6 and asserts Swift 6.2")
    func releaseWorkflowPinsCompatibleToolchain() throws {
        let root = repositoryRoot()
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let workflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        #expect(package.hasPrefix("// swift-tools-version: 6.2"))
        #expect(workflow.contains("runs-on: macos-26"))
        #expect(workflow.contains("maxim-lobanov/setup-xcode@v1"))
        #expect(workflow.contains("xcode-version: \"26.6\""))
        #expect(workflow.contains("Verify Swift 6.2 or newer"))
        #expect(workflow.contains(">= (6, 2)"))
        #expect(!workflow.contains("runs-on: macos-14"))
    }

    private func makeSession(
        vault: VaultActor,
        index: IndexActor
    ) throws -> (VaultSessionModel, SaveCoordinator) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-adversarial-support-\(UUID().uuidString)", isDirectory: true)
        let journal = try RecoveryJournal(directory: support.appendingPathComponent("Recovery", isDirectory: true))
        let coordinator = SaveCoordinator(vault: vault, journal: journal)
        let session = VaultSessionModel(
            vaultID: vault.vaultID,
            displayName: "Adversarial",
            vault: vault,
            index: index,
            graphEngine: LocalGraphEngine(index: index),
            dailyNotes: DailyNoteService(vault: vault),
            saveCoordinator: coordinator,
            workspaceState: VaultWorkspaceState(),
            workspaceStateStore: InMemoryVaultWorkspaceStateStore()
        )
        return (session, coordinator)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

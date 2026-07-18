import AppCore
import AppKit
@testable import FeatureUI
import Foundation
import GraphKit
import IndexKit
import MarkdownKit
import TestSupport
import Testing
import VaultKit

@Suite("PENTA-139 safe editing", .serialized)
@MainActor
struct PENTA139SafeEditingTests {
    @Test("clean external edits reload and dirty edits require an explicit conflict choice")
    func externalChangeStateMachine() async throws {
        let temporary = try TemporaryVault(emptyNamed: "external-change")
        try temporary.directWrite("# Base\n", to: "Note.md")
        let path = try RelativePath("Note.md")
        let (document, _) = try makeDocument(temporary)
        document.autosaveIdleInterval = .seconds(60)
        document.open(try await temporary.vault.read(path))
        document.caretOffset = 3

        try temporary.directWrite("# Disk one ✅\n", to: path.rawValue)
        await document.externalChangeDetected(try await temporary.vault.read(path))
        #expect(document.text == "# Disk one ✅\n")
        #expect(document.state == .clean)
        #expect(document.caretOffset == 3)

        document.bufferDidChange(to: "# Mine one 🧠\n")
        try temporary.directWrite("# Disk two 🌍\n", to: path.rawValue)
        await document.externalChangeDetected(try await temporary.vault.read(path))
        #expect(document.state.isConflicted)
        #expect(document.text == "# Mine one 🧠\n")

        let comparison = try #require(await document.conflictComparison())
        #expect(comparison.base == "# Disk one ✅\n")
        #expect(comparison.mine == "# Mine one 🧠\n")
        #expect(comparison.theirs == "# Disk two 🌍\n")
        #expect(comparison.hasOverlappingChanges)
        #expect(comparison.mergedDraft.contains("<<<<<<< Your edits"))

        // Edits made while the conflict banner is visible must be the bytes Keep Mine writes.
        document.bufferDidChange(to: "# Latest mine かな\n")
        await document.resolveConflict(.keepMine)
        #expect(document.state == .clean)
        #expect(try String(contentsOf: temporary.rootURL.appendingPathComponent(path.rawValue), encoding: .utf8) == "# Latest mine かな\n")

        document.bufferDidChange(to: "# Local to discard\n")
        try temporary.directWrite("# Reload target\n", to: path.rawValue)
        await document.externalChangeDetected(try await temporary.vault.read(path))
        await document.resolveConflict(.reload)
        #expect(document.state == .clean)
        #expect(document.text == "# Reload target\n")
    }

    @Test("merged drafts save against the compared disk revision")
    func mergeDraft() async throws {
        let temporary = try TemporaryVault(emptyNamed: "merge")
        try temporary.directWrite("base\n", to: "Note.md")
        let path = try RelativePath("Note.md")
        let (document, _) = try makeDocument(temporary)
        document.autosaveIdleInterval = .seconds(60)
        document.open(try await temporary.vault.read(path))
        document.bufferDidChange(to: "mine\n")
        try temporary.directWrite("theirs\n", to: path.rawValue)
        await document.externalChangeDetected(try await temporary.vault.read(path))

        await document.useMergedDraft("mine\ntheirs\n")
        #expect(document.state == .clean)
        #expect(try String(contentsOf: temporary.rootURL.appendingPathComponent(path.rawValue), encoding: .utf8) == "mine\ntheirs\n")
    }

    @Test("idle autosave persists complete UTF-8 through the atomic coordinator")
    func idleAutosave() async throws {
        let temporary = try TemporaryVault(emptyNamed: "idle-autosave")
        try temporary.directWrite("old", to: "Note.md")
        let path = try RelativePath("Note.md")
        let (document, _) = try makeDocument(temporary)
        document.autosaveIdleInterval = .milliseconds(20)
        document.open(try await temporary.vault.read(path))
        document.bufferDidChange(to: "autosaved ✅ かな")

        for _ in 0..<100 {
            if document.state == .clean { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(document.state == .clean)
        #expect(try String(contentsOf: temporary.rootURL.appendingPathComponent(path.rawValue), encoding: .utf8) == "autosaved ✅ かな")
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.rootURL.path)
            .allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test("a write failure preserves the original, complete UTF-8 recovery, and no temporary")
    func failedAtomicWriteRestoresFromJournal() async throws {
        struct InjectedFailure: Error {}

        let temporary = try TemporaryVault(emptyNamed: "write-failure")
        try temporary.directWrite("original\n", to: "Note.md")
        let path = try RelativePath("Note.md")
        let vaultID = temporary.vault.vaultID
        let guardedVault = try VaultActor(
            rootURL: temporary.rootURL,
            vaultID: vaultID,
            hooks: AtomicWriteHooks(afterTemporaryFileWritten: { temporaryURL in
                let data = try Data(contentsOf: temporaryURL)
                guard String(data: data, encoding: .utf8) == "replacement ✅ かな\n" else {
                    throw TGSidianError.invalidOperation("temporary was not complete UTF-8")
                }
                throw InjectedFailure()
            })
        )
        let journalURL = temporary.rootURL.appendingPathComponent(".recovery", isDirectory: true)
        let journal = try RecoveryJournal(directory: journalURL)
        let failing = SaveCoordinator(vault: guardedVault, journal: journal)
        let original = try await guardedVault.read(path)

        await #expect(throws: InjectedFailure.self) {
            _ = try await failing.save(
                "replacement ✅ かな\n",
                to: path,
                expectedFingerprint: original.fingerprint
            )
        }
        #expect(try String(contentsOf: temporary.rootURL.appendingPathComponent(path.rawValue), encoding: .utf8) == "original\n")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: temporary.rootURL.path)
        #expect(!siblings.contains { $0.hasSuffix(".tmp") })

        let normalVault = try VaultActor(rootURL: temporary.rootURL, vaultID: vaultID)
        let recovering = SaveCoordinator(vault: normalVault, journal: journal)
        let pending = try await recovering.pendingRecovery()
        let record = try #require(pending.first)
        #expect(record.attemptedContent == "replacement ✅ かな\n")
        let restored = try await recovering.restore(record)
        #expect(restored.content == "replacement ✅ かな\n")
        #expect(try await recovering.pendingRecovery().isEmpty)
    }

    @Test("a disk edit in the final replacement race is swapped back without loss")
    func finalAtomicSwapRaceRollsBack() async throws {
        let temporary = try TemporaryVault(emptyNamed: "swap-race")
        try temporary.directWrite("base", to: "Note.md")
        let path = try RelativePath("Note.md")
        let destination = temporary.rootURL.appendingPathComponent(path.rawValue)
        let guarded = try VaultActor(
            rootURL: temporary.rootURL,
            hooks: AtomicWriteHooks(beforeAtomicSwap: { _, _ in
                try Data("late external".utf8).write(to: destination)
            })
        )
        let original = try await guarded.read(path)

        await #expect(throws: TGSidianError.self) {
            _ = try await guarded.atomicWrite(
                "mine",
                to: path,
                expectedFingerprint: original.fingerprint
            )
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "late external")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: temporary.rootURL.path)
        #expect(!siblings.contains { $0.hasSuffix(".tmp") })
    }

    @Test("completed writes with uncleared crash journals are pruned safely")
    func staleCompletedJournalIsPruned() async throws {
        let temporary = try TemporaryVault(emptyNamed: "stale-journal")
        try temporary.directWrite("old", to: "Note.md")
        let path = try RelativePath("Note.md")
        let journal = try RecoveryJournal(
            directory: temporary.rootURL.appendingPathComponent(".recovery", isDirectory: true)
        )
        let original = try await temporary.vault.read(path)
        let record = RecoveryRecord(
            vaultID: temporary.vault.vaultID,
            path: path,
            attemptedContent: "new ✅",
            expectedFingerprint: original.fingerprint
        )
        try await journal.store(record)
        _ = try await temporary.vault.atomicWrite("new ✅", to: path, expectedFingerprint: original.fingerprint)

        let coordinator = SaveCoordinator(vault: temporary.vault, journal: journal)
        #expect(try await coordinator.pendingRecovery().isEmpty)
        #expect(try await journal.pending().isEmpty)
    }

    @Test("one malformed journal cannot hide a valid recovery record")
    func malformedJournalIsQuarantined() async throws {
        let temporary = try TemporaryVault(emptyNamed: "journal-quarantine")
        let directory = temporary.rootURL.appendingPathComponent(".recovery", isDirectory: true)
        let journal = try RecoveryJournal(directory: directory)
        let path = try RelativePath("Note.md")
        let record = RecoveryRecord(
            vaultID: temporary.vault.vaultID,
            path: path,
            attemptedContent: "recover me",
            expectedFingerprint: nil
        )
        try await journal.store(record)
        try Data("{not-json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        #expect(try await journal.pending() == [record])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.contains("broken.corrupt-") })
        #expect(!names.contains("broken.json"))
    }

    @Test("move and delete remain recoverable and never overwrite a changed destination")
    func recoverableFileOperations() async throws {
        let temporary = try TemporaryVault(emptyNamed: "file-operations")
        try temporary.directWrite("source ✅", to: "Note.md")
        let path = try RelativePath("Note.md")
        let destination = try RelativePath("Archive/Note.md")
        let journal = try RecoveryJournal(
            directory: temporary.rootURL.appendingPathComponent(".recovery", isDirectory: true)
        )
        let coordinator = SaveCoordinator(vault: temporary.vault, journal: journal)

        let moved = try await coordinator.move(path, to: destination)
        #expect(try await !temporary.vault.exists(path))
        #expect(try await temporary.vault.read(destination).content == "source ✅")
        #expect(try await coordinator.pendingFileOperations() == [moved.recovery])
        let restoredMove = try await coordinator.restore(moved.recovery)
        #expect(restoredMove.path == path)
        #expect(try await !temporary.vault.exists(destination))

        let deleted = try await coordinator.delete(path)
        #expect(try await !temporary.vault.exists(path))
        let restoredDelete = try await coordinator.restore(deleted.recovery)
        #expect(restoredDelete.content == "source ✅")

        let movedAgain = try await coordinator.move(path, to: destination)
        try temporary.directWrite("external destination", to: destination.rawValue)
        await #expect(throws: TGSidianError.self) {
            _ = try await coordinator.restore(movedAgain.recovery)
        }
        #expect(try await temporary.vault.read(destination).content == "external destination")
        #expect(try await !temporary.vault.exists(path))

        try temporary.directWrite("dismiss me", to: path.rawValue)
        let dismissedDelete = try await coordinator.delete(path)
        let stagedPath = try #require(dismissedDelete.recovery.stagedPath)
        #expect(try await temporary.vault.exists(stagedPath))
        #expect(try await !temporary.vault.listMarkdownFiles().contains(stagedPath))
        try await coordinator.discardFileOperation(dismissedDelete.recovery)
        #expect(try await !temporary.vault.exists(stagedPath))
        #expect(try await !temporary.vault.exists(path))
    }

    @Test("session rename and delete update the index and register native Undo")
    func sessionFileOperationsAndIndex() async throws {
        let temporary = try TemporaryVault(emptyNamed: "session-operations")
        try temporary.directWrite("# Note\n", to: "Note.md")
        let index = IndexActor()
        _ = try await index.rebuild(from: temporary.vault)
        let session = try makeSession(temporary, index: index)
        let path = try RelativePath("Note.md")
        await session.openNote(at: path)
        let undoManager = UndoManager()

        await session.renameNote(at: path, to: "Renamed", undoManager: undoManager)
        let renamed = try RelativePath("Renamed.md")
        #expect(try await temporary.vault.exists(renamed))
        #expect(await index.note(id: NoteID(path: path)) == nil)
        #expect(await index.note(id: NoteID(path: renamed)) != nil)
        #expect(undoManager.canUndo)

        undoManager.undo()
        for _ in 0..<100 {
            if try await temporary.vault.exists(path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await temporary.vault.exists(path))
        #expect(await index.note(id: NoteID(path: path)) != nil)

        await session.deleteNote(at: path, undoManager: undoManager)
        #expect(try await !temporary.vault.exists(path))
        #expect(await index.note(id: NoteID(path: path)) == nil)
        let deleteRecovery = try #require(session.recoverableFileOperations.last)
        await session.undoFileOperation(deleteRecovery)
        #expect(try await temporary.vault.exists(path))
        #expect(await index.note(id: NoteID(path: path)) != nil)
    }

    @Test("front matter and unresolved or ambiguous wiki links surface as non-blocking diagnostics")
    func noteDiagnostics() async throws {
        let temporary = try TemporaryVault(emptyNamed: "diagnostics")
        try temporary.directWrite("---\ninvalid yaml\n---\n# Home\n[[Missing]]\n[[Target]]\n", to: "Home.md")
        try temporary.directWrite("# Target\n", to: "A/Target.md")
        try temporary.directWrite("# Target\n", to: "B/Target.md")
        let index = IndexActor()
        _ = try await index.rebuild(from: temporary.vault)
        let session = try makeSession(temporary, index: index)

        await session.openNote(at: try RelativePath("Home.md"))
        #expect(session.documentDiagnostics.contains { $0.message.contains("Expected a top-level key") })
        #expect(session.documentDiagnostics.contains { $0.message.contains("Unresolved wiki link [[Missing]]") })
        #expect(session.documentDiagnostics.contains { $0.message.contains("Ambiguous wiki link [[Target]]") })
        #expect(session.document.state == .clean)
    }

    @Test("incremental index reports paths used by open-document monitoring")
    func indexEventPaths() async throws {
        let temporary = try TemporaryVault(emptyNamed: "event-paths")
        try temporary.directWrite("old", to: "Note.md")
        let path = try RelativePath("Note.md")
        let index = IndexActor()
        _ = try await index.rebuild(from: temporary.vault)
        try temporary.directWrite("new", to: path.rawValue)

        let modified = try await index.process(
            events: [VaultFileEvent(kind: .modified, path: path, eventID: 10)],
            from: temporary.vault
        )
        #expect(modified.changedPaths == [path])
        #expect(modified.removedPaths.isEmpty)

        try FileManager.default.removeItem(at: temporary.rootURL.appendingPathComponent(path.rawValue))
        let removed = try await index.process(
            events: [VaultFileEvent(kind: .removed, path: path, eventID: 11)],
            from: temporary.vault
        )
        #expect(removed.removedPaths == [path])
    }

    @Test("native completion, task toggling, list continuation, and code fences keep TextKit Undo")
    func nativeMarkdownCommands() async throws {
        _ = NSApplication.shared
        let surface = NativeEditorSurfaceAdapter()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = surface.install(in: scrollView)
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        #expect(window.makeFirstResponder(textView))
        surface.replaceBuffer("See [[Not", preservingSelectionWhenPossible: false)
        surface.selection = 9..<9
        let range = try #require(textView.unfinishedWikiLinkRange)
        #expect((textView.string as NSString).substring(with: range) == "Not")
        textView.insertCompletion("Notes/Editor", forPartialWordRange: range, movement: 0, isFinal: true)
        #expect(textView.string == "See [[Notes/Editor]]")
        #expect(textView.undoManager?.canUndo == true)

        surface.replaceBuffer("- [ ] ship safely", preservingSelectionWhenPossible: false)
        surface.selection = 5..<5
        textView.toggleMarkdownTask(nil)
        #expect(textView.string == "- [x] ship safely")
        #expect(EditorHostView.Coordinator.listContinuation(for: "- [x] ship safely\n") == "- [ ] ")
        #expect(EditorHostView.Coordinator.listContinuation(for: "1. first\n") == "2. ")
        #expect(EditorHostView.Coordinator.codeFenceCompletion(for: "```swift", followingText: "") == "```")
        #expect(EditorHostView.Coordinator.codeFenceCompletion(for: "```swift", followingText: "\n```") == nil)

        let temporary = try TemporaryVault(emptyNamed: "native-commands")
        let (document, _) = try makeDocument(temporary)
        let coordinator = EditorHostView.Coordinator(
            document: document,
            surface: surface,
            wikiLinkCompletions: { _ in [] },
            onFollowWikiLink: { _ in }
        )
        surface.replaceBuffer("```swift", preservingSelectionWhenPossible: false)
        surface.selection = 8..<8
        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(textView.string == "```swift\n\n```")
        #expect(textView.selectedRange().location == 9)
        textView.undoManager?.undo()
        #expect(textView.string == "```swift")

        surface.replaceBuffer("- [ ] ", preservingSelectionWhenPossible: false)
        surface.selection = 6..<6
        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(textView.string.isEmpty)
    }

    @Test("UTF-16 caret offsets report correct Unicode line and column")
    func unicodeEditorStatistics() {
        let text = "😀a\nかな"
        let caret = ("😀a\nか" as NSString).length
        let statistics = EditorStatistics.compute(text: text, caret: caret)
        #expect(statistics.line == 2)
        #expect(statistics.column == 2)
        #expect(statistics.characters == 5)
    }

    @Test("one-megabyte note reads within the note-open budget")
    func noteOpenPerformance() async throws {
        let temporary = try TemporaryVault(emptyNamed: "note-open-performance")
        let line = "Plain UTF-8 Markdown with [[Link]].\n"
        let target = 1_048_576
        let repeated = String(repeating: line, count: target / line.utf8.count + 1)
        let data = Data(repeated.utf8.prefix(target))
        try data.write(to: temporary.rootURL.appendingPathComponent("Large.md"))
        let path = try RelativePath("Large.md")
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<10 {
            let start = clock.now
            let snapshot = try await temporary.vault.read(path)
            samples.append(Self.milliseconds(start.duration(to: clock.now)))
            #expect(snapshot.content.utf8.count == target)
        }
        samples.sort()
        let p95 = samples[8]
        #expect(p95 < 100, "1 MiB note-open p95 took \(p95) ms")
        print("PENTA-139 metric: 1MiB note-open p95 = \(String(format: "%.2f", p95)) ms")
    }

    private func makeDocument(_ temporary: TemporaryVault) throws -> (EditorDocumentModel, SaveCoordinator) {
        let journal = try RecoveryJournal(
            directory: temporary.rootURL.appendingPathComponent(".recovery", isDirectory: true)
        )
        let coordinator = SaveCoordinator(vault: temporary.vault, journal: journal)
        return (
            EditorDocumentModel(vault: temporary.vault, saveCoordinator: coordinator),
            coordinator
        )
    }

    private func makeSession(_ temporary: TemporaryVault, index: IndexActor) throws -> VaultSessionModel {
        let journal = try RecoveryJournal(
            directory: temporary.rootURL.appendingPathComponent(".recovery", isDirectory: true)
        )
        let coordinator = SaveCoordinator(vault: temporary.vault, journal: journal)
        return VaultSessionModel(
            vaultID: temporary.vault.vaultID,
            displayName: "Test",
            vault: temporary.vault,
            index: index,
            graphEngine: LocalGraphEngine(index: index),
            dailyNotes: DailyNoteService(vault: temporary.vault),
            saveCoordinator: coordinator,
            workspaceState: VaultWorkspaceState(),
            workspaceStateStore: InMemoryVaultWorkspaceStateStore()
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

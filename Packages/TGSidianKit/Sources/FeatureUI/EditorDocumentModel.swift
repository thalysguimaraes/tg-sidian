import AppCore
import Foundation
import Observation
import VaultKit

/// The save state machine from SPEC §9.3 and §19.
///
/// `conflicted` is a first-class state rather than a transient error because the spec requires
/// autosave to *stop* and wait for an explicit user choice. Every state carries text, never
/// colour alone (SPEC §5.5).
public enum DocumentSaveState: Hashable, Sendable {
    case clean
    case dirty
    case saving
    case conflicted(SaveConflict)
    case writeFailed(message: String)

    /// SPEC §5.5: status must be textual/accessibility-visible.
    public var statusText: String {
        switch self {
        case .clean: "Saved"
        case .dirty: "Unsaved changes"
        case .saving: "Saving…"
        case .conflicted: "Conflict — changed on disk"
        case let .writeFailed(message): "Save failed: \(message)"
        }
    }

    /// SPEC §5.5 / §17: a glyph pairs with the text so the state never relies on colour.
    public var glyph: String {
        switch self {
        case .clean: "✓"
        case .dirty: "✎"
        case .saving: "…"
        case .conflicted: "⚠"
        case .writeFailed: "⚠"
        }
    }

    /// SPEC §9.3: autosave is blocked while a conflict or hard write failure is unresolved.
    public var allowsAutosave: Bool {
        switch self {
        case .clean, .dirty, .saving: true
        case .conflicted, .writeFailed: false
        }
    }

    public var isConflicted: Bool {
        if case .conflicted = self { return true }
        return false
    }
}

/// The three source versions shown by the conflict sheet. A divergent edit produces explicit
/// conflict markers instead of pretending an unsafe automatic merge succeeded.
public struct ConflictComparison: Hashable, Sendable {
    public let base: String
    public let mine: String
    public let theirs: String
    public let mergedDraft: String
    public let summary: String
    public let hasOverlappingChanges: Bool

    public init(base: String, mine: String, theirs: String) {
        self.base = base
        self.mine = mine
        self.theirs = theirs
        let mineChanges = Array(mine.split(separator: "\n", omittingEmptySubsequences: false))
            .difference(from: Array(base.split(separator: "\n", omittingEmptySubsequences: false))).count
        let theirChanges = Array(theirs.split(separator: "\n", omittingEmptySubsequences: false))
            .difference(from: Array(base.split(separator: "\n", omittingEmptySubsequences: false))).count
        self.summary = "Your version has \(mineChanges) line changes; disk has \(theirChanges)."

        if mine == theirs {
            self.mergedDraft = mine
            self.hasOverlappingChanges = false
        } else if mine == base {
            self.mergedDraft = theirs
            self.hasOverlappingChanges = false
        } else if theirs == base {
            self.mergedDraft = mine
            self.hasOverlappingChanges = false
        } else {
            self.mergedDraft = """
            <<<<<<< Your edits
            \(mine)
            =======
            \(theirs)
            >>>>>>> On disk
            """
            self.hasOverlappingChanges = true
        }
    }
}

/// Editor statistics for the status bar (SPEC §9.1: line/column and word/character counts).
public struct EditorStatistics: Hashable, Sendable {
    public let line: Int
    public let column: Int
    public let words: Int
    public let characters: Int

    public init(line: Int, column: Int, words: Int, characters: Int) {
        self.line = line
        self.column = column
        self.words = words
        self.characters = characters
    }

    public static func compute(text: String, caret: Int) -> EditorStatistics {
        // NSTextView reports UTF-16 offsets. Convert through NSString before counting grapheme
        // clusters so emoji and composed scripts cannot put line/column calculation mid-scalar.
        let ns = text as NSString
        let clamped = min(max(0, caret), ns.length)
        let prefix = ns.substring(to: clamped)
        let newlines = prefix.filter { $0 == "\n" }.count
        let lastLineStart = prefix.lastIndex(of: "\n").map { prefix.index(after: $0) } ?? prefix.startIndex
        let column = prefix.distance(from: lastLineStart, to: prefix.endIndex) + 1
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return EditorStatistics(
            line: newlines + 1,
            column: column,
            words: words,
            characters: text.count
        )
    }

    /// The SPEC §9.1 status line. Kept here (not in a view) so it is testable.
    public var statusText: String {
        "Ln \(line), Col \(column) · \(words) words · \(characters) characters"
    }
}

/// Owns document state, persistence, and the conflict state machine for one open note.
///
/// tg-sidian owns this state, not the text surface (SPEC §9.1) — the `EditorSurface` adapter
/// only renders and reports edits, so the surface can be swapped without touching this model.
@Observable
@MainActor
public final class EditorDocumentModel {
    public private(set) var path: RelativePath?
    public private(set) var text: String = ""
    public private(set) var savedFingerprint: FileFingerprint?
    public private(set) var state: DocumentSaveState = .clean
    public private(set) var revision: Int = 0
    public private(set) var pendingRecoveryRecords: [RecoveryRecord] = []
    public var caretOffset: Int = 0

    /// SPEC §9.3: "autosave after a short idle interval".
    public var autosaveIdleInterval: Duration = .milliseconds(800)

    private let saveCoordinator: SaveCoordinator
    private let vault: VaultActor
    private var autosaveTask: Task<Void, Never>?
    private var saveInProgress = false
    private var lastSavedText = ""
    private var inFlightContent: String?
    private var conflictDiskSnapshot: VaultFileSnapshot?
    private var conflictRecoveryRecordID: UUID?
    /// Set by the owning session so a completed save can refresh the index and backlinks.
    /// Assigned after init because the session and the document are constructed together.
    public var onSaved: (@MainActor (VaultFileSnapshot) -> Void)?

    public init(
        vault: VaultActor,
        saveCoordinator: SaveCoordinator,
        onSaved: (@MainActor (VaultFileSnapshot) -> Void)? = nil
    ) {
        self.vault = vault
        self.saveCoordinator = saveCoordinator
        self.onSaved = onSaved
    }

    public var statistics: EditorStatistics {
        EditorStatistics.compute(text: text, caret: caretOffset)
    }

    /// Replacing the buffer is safe only after every local change has either reached canonical
    /// Markdown or the user explicitly resolved/discarded it.
    public var canReplaceBuffer: Bool {
        if path == nil { return true }
        if case .clean = state { return true }
        return false
    }

    public func open(_ snapshot: VaultFileSnapshot) {
        autosaveTask?.cancel()
        path = snapshot.path
        text = snapshot.content
        savedFingerprint = snapshot.fingerprint
        lastSavedText = snapshot.content
        conflictDiskSnapshot = nil
        inFlightContent = nil
        conflictRecoveryRecordID = nil
        state = .clean
        revision &+= 1
        caretOffset = 0
    }

    public func close() {
        autosaveTask?.cancel()
        autosaveTask = nil
        path = nil
        text = ""
        savedFingerprint = nil
        lastSavedText = ""
        conflictDiskSnapshot = nil
        inFlightContent = nil
        conflictRecoveryRecordID = nil
        state = .clean
    }

    /// Called by the text surface on every edit.
    public func bufferDidChange(to newText: String) {
        guard newText != text else { return }
        text = newText
        revision &+= 1
        if case let .conflicted(conflict) = state {
            state = .conflicted(SaveConflict(
                path: conflict.path,
                expected: conflict.expected,
                actual: conflict.actual,
                attemptedContent: newText
            ))
        } else if state.allowsAutosave {
            state = .dirty
            scheduleAutosave()
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let interval = autosaveIdleInterval
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// SPEC §9.3: autosave on focus/window transitions, in addition to the idle timer.
    public func flushPendingSave() async {
        autosaveTask?.cancel()
        // A navigation/focus flush must not open another note while an earlier save can still
        // publish its fingerprint back into this document model.
        while saveInProgress {
            try? await Task.sleep(for: .milliseconds(5))
        }
        switch state {
        case .dirty:
            await save()
        case .conflicted, .writeFailed:
            // Navigation remains blocked, but a durable checkpoint guarantees that even a later
            // crash cannot make this unsaved buffer exist only in memory.
            await checkpointUnsavedBuffer()
        case .clean, .saving:
            return
        }
    }

    @discardableResult
    public func save() async -> Bool {
        guard let path, state.allowsAutosave else { return false }
        guard state != .clean else { return true }
        // Focus loss and the idle timer can fire together. Only one optimistic write may own the
        // saved fingerprint at a time; edits arriving during it are queued by the dirty state.
        guard !saveInProgress else { return false }
        saveInProgress = true
        defer { saveInProgress = false }

        state = .saving
        let attempted = text
        inFlightContent = attempted
        do {
            let snapshot = try await saveCoordinator.save(
                attempted,
                to: path,
                expectedFingerprint: savedFingerprint
            )
            savedFingerprint = snapshot.fingerprint
            lastSavedText = snapshot.content
            conflictDiskSnapshot = nil
            inFlightContent = nil
            pendingRecoveryRecords.removeAll {
                $0.path == snapshot.path && $0.attemptedContent == snapshot.content
            }
            // A keystroke may have landed while the write was in flight.
            state = attempted == text ? .clean : .dirty
            if case .dirty = state { scheduleAutosave() }
            onSaved?(snapshot)
            await clearConflictRecoveryCheckpoint()
            return true
        } catch let TGSidianError.conflict(conflict) {
            inFlightContent = nil
            conflictDiskSnapshot = try? await vault.read(conflict.path)
            // SPEC §9.3: never silently overwrite a newer external revision.
            state = .conflicted(SaveConflict(
                path: conflict.path,
                expected: conflict.expected,
                actual: conflict.actual,
                attemptedContent: text
            ))
            pendingRecoveryRecords = (try? await saveCoordinator.pendingRecovery())
                ?? pendingRecoveryRecords
            conflictRecoveryRecordID = pendingRecoveryRecords.last(where: {
                $0.path == conflict.path && $0.attemptedContent == text
            })?.id
            return false
        } catch {
            inFlightContent = nil
            // SPEC §19: disk full / write failure keeps the journal and shows a persistent error.
            pendingRecoveryRecords = (try? await saveCoordinator.pendingRecovery())
                ?? pendingRecoveryRecords
            state = .writeFailed(message: error.localizedDescription)
            return false
        }
    }

    /// SPEC §9.3 + §19: an external edit landing on a dirty buffer stops autosave and requires
    /// an explicit resolution. Called by the file watcher / reconciliation.
    public func externalChangeDetected(_ snapshot: VaultFileSnapshot) async {
        guard let path, snapshot.path == path else { return }
        guard snapshot.fingerprint != savedFingerprint else { return }

        // An FSEvents callback can race the completion of our own atomic replacement. Matching
        // bytes are the in-flight save, not an external conflict.
        if snapshot.content == inFlightContent {
            savedFingerprint = snapshot.fingerprint
            return
        }
        if snapshot.content == text {
            savedFingerprint = snapshot.fingerprint
            lastSavedText = snapshot.content
            conflictDiskSnapshot = nil
            state = .clean
            return
        }
        if case .clean = state {
            // Nothing local to lose: adopt the external revision.
            text = snapshot.content
            savedFingerprint = snapshot.fingerprint
            lastSavedText = snapshot.content
            conflictDiskSnapshot = nil
            revision &+= 1
            return
        }

        autosaveTask?.cancel()
        conflictDiskSnapshot = snapshot
        state = .conflicted(SaveConflict(
            path: path,
            expected: savedFingerprint,
            actual: snapshot.fingerprint,
            attemptedContent: text
        ))
        await checkpointUnsavedBuffer()
    }

    /// A removed open file is treated like any other external revision: local bytes stay in the
    /// buffer, autosave pauses, and Keep Mine can safely recreate the note.
    public func externalDeletionDetected(at removedPath: RelativePath) async {
        guard path == removedPath else { return }
        autosaveTask?.cancel()
        conflictDiskSnapshot = nil
        state = .conflicted(SaveConflict(
            path: removedPath,
            expected: savedFingerprint,
            actual: nil,
            attemptedContent: text
        ))
        await checkpointUnsavedBuffer()
    }

    /// SPEC §9.3: Compare / Keep Mine / Reload.
    public func resolveConflict(_ resolution: ConflictResolution) async {
        guard case .conflicted = state else { return }
        switch resolution {
        case .compare:
            // Presentation-only; the sheet shows the diff and leaves the state conflicted.
            return
        case .keepMine:
            guard let path else { return }
            state = .saving
            do {
                let current = try? await vault.read(path)
                let snapshot = try await saveCoordinator.save(
                    text,
                    to: path,
                    expectedFingerprint: current?.fingerprint
                )
                text = snapshot.content
                savedFingerprint = snapshot.fingerprint
                lastSavedText = snapshot.content
                conflictDiskSnapshot = nil
                state = .clean
                await clearConflictRecoveryCheckpoint()
                onSaved?(snapshot)
            } catch {
                state = .writeFailed(message: error.localizedDescription)
            }
        case .reload:
            guard let path else { return }
            do {
                let snapshot = try await vault.read(path)
                text = snapshot.content
                savedFingerprint = snapshot.fingerprint
                lastSavedText = snapshot.content
                conflictDiskSnapshot = nil
                revision &+= 1
                state = .clean
                await clearConflictRecoveryCheckpoint()
            } catch {
                state = .writeFailed(message: error.localizedDescription)
            }
        }
    }

    /// The two sides of an unresolved conflict, so the sheet can show what Reload would discard
    /// and what Keep Mine would overwrite (SPEC §22: conflicts cannot silently lose data).
    ///
    /// `theirs` is read from disk rather than taken from the buffer: the buffer holds the local
    /// edit, so both sides would otherwise be the same text.
    public func conflictComparison() async -> ConflictComparison? {
        guard case let .conflicted(conflict) = state else { return nil }
        let disk: VaultFileSnapshot?
        if let conflictDiskSnapshot {
            disk = conflictDiskSnapshot
        } else {
            disk = try? await vault.read(conflict.path)
        }
        return ConflictComparison(
            base: lastSavedText,
            mine: text,
            theirs: disk?.content ?? ""
        )
    }

    /// Replaces the local side with the editable merge draft, then saves against the disk revision
    /// that was just compared. Conflict markers remain plain Markdown until the user resolves them.
    public func useMergedDraft(_ mergedText: String) async {
        guard case let .conflicted(conflict) = state else { return }
        let disk: VaultFileSnapshot?
        if let conflictDiskSnapshot {
            disk = conflictDiskSnapshot
        } else {
            disk = try? await vault.read(conflict.path)
        }
        text = mergedText
        savedFingerprint = disk?.fingerprint
        lastSavedText = disk?.content ?? ""
        conflictDiskSnapshot = nil
        revision &+= 1
        state = .dirty
        if await save() {
            await clearConflictRecoveryCheckpoint()
        }
    }

    public func retryFailedSave() async {
        guard case .writeFailed = state else { return }
        state = .dirty
        await save()
    }

    public func loadPendingRecovery() async {
        pendingRecoveryRecords = (try? await saveCoordinator.pendingRecovery()) ?? []
    }

    private func checkpointUnsavedBuffer() async {
        guard let path else { return }
        do {
            let record = try await saveCoordinator.checkpointRecovery(
                text,
                path: path,
                expectedFingerprint: savedFingerprint
            )
            pendingRecoveryRecords.removeAll { $0.path == path }
            pendingRecoveryRecords.append(record)
            conflictRecoveryRecordID = record.id
        } catch {
            state = .writeFailed(message: "Could not create recovery checkpoint: \(error.localizedDescription)")
        }
    }

    private func clearConflictRecoveryCheckpoint() async {
        guard let conflictRecoveryRecordID else { return }
        try? await saveCoordinator.discardRecovery(id: conflictRecoveryRecordID)
        pendingRecoveryRecords.removeAll { $0.id == conflictRecoveryRecordID }
        self.conflictRecoveryRecordID = nil
    }

    public func recoveryComparison(for record: RecoveryRecord) async -> ConflictComparison {
        let disk = (try? await vault.read(record.path))?.content ?? ""
        return ConflictComparison(base: disk, mine: record.attemptedContent, theirs: disk)
    }

    @discardableResult
    public func restoreRecovery(_ record: RecoveryRecord) async -> Bool {
        do {
            let snapshot = try await saveCoordinator.restore(record)
            pendingRecoveryRecords.removeAll { $0.id == record.id }
            if path == nil || path == record.path { open(snapshot) }
            onSaved?(snapshot)
            return true
        } catch {
            state = .writeFailed(message: "Recovery failed: \(error.localizedDescription)")
            return false
        }
    }

    public func discardRecovery(_ record: RecoveryRecord) async {
        do {
            try await saveCoordinator.discardRecovery(id: record.id)
            pendingRecoveryRecords.removeAll { $0.id == record.id }
        } catch {
            state = .writeFailed(message: "Could not dismiss recovery: \(error.localizedDescription)")
        }
    }
}

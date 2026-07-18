import AppCore
import Darwin
import Foundation

/// Durable, app-support recovery state. Markdown in the vault remains canonical; records are
/// removed after a successful save or an explicit restore/dismiss decision.
public actor RecoveryJournal {
    public let directory: URL
    private let operationsDirectory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        self.operationsDirectory = self.directory.appendingPathComponent("FileOperations", isDirectory: true)
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: self.operationsDirectory, withIntermediateDirectories: true)
        for durableDirectory in [self.directory.deletingLastPathComponent(), self.directory] {
            let descriptor = Darwin.open(durableDirectory.path, O_RDONLY)
            if descriptor >= 0 {
                _ = Darwin.fsync(descriptor)
                Darwin.close(descriptor)
            }
        }
    }

    @discardableResult
    public func store(_ record: RecoveryRecord) throws -> URL {
        let url = directory.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        try writeDurably(encoder.encode(record), to: url)
        return url
    }

    public func remove(id: UUID) throws {
        try removeIfPresent(directory.appendingPathComponent(id.uuidString).appendingPathExtension("json"))
    }

    public func pending() throws -> [RecoveryRecord] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var records: [RecoveryRecord] = []
        for url in urls where url.pathExtension == "json" {
            do {
                records.append(try decoder.decode(RecoveryRecord.self, from: Data(contentsOf: url)))
            } catch {
                quarantineMalformed(url)
            }
        }
        return records.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func storeFileOperation(_ record: FileOperationRecoveryRecord) throws -> URL {
        let url = operationsDirectory.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        try writeDurably(encoder.encode(record), to: url)
        return url
    }

    public func removeFileOperation(id: UUID) throws {
        try removeIfPresent(
            operationsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        )
    }

    public func pendingFileOperations() throws -> [FileOperationRecoveryRecord] {
        let urls = try fileManager.contentsOfDirectory(
            at: operationsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var records: [FileOperationRecoveryRecord] = []
        for url in urls where url.pathExtension == "json" {
            do {
                records.append(try decoder.decode(FileOperationRecoveryRecord.self, from: Data(contentsOf: url)))
            } catch {
                quarantineMalformed(url)
            }
        }
        return records.sorted { $0.createdAt < $1.createdAt }
    }

    /// JSON is written through a sibling temporary, fsynced, renamed, then followed by a parent
    /// directory fsync. A crash therefore leaves either the previous complete record or the new
    /// complete record, never a truncated recovery payload.
    private func writeDurably(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary { try? fileManager.removeItem(at: temporary) }
        }

        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw TGSidianError.invalidOperation("Could not create a recovery journal temporary file")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        shouldRemoveTemporary = false
        synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        synchronizeDirectory(url.deletingLastPathComponent())
    }

    /// Preserve malformed bytes for diagnosis without letting one damaged record hide every other
    /// recoverable edit.
    private func quarantineMalformed(_ url: URL) {
        let quarantine = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString)")
        try? fileManager.moveItem(at: url, to: quarantine)
        synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func synchronizeDirectory(_ directory: URL) {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fsync(descriptor)
    }
}

public struct FileOperationOutcome: Hashable, Sendable {
    public let snapshot: VaultFileSnapshot
    public let recovery: FileOperationRecoveryRecord

    public init(snapshot: VaultFileSnapshot, recovery: FileOperationRecoveryRecord) {
        self.snapshot = snapshot
        self.recovery = recovery
    }
}

public actor SaveCoordinator {
    private let vault: VaultActor
    private let journal: RecoveryJournal

    public init(vault: VaultActor, journal: RecoveryJournal) {
        self.vault = vault
        self.journal = journal
    }

    @discardableResult
    public func save(
        _ content: String,
        to path: RelativePath,
        expectedFingerprint: FileFingerprint?
    ) async throws -> VaultFileSnapshot {
        let record = RecoveryRecord(
            vaultID: vault.vaultID,
            path: path,
            attemptedContent: content,
            expectedFingerprint: expectedFingerprint
        )
        try await journal.store(record)
        let snapshot = try await vault.atomicWrite(
            content,
            to: path,
            expectedFingerprint: expectedFingerprint
        )
        try await journal.remove(id: record.id)
        return snapshot
    }

    /// Durably checkpoints an unsaved buffer without writing canonical Markdown. The new record is
    /// stored before older checkpoints for the same note are removed, so there is no crash gap.
    @discardableResult
    public func checkpointRecovery(
        _ content: String,
        path: RelativePath,
        expectedFingerprint: FileFingerprint?
    ) async throws -> RecoveryRecord {
        let existing = try await journal.pending().filter {
            $0.vaultID == vault.vaultID && $0.path == path
        }
        if let identical = existing.last(where: { $0.attemptedContent == content }) {
            return identical
        }

        let record = RecoveryRecord(
            vaultID: vault.vaultID,
            path: path,
            attemptedContent: content,
            expectedFingerprint: expectedFingerprint
        )
        try await journal.store(record)
        for superseded in existing {
            try? await journal.remove(id: superseded.id)
        }
        return record
    }

    /// Removes journal entries whose write completed before a crash could clear the record.
    public func pendingRecovery() async throws -> [RecoveryRecord] {
        var result: [RecoveryRecord] = []
        for record in try await journal.pending() where record.vaultID == vault.vaultID {
            if let snapshot = try? await vault.read(record.path),
               snapshot.content == record.attemptedContent {
                try? await journal.remove(id: record.id)
            } else {
                result.append(record)
            }
        }
        return result
    }

    /// Explicit recovery always fingerprints the current disk revision first. It never silently
    /// reuses the stale pre-crash fingerprint.
    @discardableResult
    public func restore(_ record: RecoveryRecord) async throws -> VaultFileSnapshot {
        guard record.vaultID == vault.vaultID else {
            throw TGSidianError.invalidOperation("Recovery record belongs to a different vault")
        }
        let current = try? await vault.read(record.path)
        if let current, current.content == record.attemptedContent {
            try await journal.remove(id: record.id)
            return current
        }
        let snapshot = try await vault.atomicWrite(
            record.attemptedContent,
            to: record.path,
            expectedFingerprint: current?.fingerprint
        )
        try await journal.remove(id: record.id)
        return snapshot
    }

    public func discardRecovery(id: UUID) async throws {
        try await journal.remove(id: id)
    }

    @discardableResult
    public func move(_ source: RelativePath, to destination: RelativePath) async throws -> FileOperationOutcome {
        let sourceSnapshot = try await vault.read(source)
        let record = FileOperationRecoveryRecord(
            vaultID: vault.vaultID,
            operation: .move,
            sourcePath: source,
            destinationPath: destination,
            content: sourceSnapshot.content,
            sourceFingerprint: sourceSnapshot.fingerprint
        )
        try await journal.storeFileOperation(record)
        do {
            let moved = try await vault.moveSafely(
                source,
                to: destination,
                expectedFingerprint: sourceSnapshot.fingerprint
            )
            return FileOperationOutcome(snapshot: moved, recovery: record)
        } catch {
            let sourceStillExists = (try? await vault.exists(source)) == true
            let destinationExists = (try? await vault.exists(destination)) == true
            if sourceStillExists || !destinationExists {
                try? await journal.removeFileOperation(id: record.id)
            }
            throw error
        }
    }

    @discardableResult
    public func delete(_ path: RelativePath) async throws -> FileOperationOutcome {
        let sourceSnapshot = try await vault.read(path)
        let id = UUID()
        let stagedName = ".\(path.lastComponent).tg-sidian-delete-\(id.uuidString).tmp"
        let stagedPath = try path.deletingLastComponent.map { try $0.appending(stagedName) }
            ?? RelativePath(stagedName)
        let record = FileOperationRecoveryRecord(
            id: id,
            vaultID: vault.vaultID,
            operation: .delete,
            sourcePath: path,
            stagedPath: stagedPath,
            content: sourceSnapshot.content,
            sourceFingerprint: sourceSnapshot.fingerprint
        )
        try await journal.storeFileOperation(record)
        do {
            _ = try await vault.moveSafely(
                path,
                to: stagedPath,
                expectedFingerprint: sourceSnapshot.fingerprint
            )
            return FileOperationOutcome(snapshot: sourceSnapshot, recovery: record)
        } catch {
            let sourceStillExists = (try? await vault.exists(path)) == true
            let stagedExists = (try? await vault.exists(stagedPath)) == true
            if sourceStillExists || !stagedExists {
                try? await journal.removeFileOperation(id: record.id)
            }
            throw error
        }
    }

    public func pendingFileOperations() async throws -> [FileOperationRecoveryRecord] {
        var pending: [FileOperationRecoveryRecord] = []
        for record in try await journal.pendingFileOperations() where record.vaultID == vault.vaultID {
            let source = try? await vault.read(record.sourcePath)
            switch record.operation {
            case .delete:
                let staged: VaultFileSnapshot?
                if let stagedPath = record.stagedPath {
                    staged = try? await vault.read(stagedPath)
                } else {
                    staged = nil
                }
                if source?.content == record.content, staged == nil {
                    try? await journal.removeFileOperation(id: record.id)
                } else {
                    pending.append(record)
                }
            case .move:
                let destination: VaultFileSnapshot?
                if let destinationPath = record.destinationPath {
                    destination = try? await vault.read(destinationPath)
                } else {
                    destination = nil
                }
                if source?.content == record.content, destination == nil {
                    try? await journal.removeFileOperation(id: record.id)
                } else {
                    pending.append(record)
                }
            }
        }
        return pending
    }

    /// Restores a deleted note or reverses a move. Conflicting files are never overwritten.
    @discardableResult
    public func restore(_ record: FileOperationRecoveryRecord) async throws -> VaultFileSnapshot {
        guard record.vaultID == vault.vaultID else {
            throw TGSidianError.invalidOperation("Recovery record belongs to a different vault")
        }
        if let source = try? await vault.read(record.sourcePath) {
            guard source.content == record.content else {
                throw TGSidianError.destinationExists(record.sourcePath)
            }
            let counterpartExists: Bool = switch record.operation {
            case .delete:
                if let stagedPath = record.stagedPath {
                    (try? await vault.exists(stagedPath)) == true
                } else {
                    false
                }
            case .move:
                if let destination = record.destinationPath {
                    (try? await vault.exists(destination)) == true
                } else {
                    false
                }
            }
            guard !counterpartExists else {
                throw TGSidianError.invalidOperation(
                    "Undo stopped because both source and destination versions exist"
                )
            }
            try await journal.removeFileOperation(id: record.id)
            return source
        }

        let restored: VaultFileSnapshot
        switch record.operation {
        case .delete:
            if let stagedPath = record.stagedPath,
               let staged = try? await vault.read(stagedPath) {
                restored = try await vault.moveSafely(
                    stagedPath,
                    to: record.sourcePath,
                    expectedFingerprint: staged.fingerprint
                )
            } else {
                // Backward-compatible recovery for records created before staged deletion.
                restored = try await vault.atomicWrite(
                    record.content,
                    to: record.sourcePath,
                    expectedFingerprint: nil
                )
            }
        case .move:
            guard let destination = record.destinationPath else {
                throw TGSidianError.invalidOperation("Move recovery is missing its destination")
            }
            if let moved = try? await vault.read(destination) {
                guard moved.content == record.content else {
                    throw TGSidianError.conflict(SaveConflict(
                        path: destination,
                        expected: record.sourceFingerprint,
                        actual: moved.fingerprint,
                        attemptedContent: record.content
                    ))
                }
                restored = try await vault.moveSafely(
                    destination,
                    to: record.sourcePath,
                    expectedFingerprint: moved.fingerprint
                )
            } else {
                restored = try await vault.atomicWrite(
                    record.content,
                    to: record.sourcePath,
                    expectedFingerprint: nil
                )
            }
        }
        try await journal.removeFileOperation(id: record.id)
        return restored
    }

    public func discardFileOperation(_ record: FileOperationRecoveryRecord) async throws {
        if let stagedPath = record.stagedPath,
           let staged = try? await vault.read(stagedPath) {
            _ = try await vault.removeSafely(
                stagedPath,
                expectedFingerprint: staged.fingerprint
            )
        }
        try await journal.removeFileOperation(id: record.id)
    }
}

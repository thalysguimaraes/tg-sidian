import AppCore
import CryptoKit
import Darwin
import Foundation

public struct AtomicWriteHooks: Sendable {
    public var afterTemporaryFileWritten: (@Sendable (URL) throws -> Void)?
    public var beforeAtomicSwap: (@Sendable (URL, URL) throws -> Void)?

    public init(
        afterTemporaryFileWritten: (@Sendable (URL) throws -> Void)? = nil,
        beforeAtomicSwap: (@Sendable (URL, URL) throws -> Void)? = nil
    ) {
        self.afterTemporaryFileWritten = afterTemporaryFileWritten
        self.beforeAtomicSwap = beforeAtomicSwap
    }

    public static let none = AtomicWriteHooks()
}

public actor VaultActor: VaultServicing {
    public nonisolated let vaultID: VaultID
    public nonisolated let rootURL: URL

    private let root: VaultRoot
    private let ignoredDirectoryNames: Set<String>
    private let maximumIndexedFileSize: Int
    private let instrument: any PerformanceInstrumenting
    private let hooks: AtomicWriteHooks
    private let fileManager = FileManager.default
    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

    public init(
        rootURL: URL,
        vaultID: VaultID = VaultID(),
        ignoredDirectoryNames: Set<String> = [
            ".git", "node_modules", ".build", "build", "DerivedData", "Pods", "Carthage"
        ],
        maximumIndexedFileSize: Int = 5 * 1_024 * 1_024,
        instrument: any PerformanceInstrumenting = NoopPerformanceInstrument(),
        hooks: AtomicWriteHooks = .none
    ) throws {
        let validatedRoot = try VaultRoot(url: rootURL)
        self.rootURL = validatedRoot.resolvedURL
        self.vaultID = vaultID
        self.root = validatedRoot
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.maximumIndexedFileSize = maximumIndexedFileSize
        self.instrument = instrument
        self.hooks = hooks
    }

    public func listMarkdownFiles() throws -> [RelativePath] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var paths: [RelativePath] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                continue
            }

            let name = url.lastPathComponent
            if values.isDirectory == true {
                let shouldIgnore = ignoredDirectoryNames.contains(name)
                    || (values.isHidden == true && name != ".tg-sidian")
                if shouldIgnore { enumerator.skipDescendants() }
                continue
            }

            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { continue }
            guard (values.fileSize ?? 0) <= maximumIndexedFileSize else { continue }

            do {
                paths.append(try root.relativePath(for: url))
            } catch {
                continue
            }
        }

        let sortedPaths = paths.sorted()
        var canonicalPaths: [String: RelativePath] = [:]
        for path in sortedPaths {
            let key = NotePathIdentity.key(path.rawValue)
            if let existing = canonicalPaths[key], existing != path {
                throw TGSidianError.invalidOperation(
                    "Case-insensitive vault path collision: \(existing.rawValue) and \(path.rawValue)"
                )
            }
            canonicalPaths[key] = path
        }
        return sortedPaths
    }

    public func exists(_ path: RelativePath) throws -> Bool {
        fileManager.fileExists(atPath: try root.resolve(path).path)
    }

    /// Applies the same extension, ignored-directory, containment, and size policy used by
    /// reconciliation scans to a single FSEvents path.
    public func isIndexable(_ path: RelativePath) throws -> Bool {
        guard ["md", "markdown"].contains(path.pathExtension.lowercased()) else { return false }
        guard !path.components.dropLast().contains(where: { component in
            ignoredDirectoryNames.contains(component) || (component.hasPrefix(".") && component != ".tg-sidian")
        }) else { return false }

        let url = try root.resolve(path)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true || values.isSymbolicLink == true else { return false }
        guard (values.fileSize ?? 0) <= maximumIndexedFileSize else { return false }
        return true
    }

    public func read(_ path: RelativePath) throws -> VaultFileSnapshot {
        instrument.begin(.noteOpen)
        defer { instrument.end(.noteOpen) }

        let url = try root.resolve(path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw TGSidianError.fileNotFound(path)
        }
        guard let data = fileManager.contents(atPath: url.path),
              let content = String(data: data, encoding: .utf8)
        else {
            throw TGSidianError.unreadableFile(path)
        }
        return VaultFileSnapshot(path: path, content: content, fingerprint: try fingerprint(url: url, data: data))
    }

    /// Reads a bounded vault-relative support file for a capability-gated extension. This uses
    /// the same containment checks as note reads while deliberately avoiding a root URL escape.
    public func readData(atVaultRelativePath path: RelativePath) throws -> Data {
        let url = try root.resolve(path)
        guard let data = fileManager.contents(atPath: url.path) else {
            throw TGSidianError.fileNotFound(path)
        }
        guard data.count <= 1_024 * 1_024 else {
            throw TGSidianError.invalidOperation("Extension configuration exceeds 1 MiB")
        }
        return data
    }

    @discardableResult
    public func atomicWrite(
        _ content: String,
        to path: RelativePath,
        expectedFingerprint: FileFingerprint? = nil
    ) throws -> VaultFileSnapshot {
        instrument.begin(.save)
        defer { instrument.end(.save) }

        let destination = try root.resolve(path)
        let directory = destination.deletingLastPathComponent()
        try root.ensureContained(directory)
        if try hasCaseInsensitiveComponentCollision(path) {
            throw TGSidianError.destinationExists(path)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let initial = try currentFingerprint(at: destination)
        let initialCaseInsensitiveCollision = try caseInsensitiveSiblingExists(destination, excluding: nil)
        if let expectedFingerprint {
            guard initial == expectedFingerprint else {
                throw TGSidianError.conflict(SaveConflict(
                    path: path,
                    expected: expectedFingerprint,
                    actual: initial,
                    attemptedContent: content
                ))
            }
        } else if initial != nil || initialCaseInsensitiveCollision {
            throw TGSidianError.destinationExists(path)
        }

        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).tg-sidian-\(UUID().uuidString).tmp")
        let data = Data(content.utf8)
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary { try? fileManager.removeItem(at: temporary) }
        }

        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw TGSidianError.invalidOperation("Could not create temporary file for \(path.rawValue)")
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

        if let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
           let permissions = attributes[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }

        try hooks.afterTemporaryFileWritten?(temporary)

        let beforeReplace = try currentFingerprint(at: destination)
        let beforeReplaceCaseInsensitiveCollision = try caseInsensitiveSiblingExists(destination, excluding: nil)
        if let expectedFingerprint {
            guard beforeReplace == expectedFingerprint else {
                throw TGSidianError.conflict(SaveConflict(
                    path: path,
                    expected: expectedFingerprint,
                    actual: beforeReplace,
                    attemptedContent: content
                ))
            }
        } else if beforeReplace != nil || beforeReplaceCaseInsensitiveCollision {
            throw TGSidianError.destinationExists(path)
        }

        try hooks.beforeAtomicSwap?(temporary, destination)

        if let expectedFingerprint {
            // Swap is the filesystem compare-and-swap primitive. The previous destination moves
            // to `temporary` atomically; validating that inode after the swap closes the race
            // between the final fingerprint check and replacement. A mismatch is swapped back.
            guard Darwin.renamex_np(temporary.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let replacedFingerprint: FileFingerprint?
            do {
                replacedFingerprint = try currentFingerprint(at: temporary)
            } catch {
                let rollbackResult = Darwin.renamex_np(
                    temporary.path,
                    destination.path,
                    UInt32(RENAME_SWAP)
                )
                if rollbackResult != 0 {
                    shouldRemoveTemporary = false
                    throw TGSidianError.invalidOperation(
                        "Atomic replacement validation failed; both complete versions were preserved"
                    )
                }
                throw error
            }
            guard replacedFingerprint == expectedFingerprint else {
                let rollbackResult = Darwin.renamex_np(
                    temporary.path,
                    destination.path,
                    UInt32(RENAME_SWAP)
                )
                if rollbackResult != 0 {
                    // Both complete versions still exist. Never delete the displaced external
                    // revision when rollback itself fails.
                    shouldRemoveTemporary = false
                    throw TGSidianError.invalidOperation(
                        "Atomic replacement rollback failed; both complete versions were preserved"
                    )
                }
                throw TGSidianError.conflict(SaveConflict(
                    path: path,
                    expected: expectedFingerprint,
                    actual: replacedFingerprint,
                    attemptedContent: content
                ))
            }
            try fileManager.removeItem(at: temporary)
            shouldRemoveTemporary = false
        } else {
            // New-file creation must never overwrite a file that appeared after our checks.
            guard Darwin.renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST {
                    throw TGSidianError.destinationExists(path)
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            shouldRemoveTemporary = false
        }
        synchronizeDirectory(directory)
        return try readWithoutInstrumentation(path)
    }

    public func move(_ source: RelativePath, to destination: RelativePath) throws {
        _ = try moveSafely(source, to: destination, expectedFingerprint: nil)
    }

    /// Moves a canonical note with the same optimistic-concurrency guard used by atomic saves.
    /// `rename(2)` is atomic on the vault volume; synchronizing both parent directories makes the
    /// directory entry durable before a recovery record can be cleared.
    @discardableResult
    public func moveSafely(
        _ source: RelativePath,
        to destination: RelativePath,
        expectedFingerprint: FileFingerprint?
    ) throws -> VaultFileSnapshot {
        guard source != destination else { return try readWithoutInstrumentation(source) }
        let sourceURL = try root.resolve(source)
        let destinationURL = try root.resolve(destination)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw TGSidianError.fileNotFound(source)
        }
        let isCaseOnlyRename = source != destination
            && NotePathIdentity.key(source.rawValue) == NotePathIdentity.key(destination.rawValue)
        guard (try !hasCaseInsensitiveComponentCollision(destination) || isCaseOnlyRename),
              try !caseInsensitiveSiblingExists(destinationURL, excluding: sourceURL)
        else {
            throw TGSidianError.destinationExists(destination)
        }
        if let expectedFingerprint {
            let actual = try currentFingerprint(at: sourceURL)
            guard actual == expectedFingerprint else {
                throw TGSidianError.conflict(SaveConflict(
                    path: source,
                    expected: expectedFingerprint,
                    actual: actual,
                    attemptedContent: ""
                ))
            }
        }

        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        guard Darwin.rename(sourceURL.path, destinationURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        synchronizeDirectory(sourceURL.deletingLastPathComponent())
        if sourceURL.deletingLastPathComponent() != destinationDirectory {
            synchronizeDirectory(destinationDirectory)
        }
        return try readWithoutInstrumentation(destination)
    }

    public func remove(_ path: RelativePath) throws {
        _ = try removeSafely(path, expectedFingerprint: nil)
    }

    /// Moves a vault file into Finder's Trash. This deliberately has no recovery-journal record:
    /// macOS owns the resulting location and restoring it is a Finder operation.
    @discardableResult
    public func moveToMacOSTrash(_ path: RelativePath) throws -> VaultFileSnapshot {
        let snapshot = try readWithoutInstrumentation(path)
        let url = try root.resolve(path)
        _ = try fileManager.trashItem(at: url, resultingItemURL: nil)
        synchronizeDirectory(url.deletingLastPathComponent())
        return snapshot
    }

    /// Removes a note only if it is still the exact revision captured in the recovery record.
    /// The caller stores that record durably before entering this method.
    @discardableResult
    public func removeSafely(
        _ path: RelativePath,
        expectedFingerprint: FileFingerprint?
    ) throws -> VaultFileSnapshot {
        let snapshot = try readWithoutInstrumentation(path)
        if let expectedFingerprint, snapshot.fingerprint != expectedFingerprint {
            throw TGSidianError.conflict(SaveConflict(
                path: path,
                expected: expectedFingerprint,
                actual: snapshot.fingerprint,
                attemptedContent: snapshot.content
            ))
        }
        let url = try root.resolve(path)
        try fileManager.removeItem(at: url)
        synchronizeDirectory(url.deletingLastPathComponent())
        return snapshot
    }

    public func resolvedURL(for path: RelativePath) throws -> URL {
        try root.resolve(path)
    }

    private func readWithoutInstrumentation(_ path: RelativePath) throws -> VaultFileSnapshot {
        let url = try root.resolve(path)
        guard let data = fileManager.contents(atPath: url.path),
              let content = String(data: data, encoding: .utf8)
        else { throw TGSidianError.unreadableFile(path) }
        return VaultFileSnapshot(path: path, content: content, fingerprint: try fingerprint(url: url, data: data))
    }

    private func currentFingerprint(at url: URL) throws -> FileFingerprint? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try fingerprint(url: url, data: data)
    }

    private func fingerprint(url: URL, data: Data) throws -> FileFingerprint {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        var digestBytes: [UInt8] = []
        digestBytes.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            digestBytes.append(Self.lowercaseHexDigits[Int(byte >> 4)])
            digestBytes.append(Self.lowercaseHexDigits[Int(byte & 0x0F)])
        }
        let digest = String(decoding: digestBytes, as: UTF8.self)
        return FileFingerprint(byteCount: data.count, modificationDate: modificationDate, contentHash: digest)
    }

    private func hasCaseInsensitiveComponentCollision(_ path: RelativePath) throws -> Bool {
        var current = rootURL
        for component in path.components {
            guard fileManager.fileExists(atPath: current.path) else { return false }
            let names = try fileManager.contentsOfDirectory(atPath: current.path)
            if names.contains(component) {
                current.appendPathComponent(component)
                continue
            }
            if names.contains(where: { NotePathIdentity.key($0) == NotePathIdentity.key(component) }) {
                return true
            }
            current.appendPathComponent(component)
        }
        return false
    }

    private func caseInsensitiveSiblingExists(_ destination: URL, excluding source: URL?) throws -> Bool {
        let parent = destination.deletingLastPathComponent()
        let names = (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.contains { name in
            let candidate = parent.appendingPathComponent(name).standardizedFileURL
            if let source, candidate == source.standardizedFileURL { return false }
            return NotePathIdentity.key(name) == NotePathIdentity.key(destination.lastPathComponent)
        }
    }

    private func synchronizeDirectory(_ directory: URL) {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fsync(descriptor)
    }
}

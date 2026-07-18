import AppCore
import Foundation
import TestSupport
import Testing
import VaultKit

@Suite("Canonical vault filesystem", .serialized)
struct VaultTests {
    @Test("fixture discovery is read-only and ignores escaping symlinks")
    func discoveryAndContainment() async throws {
        let fixture = try makeFixture()
        let before = try fileHashes(root: fixture.rootURL)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-outside-\(UUID().uuidString).md")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = fixture.rootURL.appendingPathComponent("Escape.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let paths = try await fixture.vault.listMarkdownFiles()
        #expect(paths.contains(try RelativePath("Home.md")))
        #expect(!paths.contains(try RelativePath("Escape.md")))
        await #expect(throws: TGSidianError.self) {
            _ = try await fixture.vault.read(try RelativePath("Escape.md"))
        }

        try FileManager.default.removeItem(at: link)
        let after = try fileHashes(root: fixture.rootURL)
        #expect(before == after)
    }

    @Test("default and user-configured ignored directories are not discovered")
    func ignoredDirectoryRules() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-ignore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [".git", "node_modules", "Private"] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("ignored".utf8).write(to: url.appendingPathComponent("Ignored.md"))
        }
        try Data("visible".utf8).write(to: root.appendingPathComponent("Visible.markdown"))
        let vault = try VaultActor(
            rootURL: root,
            ignoredDirectoryNames: [
                ".git", "node_modules", ".build", "build", "DerivedData", "Pods", "Carthage", "Private"
            ]
        )

        #expect(try await vault.listMarkdownFiles() == [RelativePath("Visible.markdown")])
    }

    @Test("an intermediate directory symlink cannot escape the vault for reads or writes")
    func intermediateSymlinkEscape() async throws {
        let fixture = try makeFixture()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside secret".utf8).write(to: outside.appendingPathComponent("Secret.md"))
        try FileManager.default.createSymbolicLink(
            at: fixture.rootURL.appendingPathComponent("Linked", isDirectory: true),
            withDestinationURL: outside
        )
        let escapedPath = try RelativePath("Linked/Secret.md")
        let escapedWrite = try RelativePath("Linked/New.md")

        #expect(try await !fixture.vault.listMarkdownFiles().contains(escapedPath))
        await #expect(throws: TGSidianError.self) {
            _ = try await fixture.vault.read(escapedPath)
        }
        await #expect(throws: TGSidianError.self) {
            _ = try await fixture.vault.atomicWrite(
                "must stay contained",
                to: escapedWrite,
                expectedFingerprint: nil
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("New.md").path))
    }

    @Test("atomic save detects an external edit and never overwrites it")
    func atomicConflict() async throws {
        let fixture = try makeFixture()
        let path = try RelativePath("Home.md")
        let original = try await fixture.vault.read(path)
        let directURL = fixture.rootURL.appendingPathComponent(path.rawValue)
        let external = "# External revision\n"
        try Data(external.utf8).write(to: directURL, options: .atomic)

        await #expect(throws: TGSidianError.self) {
            _ = try await fixture.vault.atomicWrite(
                "# My unsaved revision\n",
                to: path,
                expectedFingerprint: original.fingerprint
            )
        }
        #expect(try String(contentsOf: directURL, encoding: .utf8) == external)
    }

    @Test("a successful save atomically replaces complete UTF-8 content")
    func atomicSuccess() async throws {
        let fixture = try makeFixture()
        let path = try RelativePath("Home.md")
        let original = try await fixture.vault.read(path)
        let replacement = original.content + "\nComplete replacement ✅\n"
        let written = try await fixture.vault.atomicWrite(
            replacement,
            to: path,
            expectedFingerprint: original.fingerprint
        )
        #expect(written.content == replacement)
        #expect(written.fingerprint.contentHash != original.fingerprint.contentHash)
        #expect(try String(contentsOf: fixture.rootURL.appendingPathComponent("Home.md"), encoding: .utf8) == replacement)
    }

    @Test("a late external edit after temporary write is detected before replace")
    func lateWriteConflict() async throws {
        let fixture = try makeFixture()
        let path = try RelativePath("Home.md")
        let destination = fixture.rootURL.appendingPathComponent(path.rawValue)
        let external = "# Late external revision\n"
        let guardedVault = try VaultActor(
            rootURL: fixture.rootURL,
            hooks: AtomicWriteHooks(afterTemporaryFileWritten: { _ in
                try Data(external.utf8).write(to: destination, options: .atomic)
            })
        )
        let original = try await guardedVault.read(path)
        await #expect(throws: TGSidianError.self) {
            _ = try await guardedVault.atomicWrite(
                "# Mine\n",
                to: path,
                expectedFingerprint: original.fingerprint
            )
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == external)
    }

    @Test("recovery journal retains a conflicted edit and clears successful saves")
    func recoveryJournal() async throws {
        let fixture = try makeFixture()
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = try RecoveryJournal(directory: journalURL)
        let coordinator = SaveCoordinator(vault: fixture.vault, journal: journal)
        let path = try RelativePath("Home.md")
        let original = try await fixture.vault.read(path)

        try Data("external".utf8).write(to: fixture.rootURL.appendingPathComponent(path.rawValue), options: .atomic)
        do {
            _ = try await coordinator.save("mine", to: path, expectedFingerprint: original.fingerprint)
            Issue.record("Expected a save conflict")
        } catch {}
        let pending = try await coordinator.pendingRecovery()
        #expect(pending.count == 1)
        #expect(pending.first?.attemptedContent == "mine")

        let externalSnapshot = try await fixture.vault.read(path)
        _ = try await coordinator.save(
            "resolved content",
            to: path,
            expectedFingerprint: externalSnapshot.fingerprint
        )
        let afterSuccessfulSave = try await coordinator.pendingRecovery()
        #expect(afterSuccessfulSave == pending)
    }

    @Test("case-insensitive destinations cannot be silently overwritten")
    func caseInsensitiveMoveCollision() async throws {
        let fixture = try makeFixture()
        let source = try RelativePath("Notes/Scratch.md")
        let destination = try RelativePath("Notes/architecture.md")
        await #expect(throws: TGSidianError.self) {
            try await fixture.vault.move(source, to: destination)
        }
        await #expect(throws: TGSidianError.self) {
            _ = try await fixture.vault.atomicWrite(
                "# New\n",
                to: try RelativePath("notes/New.md"),
                expectedFingerprint: nil
            )
        }
        #expect(try await fixture.vault.exists(source))
        let rootEntries = try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path)
        #expect(!rootEntries.contains("notes"))
    }

    private func makeFixture() throws -> TemporaryVault {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/AcceptanceVault", isDirectory: true)
        return try TemporaryVault(copying: url)
    }

    private func fileHashes(root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return result }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            result[relative] = try Data(contentsOf: fileURL).base64EncodedString()
        }
        return result
    }
}

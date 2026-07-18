import AppCore
import Foundation

/// A vault the user has granted access to, plus the security-scoped bookmark that renews it
/// across launches (SPEC §6.1, §16).
public struct VaultBookmark: Hashable, Sendable, Codable, Identifiable {
    public let vaultID: VaultID
    public let displayName: String
    public let bookmarkData: Data
    public let lastOpenedAt: Date

    public var id: VaultID { vaultID }

    public init(vaultID: VaultID, displayName: String, bookmarkData: Data, lastOpenedAt: Date = Date()) {
        self.vaultID = vaultID
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastOpenedAt = lastOpenedAt
    }
}

/// The outcome of resolving a bookmark. `permissionLost` is a first-class case rather than an
/// error string because SPEC §19 requires an explicit "reselect the vault" recovery path.
public enum BookmarkResolution: Sendable {
    case resolved(url: URL, isStale: Bool)
    case permissionLost(reason: String)
}

public protocol VaultBookmarkStoring: Sendable {
    func bookmarks() -> [VaultBookmark]
    func store(url: URL, vaultID: VaultID) throws -> VaultBookmark
    func resolve(_ bookmark: VaultBookmark) -> BookmarkResolution
    func remove(vaultID: VaultID)
    func markOpened(vaultID: VaultID)
}

/// Persists bookmarks in Application Support (never in the vault, per SPEC §10.3's rule that
/// derived and app state live outside the user's Markdown).
public final class VaultBookmarkStore: VaultBookmarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.fileURL = directory.appendingPathComponent("vault-bookmarks.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func bookmarks() -> [VaultBookmark] {
        lock.lock()
        defer { lock.unlock() }
        return load().sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    public func store(url: URL, vaultID: VaultID) throws -> VaultBookmark {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let bookmark = VaultBookmark(
            vaultID: vaultID,
            displayName: url.lastPathComponent,
            bookmarkData: data
        )
        lock.lock()
        defer { lock.unlock() }
        var all = load().filter { $0.vaultID != vaultID }
        all.append(bookmark)
        try persist(all)
        return bookmark
    }

    public func resolve(_ bookmark: VaultBookmark) -> BookmarkResolution {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return .resolved(url: url, isStale: isStale)
        } catch {
            return .permissionLost(reason: "The folder moved, was renamed, or access was revoked.")
        }
    }

    public func remove(vaultID: VaultID) {
        lock.lock()
        defer { lock.unlock() }
        try? persist(load().filter { $0.vaultID != vaultID })
    }

    public func markOpened(vaultID: VaultID) {
        lock.lock()
        defer { lock.unlock() }
        let updated = load().map { bookmark in
            bookmark.vaultID == vaultID
                ? VaultBookmark(
                    vaultID: bookmark.vaultID,
                    displayName: bookmark.displayName,
                    bookmarkData: bookmark.bookmarkData,
                    lastOpenedAt: Date()
                )
                : bookmark
        }
        try? persist(updated)
    }

    private func load() -> [VaultBookmark] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([VaultBookmark].self, from: data)) ?? []
    }

    private func persist(_ bookmarks: [VaultBookmark]) throws {
        try encoder.encode(bookmarks).write(to: fileURL, options: .atomic)
    }
}

/// In-memory bookmark store for tests. Records `startAccessing` balance so tests can assert the
/// app does not leak security-scoped resources.
public final class InMemoryBookmarkStore: VaultBookmarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [VaultID: VaultBookmark] = [:]
    private var urls: [VaultID: URL] = [:]

    public init() {}

    public func bookmarks() -> [VaultBookmark] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    public func store(url: URL, vaultID: VaultID) throws -> VaultBookmark {
        let bookmark = VaultBookmark(
            vaultID: vaultID,
            displayName: url.lastPathComponent,
            bookmarkData: Data(url.path.utf8)
        )
        lock.lock()
        defer { lock.unlock() }
        storage[vaultID] = bookmark
        urls[vaultID] = url
        return bookmark
    }

    public func resolve(_ bookmark: VaultBookmark) -> BookmarkResolution {
        lock.lock()
        defer { lock.unlock() }
        guard let url = urls[bookmark.vaultID] else {
            return .permissionLost(reason: "No recorded URL for this vault.")
        }
        return .resolved(url: url, isStale: false)
    }

    public func remove(vaultID: VaultID) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: vaultID)
        urls.removeValue(forKey: vaultID)
    }

    public func markOpened(vaultID: VaultID) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = storage[vaultID] else { return }
        storage[vaultID] = VaultBookmark(
            vaultID: existing.vaultID,
            displayName: existing.displayName,
            bookmarkData: existing.bookmarkData,
            lastOpenedAt: Date()
        )
    }
}

import Foundation

/// Security-scoped bookmarks for auxiliary folders the user has linked beyond the vault itself
/// — today the Obsidian vault root, when the app's vault is a subtree of it and the plugin
/// configuration in `.obsidian/` sits outside the vault's sandbox grant.
public protocol LinkedFolderBookmarkStoring: Sendable {
    /// Resolves a linked folder, refreshing the stored bookmark when macOS reports it stale.
    /// Returns nil when nothing is linked or the grant no longer resolves.
    func resolveLinkedFolder(forKey key: String) -> URL?
    func storeLinkedFolder(_ url: URL, forKey key: String) throws
    func removeLinkedFolder(forKey key: String)
}

/// Persists linked-folder bookmarks next to the vault bookmarks in Application Support.
public final class LinkedFolderBookmarkStore: LinkedFolderBookmarkStoring, @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "tgsidian.linked-folder-bookmarks")

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("linked-folders.json")
    }

    public func resolveLinkedFolder(forKey key: String) -> URL? {
        queue.sync {
            guard let data = load()[key] else { return nil }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            if isStale, let refreshed = try? Self.bookmarkData(for: url) {
                var all = load()
                all[key] = refreshed
                save(all)
            }
            return url
        }
    }

    public func storeLinkedFolder(_ url: URL, forKey key: String) throws {
        let data = try Self.bookmarkData(for: url)
        queue.sync {
            var all = load()
            all[key] = data
            save(all)
        }
    }

    public func removeLinkedFolder(forKey key: String) {
        queue.sync {
            var all = load()
            all[key] = nil
            save(all)
        }
    }

    private static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func load() -> [String: Data] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    private func save(_ all: [String: Data]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Test double: no security scope, in memory.
public final class InMemoryLinkedFolderBookmarkStore: LinkedFolderBookmarkStoring, @unchecked Sendable {
    private var folders: [String: URL] = [:]
    private let queue = DispatchQueue(label: "tgsidian.linked-folder-bookmarks.memory")

    public init() {}

    public func resolveLinkedFolder(forKey key: String) -> URL? {
        queue.sync { folders[key] }
    }

    public func storeLinkedFolder(_ url: URL, forKey key: String) throws {
        queue.sync { folders[key] = url }
    }

    public func removeLinkedFolder(forKey key: String) {
        _ = queue.sync { folders.removeValue(forKey: key) }
    }
}

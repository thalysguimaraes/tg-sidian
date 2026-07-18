import AppCore
import Foundation

public struct VaultRoot: Sendable {
    public let url: URL
    public let resolvedURL: URL

    public init(url: URL) throws {
        guard url.isFileURL else {
            throw TGSidianError.invalidOperation("Vault root must be a file URL")
        }
        self.url = url.standardizedFileURL
        self.resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
    }

    public func resolve(_ path: RelativePath) throws -> URL {
        var candidate = resolvedURL
        for component in path.components {
            candidate.appendPathComponent(component, isDirectory: false)
            candidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            try ensureResolvedURLContained(candidate)
        }
        return candidate
    }

    public func relativePath(for fileURL: URL) throws -> RelativePath {
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
        try ensureResolvedURLContained(resolved)
        let rootPath = resolvedURL.path.hasSuffix("/") ? resolvedURL.path : resolvedURL.path + "/"
        guard resolved.path.hasPrefix(rootPath) else {
            throw TGSidianError.pathEscapesVault(resolved.path)
        }
        return try RelativePath(String(resolved.path.dropFirst(rootPath.count)))
    }

    public func ensureContained(_ fileURL: URL) throws {
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
        try ensureResolvedURLContained(resolved)
    }

    /// Validates a URL that the caller has already canonicalized. This avoids a second symlink
    /// walk while retaining the per-component escape checks in `resolve`.
    private func ensureResolvedURLContained(_ resolved: URL) throws {
        let rootPath = resolvedURL.path
        let candidatePath = resolved.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw TGSidianError.pathEscapesVault(candidatePath)
        }
    }
}

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
            try ensureContained(candidate)
        }
        return candidate
    }

    public func relativePath(for fileURL: URL) throws -> RelativePath {
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
        try ensureContained(resolved)
        let rootPath = resolvedURL.path.hasSuffix("/") ? resolvedURL.path : resolvedURL.path + "/"
        guard resolved.path.hasPrefix(rootPath) else {
            throw TGSidianError.pathEscapesVault(resolved.path)
        }
        return try RelativePath(String(resolved.path.dropFirst(rootPath.count)))
    }

    public func ensureContained(_ fileURL: URL) throws {
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedURL.path
        let candidatePath = resolved.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw TGSidianError.pathEscapesVault(candidatePath)
        }
    }
}

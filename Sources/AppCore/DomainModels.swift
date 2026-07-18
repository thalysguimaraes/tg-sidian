import Foundation

public enum TGSidianError: Error, Sendable, Equatable, LocalizedError {
    case invalidRelativePath(String)
    case pathEscapesVault(String)
    case fileNotFound(RelativePath)
    case unreadableFile(RelativePath)
    case invalidFrontMatter(String)
    case conflict(SaveConflict)
    case destinationExists(RelativePath)
    case indexCorrupt(String)
    case invalidOperation(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path): "Invalid relative path: \(path)"
        case let .pathEscapesVault(path): "Resolved path escapes the vault: \(path)"
        case let .fileNotFound(path): "File not found: \(path.rawValue)"
        case let .unreadableFile(path): "File is not valid UTF-8 or cannot be read: \(path.rawValue)"
        case let .invalidFrontMatter(message): "Invalid front matter: \(message)"
        case let .conflict(conflict): "External write conflict at \(conflict.path.rawValue)"
        case let .destinationExists(path): "Destination already exists: \(path.rawValue)"
        case let .indexCorrupt(message): "Derived index is corrupt: \(message)"
        case let .invalidOperation(message): message
        }
    }
}

public enum FrontMatterValue: Hashable, Sendable, Codable {
    case string(String)
    case strings([String])
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case null

    public var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .strings(values): values.joined(separator: ", ")
        case let .bool(value): value ? "true" : "false"
        case let .integer(value): String(value)
        case let .number(value): String(value)
        case .null: nil
        }
    }

    public var stringValues: [String] {
        switch self {
        case let .strings(values): values
        case let .string(value): [value]
        default: stringValue.map { [$0] } ?? []
        }
    }
}

public struct MarkdownDiagnostic: Hashable, Sendable, Codable {
    public enum Severity: String, Hashable, Sendable, Codable {
        case warning
        case error
    }

    public let severity: Severity
    public let message: String
    public let line: Int?

    public init(severity: Severity, message: String, line: Int? = nil) {
        self.severity = severity
        self.message = message
        self.line = line
    }
}

public struct MarkdownHeading: Hashable, Sendable, Codable {
    public let level: Int
    public let text: String
    public let slug: String
    public let line: Int

    public init(level: Int, text: String, slug: String, line: Int) {
        self.level = level
        self.text = text
        self.slug = slug
        self.line = line
    }
}

public struct WikiLink: Hashable, Sendable, Codable {
    public let rawTarget: String
    public let heading: String?
    public let alias: String?
    public let line: Int

    public init(rawTarget: String, heading: String? = nil, alias: String? = nil, line: Int) {
        self.rawTarget = rawTarget
        self.heading = heading
        self.alias = alias
        self.line = line
    }
}

public struct MarkdownTask: Hashable, Sendable, Codable {
    public enum State: String, Hashable, Sendable, Codable {
        case todo
        case done
        case cancelled
    }

    public let state: State
    public let text: String
    public let line: Int

    public init(state: State, text: String, line: Int) {
        self.state = state
        self.text = text
        self.line = line
    }
}

public struct ParsedNote: Hashable, Sendable, Codable {
    public let title: String
    public let body: String
    public let rawFrontMatter: String?
    public let frontMatter: [String: FrontMatterValue]
    public let headings: [MarkdownHeading]
    public let links: [WikiLink]
    public let tags: Set<String>
    public let tasks: [MarkdownTask]
    public let diagnostics: [MarkdownDiagnostic]

    public init(
        title: String,
        body: String,
        rawFrontMatter: String?,
        frontMatter: [String: FrontMatterValue],
        headings: [MarkdownHeading],
        links: [WikiLink],
        tags: Set<String>,
        tasks: [MarkdownTask],
        diagnostics: [MarkdownDiagnostic]
    ) {
        self.title = title
        self.body = body
        self.rawFrontMatter = rawFrontMatter
        self.frontMatter = frontMatter
        self.headings = headings
        self.links = links
        self.tags = tags
        self.tasks = tasks
        self.diagnostics = diagnostics
    }
}

public struct NoteSummary: Hashable, Sendable, Codable {
    public let id: NoteID
    public let path: RelativePath
    public let title: String
    public let tags: Set<String>
    public let type: String?
    public let modifiedAt: Date

    public init(id: NoteID, path: RelativePath, title: String, tags: Set<String>, type: String?, modifiedAt: Date) {
        self.id = id
        self.path = path
        self.title = title
        self.tags = tags
        self.type = type
        self.modifiedAt = modifiedAt
    }
}

public struct ResolvedConnection: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case resolved
        case unresolved
        case ambiguous
    }

    public let source: NoteID
    public let target: NoteID?
    public let rawTarget: String
    public let status: Status

    public init(source: NoteID, target: NoteID?, rawTarget: String, status: Status) {
        self.source = source
        self.target = target
        self.rawTarget = rawTarget
        self.status = status
    }
}

public struct Backlink: Hashable, Sendable, Codable {
    public let source: NoteSummary
    public let target: NoteID
    public let excerpt: String
    public let heading: String?

    public init(source: NoteSummary, target: NoteID, excerpt: String, heading: String?) {
        self.source = source
        self.target = target
        self.excerpt = excerpt
        self.heading = heading
    }
}

public struct SearchRequest: Hashable, Sendable, Codable {
    public var query: String
    public var folder: RelativePath?
    public var type: String?
    public var tag: String?
    public var modifiedAfter: Date?
    public var hasUnresolvedLinks: Bool?
    public var limit: Int

    public init(
        query: String,
        folder: RelativePath? = nil,
        type: String? = nil,
        tag: String? = nil,
        modifiedAfter: Date? = nil,
        hasUnresolvedLinks: Bool? = nil,
        limit: Int = 50
    ) {
        self.query = query
        self.folder = folder
        self.type = type
        self.tag = tag
        self.modifiedAfter = modifiedAfter
        self.hasUnresolvedLinks = hasUnresolvedLinks
        self.limit = limit
    }
}

public struct SearchHit: Hashable, Sendable, Codable {
    public let note: NoteSummary
    public let score: Int
    public let excerpt: String

    public init(note: NoteSummary, score: Int, excerpt: String) {
        self.note = note
        self.score = score
        self.excerpt = excerpt
    }
}


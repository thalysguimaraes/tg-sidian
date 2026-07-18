import Foundation

public struct RelativePath: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw TGSidianError.invalidRelativePath(rawValue)
        }
        guard !rawValue.hasPrefix("/"), !rawValue.hasSuffix("/") else {
            throw TGSidianError.invalidRelativePath(rawValue)
        }
        guard !rawValue.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TGSidianError.invalidRelativePath(rawValue)
        }

        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TGSidianError.invalidRelativePath(rawValue)
        }

        self.rawValue = rawValue.precomposedStringWithCanonicalMapping
    }

    private init(trustedLiteral rawValue: String) {
        self.rawValue = rawValue.precomposedStringWithCanonicalMapping
    }

    public static let dailyNotesDirectory = RelativePath(trustedLiteral: "Daily Notes")

    public var description: String { rawValue }
    public var components: [String] { rawValue.split(separator: "/").map(String.init) }
    public var lastComponent: String { components.last ?? rawValue }
    public var pathExtension: String { (lastComponent as NSString).pathExtension }
    public var nameWithoutExtension: String { (lastComponent as NSString).deletingPathExtension }

    public var deletingLastComponent: RelativePath? {
        guard components.count > 1 else { return nil }
        return try? RelativePath(components.dropLast().joined(separator: "/"))
    }

    public var deletingPathExtension: RelativePath {
        let value = (rawValue as NSString).deletingPathExtension
        return (try? RelativePath(value)) ?? self
    }

    public func appending(_ component: String) throws -> RelativePath {
        try RelativePath(rawValue + "/" + component)
    }

    public static func < (lhs: RelativePath, rhs: RelativePath) -> Bool {
        lhs.rawValue.localizedStandardCompare(rhs.rawValue) == .orderedAscending
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct VaultID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Canonical key for filesystem identity and wiki-link path matching.
///
/// APFS case-insensitive volumes preserve diacritics and whitespace: `Cafe.md`, `Café.md`, and
/// `Cafe .md` are distinct files. Keeping this transform in AppCore prevents discovery, NoteID,
/// and link resolution from drifting into incompatible collision rules again.
public enum NotePathIdentity {
    public static func key(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    public static func noteKey(for path: RelativePath) -> String {
        key(path.deletingPathExtension.rawValue)
    }
}

public struct NoteID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(path: RelativePath) {
        self.rawValue = NotePathIdentity.noteKey(for: path)
    }

    public var description: String { rawValue }

    public static func < (lhs: NoteID, rhs: NoteID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct FileFingerprint: Hashable, Sendable, Codable {
    public let byteCount: Int
    public let modificationDate: Date
    public let contentHash: String

    public init(byteCount: Int, modificationDate: Date, contentHash: String) {
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.contentHash = contentHash
    }
}

public struct VaultFileSnapshot: Hashable, Sendable, Codable {
    public let path: RelativePath
    public let content: String
    public let fingerprint: FileFingerprint

    public init(path: RelativePath, content: String, fingerprint: FileFingerprint) {
        self.path = path
        self.content = content
        self.fingerprint = fingerprint
    }
}

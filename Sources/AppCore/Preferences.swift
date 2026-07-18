import Foundation
import Observation

public enum AppAppearance: String, Hashable, Sendable, Codable {
    case system
    case light
    case dark
}

public enum NewNoteLocation: Hashable, Sendable, Codable {
    case vaultRoot
    case sameFolder
    case chosenFolder(RelativePath)

    private enum CodingKeys: String, CodingKey { case kind, folder }
    private enum Kind: String, Codable { case vaultRoot, sameFolder, chosenFolder }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .vaultRoot: self = .vaultRoot
        case .sameFolder: self = .sameFolder
        case .chosenFolder: self = .chosenFolder(try values.decode(RelativePath.self, forKey: .folder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .vaultRoot:
            try values.encode(Kind.vaultRoot, forKey: .kind)
        case .sameFolder:
            try values.encode(Kind.sameFolder, forKey: .kind)
        case let .chosenFolder(folder):
            try values.encode(Kind.chosenFolder, forKey: .kind)
            try values.encode(folder, forKey: .folder)
        }
    }
}

public enum DeletedNoteDestination: String, Hashable, Sendable, Codable {
    case macOSTrash
    case vaultTrash
}

public enum InternalLinkFormat: String, Hashable, Sendable, Codable {
    case wikiLink
    case markdown
}

/// Local preferences needed by the design-backed vault and editor surfaces.
/// These values do not imply a separate Settings product screen.
public struct AppPreferences: Hashable, Sendable, Codable {
    public var appearance: AppAppearance
    public var editorFontSize: Double
    public var editorLineWidth: Double
    public var spellcheckEnabled: Bool
    public var ignorePatterns: Set<String>
    public var newNoteLocation: NewNoteLocation
    public var deletedNoteDestination: DeletedNoteDestination
    public var internalLinkFormat: InternalLinkFormat
    public var shortestLinkPaths: Bool
    public var templatesFolder: RelativePath?

    public init(
        appearance: AppAppearance = .system,
        editorFontSize: Double = 15,
        editorLineWidth: Double = 720,
        spellcheckEnabled: Bool = true,
        ignorePatterns: Set<String> = [],
        newNoteLocation: NewNoteLocation = .vaultRoot,
        deletedNoteDestination: DeletedNoteDestination = .vaultTrash,
        internalLinkFormat: InternalLinkFormat = .wikiLink,
        shortestLinkPaths: Bool = true,
        templatesFolder: RelativePath? = nil
    ) {
        self.appearance = appearance
        self.editorFontSize = editorFontSize
        self.editorLineWidth = editorLineWidth
        self.spellcheckEnabled = spellcheckEnabled
        self.ignorePatterns = ignorePatterns
        self.newNoteLocation = newNoteLocation
        self.deletedNoteDestination = deletedNoteDestination
        self.internalLinkFormat = internalLinkFormat
        self.shortestLinkPaths = shortestLinkPaths
        self.templatesFolder = templatesFolder
    }

    private enum CodingKeys: String, CodingKey {
        case appearance
        case editorFontSize
        case editorLineWidth
        case spellcheckEnabled
        case ignorePatterns
        case newNoteLocation
        case deletedNoteDestination
        case internalLinkFormat
        case shortestLinkPaths
        case templatesFolder
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try values.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        editorFontSize = try values.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? 15
        editorLineWidth = try values.decodeIfPresent(Double.self, forKey: .editorLineWidth) ?? 720
        spellcheckEnabled = try values.decodeIfPresent(Bool.self, forKey: .spellcheckEnabled) ?? true
        ignorePatterns = try values.decodeIfPresent(Set<String>.self, forKey: .ignorePatterns) ?? []
        newNoteLocation = try values.decodeIfPresent(NewNoteLocation.self, forKey: .newNoteLocation) ?? .vaultRoot
        // Preserve the pre-settings delete behavior (recoverable in-vault staging) for existing
        // installs; macOS Trash is an explicit opt-in.
        deletedNoteDestination = try values.decodeIfPresent(DeletedNoteDestination.self, forKey: .deletedNoteDestination) ?? .vaultTrash
        internalLinkFormat = try values.decodeIfPresent(InternalLinkFormat.self, forKey: .internalLinkFormat) ?? .wikiLink
        shortestLinkPaths = try values.decodeIfPresent(Bool.self, forKey: .shortestLinkPaths) ?? true
        templatesFolder = try values.decodeIfPresent(RelativePath.self, forKey: .templatesFolder)
    }
}

/// Machine-local app preferences shared by the launch screen and every opened vault.
///
/// Storing one Codable value keeps migrations explicit and prevents app-wide presentation
/// choices from leaking into a vault's portable workspace state.
@Observable
@MainActor
public final class AppPreferencesStore {
    public static let defaultKey = "app-preferences"

    public var preferences: AppPreferences {
        didSet {
            guard preferences != oldValue else { return }
            persist()
        }
    }

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = AppPreferencesStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let restored = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            preferences = restored
        } else {
            preferences = AppPreferences()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

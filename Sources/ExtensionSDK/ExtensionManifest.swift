import Foundation

public enum ExtensionCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case network
    case keychain
    case vaultRead
    case editorDecoration
}

public struct ExtensionManifest: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let capabilities: Set<ExtensionCapability>
    public let enabledByDefault: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        capabilities: Set<ExtensionCapability> = [],
        enabledByDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.capabilities = capabilities
        self.enabledByDefault = enabledByDefault
    }
}

public protocol TGSidianExtension: Sendable {
    static var manifest: ExtensionManifest { get }
    @MainActor init(context: ExtensionContext)
}

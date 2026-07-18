import Foundation
import Observation

@MainActor
@Observable
public final class ExtensionRegistry {
    /// Built-ins are composed statically by the application. The SDK has no dependency on
    /// concrete extension targets, so its own baseline list is intentionally empty.
    public static let builtIn: [any TGSidianExtension.Type] = []

    public let extensionTypes: [any TGSidianExtension.Type]

    private let defaults: UserDefaults
    private let defaultsKeyPrefix: String
    private let context: @MainActor (ExtensionManifest) -> ExtensionContext
    private var cachedEnabledExtensions: [any TGSidianExtension] = []

    /// Changes whenever enablement changes, allowing UI consumers to invalidate provider output
    /// without recreating the registry or relaunching the application.
    public private(set) var revision: UInt = 0

    public init(
        extensionTypes: [any TGSidianExtension.Type] = ExtensionRegistry.builtIn,
        defaults: UserDefaults = .standard,
        defaultsKeyPrefix: String = "extensions.enabled.",
        context: @escaping @MainActor (ExtensionManifest) -> ExtensionContext
            = { ExtensionContext(manifest: $0) }
    ) {
        self.extensionTypes = Self.resolvingDuplicateIdentifiers(in: extensionTypes)
        self.defaults = defaults
        self.defaultsKeyPrefix = defaultsKeyPrefix
        self.context = context
        rebuildEnabledExtensions()
    }

    public var manifests: [ExtensionManifest] {
        var result: [ExtensionManifest] = []
        for extensionType in extensionTypes {
            result.append(extensionType.manifest)
        }
        return result
    }

    public var enabledManifests: [ExtensionManifest] {
        manifests.filter(isEnabled)
    }

    public var enabledExtensions: [any TGSidianExtension] {
        cachedEnabledExtensions
    }

    public func isEnabled(_ manifest: ExtensionManifest) -> Bool {
        let key = defaultsKeyPrefix + manifest.id
        guard defaults.object(forKey: key) != nil else {
            return manifest.enabledByDefault
        }
        return defaults.bool(forKey: key)
    }

    public func setEnabled(_ enabled: Bool, for extensionID: String) {
        guard manifests.contains(where: { $0.id == extensionID }) else { return }
        defaults.set(enabled, forKey: defaultsKeyPrefix + extensionID)
        rebuildEnabledExtensions()
        revision &+= 1
    }

    public func resetEnabledState(for extensionID: String) {
        defaults.removeObject(forKey: defaultsKeyPrefix + extensionID)
        rebuildEnabledExtensions()
        revision &+= 1
    }

    /// Invalidates host renderers after an enabled extension refreshes asynchronous provider
    /// data. This deliberately does not rebuild extensions: doing so could re-load a disabled
    /// integration or discard an extension's in-flight state.
    public func invalidate() {
        revision &+= 1
    }

    private static func resolvingDuplicateIdentifiers(
        in types: [any TGSidianExtension.Type]
    ) -> [any TGSidianExtension.Type] {
        var identifiers = Set<String>()
        return types.filter { identifiers.insert($0.manifest.id).inserted }
    }

    private func rebuildEnabledExtensions() {
        var result: [any TGSidianExtension] = []
        for extensionType in extensionTypes {
            let manifest = extensionType.manifest
            if isEnabled(manifest) {
                result.append(extensionType.init(context: context(manifest)))
            }
        }
        cachedEnabledExtensions = result
    }
}

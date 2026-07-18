import ExtensionSDK
import Foundation
import Testing

@Suite("Extension SDK")
@MainActor
struct ExtensionSDKTests {
    @Test("registry resolves manifests and duplicate identifiers deterministically")
    func manifestResolution() {
        let registry = makeRegistry([DefaultOffExtension.self, DuplicateIDExtension.self])

        #expect(registry.manifests == [DefaultOffExtension.manifest])
    }

    @Test("extensions are default-off unless their manifest opts in")
    func defaultOff() {
        let registry = makeRegistry([DefaultOffExtension.self, DefaultOnExtension.self])

        #expect(registry.enabledManifests.map(\.id) == [DefaultOnExtension.manifest.id])
        #expect(registry.enabledExtensions.count == 1)
    }

    @Test("registry filtering changes immediately and persists in injected defaults")
    func registryFiltering() {
        let defaults = isolatedDefaults()
        let registry = ExtensionRegistry(
            extensionTypes: [DefaultOffExtension.self, DefaultOnExtension.self],
            defaults: defaults
        )

        registry.setEnabled(true, for: DefaultOffExtension.manifest.id)
        registry.setEnabled(false, for: DefaultOnExtension.manifest.id)

        #expect(registry.enabledManifests.map(\.id) == [DefaultOffExtension.manifest.id])
        #expect(registry.revision == 2)
        let reloaded = ExtensionRegistry(
            extensionTypes: [DefaultOffExtension.self, DefaultOnExtension.self],
            defaults: defaults
        )
        #expect(reloaded.enabledManifests.map(\.id) == [DefaultOffExtension.manifest.id])
    }

    @Test("context omits undeclared services and namespaces secret keys")
    func capabilityLimitedContext() async throws {
        let secrets = RecordingSecretsStore()
        let noCapabilities = ExtensionContext(
            manifest: DefaultOffExtension.manifest,
            secrets: secrets
        )
        #expect(noCapabilities.secrets == nil)

        let manifest = ExtensionManifest(
            id: "design.thalys.secrets",
            name: "Secrets",
            summary: "",
            capabilities: [.keychain]
        )
        let context = ExtensionContext(manifest: manifest, secrets: secrets)
        try await context.secrets?.setData(Data([1, 2, 3]), forKey: "token")

        #expect(await secrets.keys() == ["design.thalys.secrets.token"])
    }

    private func makeRegistry(
        _ types: [any TGSidianExtension.Type]
    ) -> ExtensionRegistry {
        ExtensionRegistry(extensionTypes: types, defaults: isolatedDefaults())
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "ExtensionSDKTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
}

private struct DefaultOffExtension: TGSidianExtension {
    static let manifest = ExtensionManifest(
        id: "design.thalys.default-off",
        name: "Default Off",
        summary: "Test extension"
    )

    @MainActor init(context: ExtensionContext) {}
}

private struct DuplicateIDExtension: TGSidianExtension {
    static let manifest = ExtensionManifest(
        id: DefaultOffExtension.manifest.id,
        name: "Duplicate",
        summary: "Must be ignored",
        enabledByDefault: true
    )

    @MainActor init(context: ExtensionContext) {}
}

private struct DefaultOnExtension: TGSidianExtension {
    static let manifest = ExtensionManifest(
        id: "design.thalys.default-on",
        name: "Default On",
        summary: "Test extension",
        enabledByDefault: true
    )

    @MainActor init(context: ExtensionContext) {}
}

private actor RecordingSecretsStore: SecretsStore {
    private var recordedKeys: [String] = []

    func data(forKey key: String) async throws -> Data? {
        recordedKeys.append(key)
        return nil
    }

    func setData(_ data: Data?, forKey key: String) async throws {
        recordedKeys.append(key)
    }

    func keys() -> [String] {
        recordedKeys
    }
}

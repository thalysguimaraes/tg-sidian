import AppCore
import Foundation
import Testing

@Suite("App preferences")
@MainActor
struct AppPreferencesTests {
    @Test("defaults include native spellcheck")
    func defaults() {
        let preferences = AppPreferences()
        #expect(preferences.appearance == .system)
        #expect(preferences.editorFontSize == 15)
        #expect(preferences.editorLineWidth == 720)
        #expect(preferences.spellcheckEnabled)
    }

    @Test("legacy values decode with backward-compatible defaults")
    func legacyDecode() throws {
        let data = Data(
            #"{"appearance":"dark","editorFontSize":17,"editorLineWidth":640,"ignorePatterns":["build"]}"#.utf8
        )
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(preferences.appearance == .dark)
        #expect(preferences.editorFontSize == 17)
        #expect(preferences.editorLineWidth == 640)
        #expect(preferences.spellcheckEnabled)
        #expect(preferences.ignorePatterns == ["build"])
    }

    @Test("machine-local preferences survive a store round trip")
    func storeRoundTrip() throws {
        let suite = "AppPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let key = "preferences"
        let store = AppPreferencesStore(defaults: defaults, key: key)
        store.preferences = AppPreferences(
            appearance: .light,
            editorFontSize: 18,
            editorLineWidth: 680,
            spellcheckEnabled: false,
            ignorePatterns: ["DerivedData"]
        )

        let restored = AppPreferencesStore(defaults: defaults, key: key).preferences
        #expect(restored.appearance == .light)
        #expect(restored.editorFontSize == 18)
        #expect(restored.editorLineWidth == 680)
        #expect(!restored.spellcheckEnabled)
        #expect(restored.ignorePatterns == ["DerivedData"])
    }

    @Test("Files and Links values persist with safe defaults for older settings")
    func filesAndLinksRoundTrip() throws {
        let preferences = AppPreferences(
            newNoteLocation: .chosenFolder(try RelativePath("Notes/Inbox")),
            deletedNoteDestination: .vaultTrash,
            internalLinkFormat: .markdown,
            shortestLinkPaths: false,
            templatesFolder: try RelativePath("Templates")
        )
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored.newNoteLocation == .chosenFolder(try RelativePath("Notes/Inbox")))
        #expect(restored.deletedNoteDestination == .vaultTrash)
        #expect(restored.internalLinkFormat == .markdown)
        #expect(!restored.shortestLinkPaths)
        let expectedTemplatesFolder = try RelativePath("Templates")
        #expect(restored.templatesFolder == expectedTemplatesFolder)
    }
}

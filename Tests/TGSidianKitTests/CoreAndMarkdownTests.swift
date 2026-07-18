import AppCore
import Foundation
import MarkdownKit
import Testing

@Suite("AppCore and Markdown")
struct CoreAndMarkdownTests {
    @Test("relative paths validate traversal and normalize Unicode")
    func relativePathValidation() throws {
        let path = try RelativePath("Notes/Café.md")
        #expect(path.components == ["Notes", "Café.md"])
        #expect(path.nameWithoutExtension == "Café")
        #expect(throws: TGSidianError.self) { try RelativePath("../Secrets.md") }
        #expect(throws: TGSidianError.self) { try RelativePath("/absolute.md") }
        #expect(throws: TGSidianError.self) { try RelativePath("Notes//Empty.md") }
        #expect(throws: TGSidianError.self) { try RelativePath("Notes/./Dot.md") }
    }

    @Test("local editor preferences have design-backed defaults")
    func safePreferenceDefaults() {
        let preferences = AppPreferences()
        #expect(preferences.appearance == .system)
        #expect(preferences.editorFontSize == 15)
        #expect(preferences.editorLineWidth == 720)
        #expect(preferences.ignorePatterns.isEmpty)
    }

    @Test("restored workspace state clamps dimensions and rejects non-folder disclosure IDs")
    func workspaceStateValidation() throws {
        let note = try RelativePath("Notes/Home.md")
        let state = VaultWorkspaceState(
            sidebarWidth: 4,
            inspectorWidth: 9_000,
            showsInspector: false,
            expandedFolderIDs: ["folder:Notes", "note:Notes/Home.md", "arbitrary"],
            lastOpenNotePath: note
        )

        #expect(state.sidebarWidth == 220)
        #expect(state.inspectorWidth == 360)
        #expect(!state.showsInspector)
        #expect(state.expandedFolderIDs == ["folder:Notes"])
        #expect(state.lastOpenNotePath == note)
    }

    @Test("folder appearances validate and hidden/appearance state survives a JSON round-trip")
    func folderPreferencesPersist() throws {
        // FolderAppearance rejects unknown symbols and malformed hex, degrading to safe defaults.
        #expect(FolderAppearance(symbolName: "not-a-symbol", colorHex: "#526B86").symbolName == "folder")
        #expect(FolderAppearance(symbolName: "star", colorHex: "nonsense").colorHex == "#8E8E96")
        #expect(FolderAppearance(symbolName: "star", colorHex: "526b86").colorHex == "#526B86")

        // Only folder-scoped IDs are retained; note/other IDs are dropped like expandedFolderIDs.
        let state = VaultWorkspaceState(
            hiddenFolderIDs: ["folder:Archive", "note:Archive/x.md"],
            folderAppearances: [
                "folder:Work": FolderAppearance(symbolName: "briefcase", colorHex: "#4C8C4A"),
                "note:Work/y.md": FolderAppearance(symbolName: "star", colorHex: "#B4514E")
            ]
        )
        #expect(state.hiddenFolderIDs == ["folder:Archive"])
        #expect(Array(state.folderAppearances.keys) == ["folder:Work"])

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(VaultWorkspaceState.self, from: data)
        #expect(restored.hiddenFolderIDs == ["folder:Archive"])
        #expect(restored.folderAppearances["folder:Work"]?.symbolName == "briefcase")
        #expect(restored.folderAppearances["folder:Work"]?.colorHex == "#4C8C4A")

        // A state file written before these fields existed decodes without wiping other prefs.
        let legacy = Data(#"{"sidebarWidth":300,"inspectorWidth":300,"showsInspector":true}"#.utf8)
        let migrated = try JSONDecoder().decode(VaultWorkspaceState.self, from: legacy)
        #expect(migrated.hiddenFolderIDs.isEmpty)
        #expect(migrated.folderAppearances.isEmpty)
        #expect(migrated.sidebarWidth == 300)
    }

    @Test("front matter, links, tasks, headings, and tags parse together")
    func markdownParsing() throws {
        let markdown = """
        ---
        title: "A Note"
        type: reading
        tags:
          - Swift
          - local-first
        rating: 5
        unknown: preserve
        ---
        # Heading One

        See [[Architecture#Actors|actor design]] and #Knowledge.

        - [ ] Open task
        - [x] Done task
        """

        let parsed = MarkdownParser().parse(markdown, path: try RelativePath("Notes/Fallback.md"))
        #expect(parsed.title == "A Note")
        #expect(parsed.frontMatter["type"] == .string("reading"))
        #expect(parsed.frontMatter["rating"] == .integer(5))
        #expect(parsed.tags == ["swift", "local-first", "knowledge"])
        #expect(parsed.headings.first?.slug == "heading-one")
        #expect(parsed.links == [WikiLink(rawTarget: "Architecture", heading: "Actors", alias: "actor design", line: 12)])
        #expect(parsed.tasks.map(\.state) == [.todo, .done])
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test("surgical front matter changes preserve body and unknown keys")
    func frontMatterUpdate() throws {
        let original = """
        ---
        title: Old
        unknown-key: preserve-me
        tags:
          - one
          - two
        ---
        Body: do not rewrite this.
        """
        let updated = try MarkdownFormatter.updatingFrontMatter(
            in: original,
            changes: ["title": .string("New: Title"), "status": .string("queued")]
        )
        #expect(updated.contains("title: \"New: Title\""))
        #expect(updated.contains("unknown-key: preserve-me"))
        #expect(updated.contains("tags:\n  - one\n  - two"))
        #expect(updated.hasSuffix("Body: do not rewrite this."))

        let parsed = MarkdownParser().parse(updated)
        #expect(parsed.frontMatter["title"] == .string("New: Title"))
        #expect(parsed.frontMatter["status"] == .string("queued"))
    }

    @Test("invalid front matter remains searchable body with a diagnostic")
    func malformedFrontMatter() {
        let content = "---\ntitle Broken\nBody remains canonical"
        let parsed = MarkdownParser().parse(content)
        #expect(parsed.diagnostics.contains(where: { $0.severity == .error }))
        #expect(parsed.body.contains("Body remains canonical"))
    }
}

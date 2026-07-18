@testable import FeatureUI
import Testing

@Suite("Hotkey catalog")
struct HotkeyCatalogTests {
    @Test("lists every current menu and in-app shortcut in deterministic order")
    func listsRegisteredShortcuts() {
        #expect(HotkeyCatalog.commands.map(\.title) == [
            "Use merged draft",
            "Save extension settings",
            "New Note",
            "Open Vault…",
            "Apply folder icon",
            "Cancel link selection",
            "Complete Wiki Link",
            "Toggle Task",
            "Search Vault",
            "Toggle Inspector",
            "Restore recovered edits",
            "Done",
            "Focus search results",
            "Focus next search result",
            "Focus previous search result",
            "Open selected search result"
        ])
        #expect(HotkeyCatalog.commands.first(where: { $0.title == "Toggle Inspector" })?.keys == "⌥⌘I")
        #expect(HotkeyCatalog.commands.first(where: { $0.title == "Complete Wiki Link" })?.keys == "⌃Esc")
    }

    @Test("matches all whitespace-separated terms across command, menu, and key")
    func filtersByEveryDisplayField() {
        #expect(HotkeyCatalog.commands(matching: "navigate inspector").map(\.title) == ["Toggle Inspector"])
        #expect(HotkeyCatalog.commands(matching: "vault ↓").map(\.title) == ["Focus next search result"])
        #expect(HotkeyCatalog.commands(matching: "merged settings").isEmpty)
    }

    @Test("blank and case-insensitive queries preserve the stable catalog order")
    func searchIsDeterministic() {
        #expect(HotkeyCatalog.commands(matching: "   ") == HotkeyCatalog.commands)
        #expect(HotkeyCatalog.commands(matching: "SEARCH vault").map(\.title) == [
            "Search Vault",
            "Focus next search result",
            "Focus previous search result",
            "Open selected search result"
        ])
    }
}

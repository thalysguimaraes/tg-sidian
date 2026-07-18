import AppCore
import FeatureUI
import Foundation
import IndexKit
import TestSupport
import Testing
import VaultKit

@Suite("Architecture invariants")
struct ArchitectureTests {
    @Test("local module imports point inward and AppCore imports no sibling module")
    func dependencyDirection() throws {
        let root = repositoryRoot()
        let sources = root.appendingPathComponent("Sources")
        let localModules: Set<String> = [
            "AppCore", "InstrumentationKit", "SecurityKit", "MarkdownKit", "VaultKit",
            "IndexKit", "GraphKit", "ExtensionSDK", "FeatureUI", "TestSupport"
        ]
        let allowed: [String: Set<String>] = [
            "AppCore": [],
            "InstrumentationKit": ["AppCore"],
            "SecurityKit": ["AppCore"],
            "MarkdownKit": ["AppCore"],
            "VaultKit": ["AppCore", "MarkdownKit"],
            "IndexKit": ["AppCore", "MarkdownKit", "VaultKit"],
            "GraphKit": ["AppCore", "IndexKit"],
            "ExtensionSDK": ["AppCore"],
            "FeatureUI": [
                "AppCore", "MarkdownKit", "VaultKit", "IndexKit",
                "GraphKit", "SecurityKit", "InstrumentationKit", "ExtensionSDK"
            ],
            "TestSupport": ["AppCore", "MarkdownKit", "VaultKit", "IndexKit", "GraphKit"]
        ]

        for module in localModules.sorted() {
            let directory = sources.appendingPathComponent(module)
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" }
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                let imports = text.split(separator: "\n").compactMap { line -> String? in
                    let parts = line.split(separator: " ")
                    guard parts.count == 2, parts[0] == "import" else { return nil }
                    return String(parts[1])
                }.filter { localModules.contains($0) }
                for imported in imports {
                    #expect(allowed[module, default: []].contains(imported), "\(module) must not import \(imported)")
                }
            }
        }
    }

    @Test("the workspace exposes only design-backed vault navigation")
    func designBackedNavigation() throws {
        let root = repositoryRoot()
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/FeatureUI/SidebarView.swift"),
            encoding: .utf8
        )
        let routes = try String(
            contentsOf: root.appendingPathComponent("Sources/FeatureUI/VaultSessionModel.swift"),
            encoding: .utf8
        )
        for excluded in ["Buying List", "Tools and Bookmarks", "Reading List", "Watches", "Inbox"] {
            #expect(!sidebar.contains(excluded), "Sidebar must not expose tg-inspo destination: \(excluded)")
        }
        for excludedCase in ["case home", "case inbox", "case collection", "case settings"] {
            #expect(!routes.contains(excludedCase), "Route must not expose tg-inspo state: \(excludedCase)")
        }
    }

    @Test("production app target declares sandbox, bookmarks, and complete app icon assets")
    func productionAppConfiguration() throws {
        let root = repositoryRoot()
        let entitlementsURL = root.appendingPathComponent("Sources/TGSidianApp/Resources/TGSidian.entitlements")
        let values = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: entitlementsURL),
            options: [],
            format: nil
        ) as? NSDictionary)
        #expect((values["com.apple.security.app-sandbox"] as? NSNumber)?.boolValue == true)
        #expect((values["com.apple.security.files.bookmarks.app-scope"] as? NSNumber)?.boolValue == true)
        #expect((values["com.apple.security.files.user-selected.read-write"] as? NSNumber)?.boolValue == true)

        let project = try String(
            contentsOf: root.appendingPathComponent("TGSidian.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        #expect(project.contains("TGSidian.entitlements"))
        #expect(project.contains("Assets.xcassets in Resources"))
        #expect(project.contains("XCLocalSwiftPackageReference"))

        // The app icon is an Icon Composer bundle (macOS 26 Liquid Glass format); actool
        // derives every raster size from it, so no appiconset PNGs exist anymore.
        #expect(project.contains("AppIcon.icon in Resources"))
        let iconBundle = root.appendingPathComponent("Sources/TGSidianApp/Resources/AppIcon.icon")
        let definition = iconBundle.appendingPathComponent("icon.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: definition.path)
        #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0)
        var assetsIsDirectory: ObjCBool = false
        let hasAssets = FileManager.default.fileExists(
            atPath: iconBundle.appendingPathComponent("Assets").path,
            isDirectory: &assetsIsDirectory
        )
        #expect(hasAssets && assetsIsDirectory.boolValue)
    }

    @Test("every FeatureUI button uses the native titled accessibility bridge")
    func titledAccessibleButtons() throws {
        let root = repositoryRoot()
        let featureUI = root.appendingPathComponent("Sources/FeatureUI")
        let buttonFiles = [
            "EditorScreen.swift",
            "InspectorView.swift",
            "SharedComponents.swift",
            "SidebarView.swift",
            "WorkspaceView.swift"
        ]

        for filename in buttonFiles {
            let source = try String(
                contentsOf: featureUI.appendingPathComponent(filename),
                encoding: .utf8
            )
            let buttonCount = matchCount(#"\bButton\s*(?:\{|\()"#, in: source)
            let titledBridgeCount = matchCount(#"\.nativeAccessibleButton\s*\("#, in: source)
            #expect(buttonCount > 0, "Expected at least one button in \(filename)")
            #expect(
                buttonCount == titledBridgeCount,
                "Every button in \(filename) must expose a native AXTitle"
            )
        }

        #expect(AccessibilityControlContract.hasUsableLabel("Choose Vault…"))
        #expect(!AccessibilityControlContract.hasUsableLabel("  \n"))
    }

    /// The bridge wraps ~50 controls across all three panes. When it contributed its own size to
    /// the layout it made every wrapped control greedy, so toolbars spread their buttons across
    /// the full width and stacks spread their rows down the full height.
    @Test("the native accessibility bridge stays layout-neutral")
    func accessibilityBridgeDoesNotAffectLayout() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Sources/FeatureUI/NativeAccessibleControl.swift"
            ),
            encoding: .utf8
        )

        #expect(
            matchCount(#"\.overlay\s*\{"#, in: source) == 1,
            "The bridge must overlay the control so it is sized by the content it describes"
        )
        #expect(
            matchCount(#"\bZStack\s*(?:\{|\()"#, in: source) == 0,
            "A ZStack unions the bridge's size into the layout, making wrapped controls greedy"
        )
        #expect(
            matchCount(#"maxWidth:\s*\.infinity"#, in: source) == 0,
            "The bridge must never propose an expanding width"
        )
        #expect(
            matchCount(#"func sizeThatFits"#, in: source) == 1,
            "The NSButton title must not give the bridge an intrinsic size"
        )
    }

    /// Both side panes are peers in the workspace shell. The native leading sidebar already
    /// floats; the flat inspector column needs the explicit trailing floating counterpart.
    @Test("the workspace presents two floating sidebar surfaces")
    func inspectorMatchesSidebarStructure() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Sources/FeatureUI/WorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(matchCount(#"(?<!Floating)SidebarSurface\s*\{"#, in: source) == 1)
        #expect(matchCount(#"FloatingSidebarSurface\s*(?:\{|\()"#, in: source) == 1)
        #expect(source.contains("SidebarView(session: session, onChangeVault: onChangeVault)"))
        #expect(source.contains("InspectorView(session: session, onCollapse: toggleInspector)"))
        #expect(!source.contains("private var inspectorPanel"))
        #expect(!source.contains(".inspector(isPresented:"))
        #expect(source.contains("ZStack(alignment: .trailing)"))
        #expect(source.contains("leadingChromeInset: editorChromeLeadingInset"))
        #expect(source.contains("trailingChromeInset: editorChromeTrailingInset"))
        #expect(source.contains(".frame(width: editorChromeLeadingInset)"))
        #expect(source.contains(".frame(width: editorChromeTrailingInset)"))

        let editor = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Sources/FeatureUI/EditorScreen.swift"
            ),
            encoding: .utf8
        )
        #expect(editor.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
    }

    @Test("split layout rejects zero, non-finite, and collapsed sidebar widths")
    func validSplitWidths() {
        #expect(WorkspaceSplitLayout.sidebarWidth(0) == 220)
        #expect(WorkspaceSplitLayout.sidebarWidth(-200) == 220)
        #expect(WorkspaceSplitLayout.sidebarWidth(.nan) == 292)
        #expect(WorkspaceSplitLayout.inspectorWidth(0) == 250)

        let defaultPositions = WorkspaceSplitLayout.dividerPositions(
            totalWidth: 1_440,
            dividerThickness: 1,
            sidebarWidth: 0,
            inspectorWidth: 0,
            showsInspector: true
        )
        #expect(defaultPositions.sidebar == 220)
        #expect(defaultPositions.inspector == 1_189)

        let minimumWindowPositions = WorkspaceSplitLayout.dividerPositions(
            totalWidth: 1_000,
            dividerThickness: 1,
            sidebarWidth: 292,
            inspectorWidth: 292,
            showsInspector: true
        )
        #expect(minimumWindowPositions.sidebar >= 220)
        #expect(minimumWindowPositions.inspector.map { $0 > minimumWindowPositions.sidebar } == true)
    }

    /// Width is only worth spending where content can use it. The inspector's calendar stops
    /// improving once its seven columns are comfortable, so it must not out-grow the tree or
    /// claim width the editor could give to prose.
    @Test("side panes cap proportional to their content, and the editor takes the slack")
    func panesCapProportionalToContent() {
        #expect(WorkspaceSplitLayout.maximumInspectorWidth < WorkspaceSplitLayout.maximumSidebarWidth)
        #expect(WorkspaceSplitLayout.inspectorWidth(420) == WorkspaceSplitLayout.maximumInspectorWidth)

        // On a wide window every point beyond the side-pane caps belongs to the editor.
        let wide = WorkspaceSplitLayout.dividerPositions(
            totalWidth: 2_600,
            dividerThickness: 1,
            sidebarWidth: 999,
            inspectorWidth: 999,
            showsInspector: true
        )
        let sidebar = wide.sidebar
        let inspector = 2_600 - (wide.inspector ?? 0) - 1
        let editor = 2_600 - sidebar - inspector - 2
        #expect(sidebar == WorkspaceSplitLayout.maximumSidebarWidth)
        #expect(inspector == WorkspaceSplitLayout.maximumInspectorWidth)
        #expect(editor > sidebar + inspector, "The editor takes the slack on a wide window")
    }

    /// The design shows folders A-Z while Daily Notes runs 2026-07-15, -14, -13 — newest first.
    /// The sidebar displays filenames, so a folder of notes that all carry the front-matter title
    /// "Daily Journal" must still read as distinct, ordered dates.
    @Test("the default sidebar order is date-aware newest-first on filenames")
    func dateAwareSortOrder() throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        func note(_ path: String, title: String = "Daily Journal", modifiedAt: Date = modified) throws -> NoteSummary {
            let relative = try RelativePath(path)
            return NoteSummary(
                id: NoteID(path: relative),
                path: relative,
                title: title,
                tags: [],
                type: nil,
                modifiedAt: modifiedAt
            )
        }

        let tree = SidebarNode.tree(from: [
            try note("Daily Notes/2026-07-14.md"),
            try note("Daily Notes/2026-07-16.md"),
            try note("Daily Notes/2026-07-15.md"),
            try note("Daily Notes/Inbox.md", title: "Inbox"),
            try note("Agent Notes/zeta.md", title: "Zeta"),
            try note("Agent Notes/alpha.md", title: "Alpha")
        ])

        // Folders stay alphabetical; a folder has no date to sort on.
        #expect(tree.map(\.name) == ["Agent Notes", "Daily Notes"])

        let agentNotes = try #require(tree.first { $0.name == "Agent Notes" })
        #expect(agentNotes.children.map(\.name) == ["alpha", "zeta"])

        let dailyNotes = try #require(tree.first { $0.name == "Daily Notes" })
        #expect(
            dailyNotes.children.map(\.name) == ["2026-07-16", "2026-07-15", "2026-07-14", "Inbox"],
            "Date-named notes lead newest-first; undated siblings follow"
        )

        // The front-matter title is identical across these notes; the filename is what shows.
        #expect(!dailyNotes.children.contains { $0.name == "Daily Journal" })
    }

    @Test("explicit sidebar orders override the date-aware default")
    func explicitSortOrders() throws {
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        let a = SidebarSortKey(name: "2026-07-14", modifiedAt: new)
        let b = SidebarSortKey(name: "2026-07-16", modifiedAt: old)

        #expect(SidebarSorting.compare(b, a, using: .dateAwareNewestFirst))
        #expect(SidebarSorting.compare(a, b, using: .nameAscending))
        #expect(SidebarSorting.compare(b, a, using: .nameDescending))
        #expect(SidebarSorting.compare(a, b, using: .modifiedNewestFirst))
        #expect(SidebarSorting.compare(b, a, using: .modifiedOldestFirst))

        // Only a full YYYY-MM-DD prefix counts as a date.
        #expect(SidebarSortKey(name: "2026-07-16", modifiedAt: new).datePrefix == "2026-07-16")
        #expect(SidebarSortKey(name: "2026-7-16", modifiedAt: new).datePrefix == nil)
        #expect(SidebarSortKey(name: "Inbox", modifiedAt: new).datePrefix == nil)
        #expect(SidebarSortKey(name: "2026-07-16 standup", modifiedAt: new).datePrefix == "2026-07-16")
    }

    @Test("deterministic generated fixture rebuilds to the requested note count")
    func generatedFixture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-generated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FixtureVaultGenerator.generate(at: root, noteCount: 250, seed: 42)
        let vault = try VaultActor(rootURL: root)
        let index = IndexActor()
        let report = try await index.rebuild(from: vault)
        #expect(report.indexedCount == 250)
        #expect(await index.search(.init(query: "Note 249")).first?.note.title == "Note 249")
    }

    private func matchCount(_ pattern: String, in source: String) -> Int {
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression?.numberOfMatches(in: source, range: range) ?? 0
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

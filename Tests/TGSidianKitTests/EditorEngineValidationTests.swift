import AppCore
import AppKit
@testable import FeatureUI
import Foundation
import SwiftUI
import TestSupport
import Testing
import VaultKit

@Suite("Native editor engine", .serialized)
@MainActor
struct EditorEngineValidationTests {
    @Test("IME marked text is preserved until an external replacement can apply safely")
    func markedTextDefersExternalReplacement() throws {
        let (surface, textView, _) = makeSurface()
        surface.replaceBuffer("prefix ", preservingSelectionWhenPossible: false)
        surface.selection = 7..<7

        textView.setMarkedText(
            NSAttributedString(string: "かな"),
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.hasMarkedText())

        surface.replaceBuffer("external replacement", preservingSelectionWhenPossible: true)
        #expect(surface.hasDeferredReplacement)
        #expect(textView.string != "external replacement")

        textView.unmarkText()
        #expect(surface.flushDeferredReplacementIfPossible())
        #expect(!surface.hasDeferredReplacement)
        #expect(surface.text == "external replacement")
    }

    @Test("selection survives external buffers and clamps in UTF-16 space")
    func selectionAndExternalReplacement() {
        let (surface, _, _) = makeSurface()
        surface.replaceBuffer("alpha beta gamma", preservingSelectionWhenPossible: false)
        surface.selection = 6..<10

        surface.replaceBuffer("alpha BETA gamma delta", preservingSelectionWhenPossible: true)
        #expect(surface.selection == 6..<10)
        #expect(surface.text == "alpha BETA gamma delta")

        surface.replaceBuffer("短", preservingSelectionWhenPossible: true)
        #expect(surface.selection == 1..<1)
        surface.replaceBuffer("reset", preservingSelectionWhenPossible: false)
        #expect(surface.selection == 0..<0)
    }

    @Test("native undo manager groups a compound edit")
    func undoGrouping() throws {
        let (surface, textView, scrollView) = makeSurface()
        let window = makeWindow(containing: scrollView)
        #expect(window.makeFirstResponder(textView))
        surface.replaceBuffer("", preservingSelectionWhenPossible: false)

        let undoManager = try #require(textView.undoManager)
        undoManager.removeAllActions()
        undoManager.beginUndoGrouping()
        textView.insertText("one", replacementRange: textView.selectedRange())
        textView.insertText(" two", replacementRange: textView.selectedRange())
        undoManager.endUndoGrouping()

        #expect(textView.string == "one two")
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(textView.string.isEmpty)
    }

    @Test("Find, spellcheck, Writing Tools, and VoiceOver use native services")
    func nativeServicesAndAccessibility() {
        let (surface, textView, _) = makeSurface()
        let appOwnedSurface: any EditorSurface = surface
        #expect(appOwnedSurface.text.isEmpty)
        // Live preview pins the TextKit 1 stack: marker concealment needs the classic
        // layout manager's `.null`-glyph hook (ADR-0002 amendment).
        #expect(textView.layoutManager is ConcealingLayoutManager)
        #expect(textView.usesFindBar)
        #expect(textView.isIncrementalSearchingEnabled)
        #expect(textView.isContinuousSpellCheckingEnabled)
        #expect(textView.isGrammarCheckingEnabled)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(textView.accessibilityLabel() == "Note editor")
        #expect(textView.accessibilityRoleDescription() == "Markdown source editor")

        if #available(macOS 15.0, *) {
            #expect(textView.writingToolsBehavior == .complete)
            #expect(textView.allowedWritingToolsResultOptions == .plainText)
        }
    }

    @Test("appearance and focus events cross the adapter boundary")
    func appearanceAndFocus() {
        let (surface, textView, scrollView) = makeSurface()
        var appearanceChanges = 0
        var focusChanges: [Bool] = []
        surface.onAppearanceChange = { appearanceChanges += 1 }
        surface.onFocusChange = { focusChanges.append($0) }

        textView.viewDidChangeEffectiveAppearance()
        #expect(appearanceChanges == 1)

        let window = makeWindow(containing: scrollView)
        surface.requestFocus()
        #expect(window.firstResponder === textView)
        #expect(focusChanges.last == true)
        surface.resignFocus()
        #expect(window.firstResponder !== textView)
        #expect(focusChanges.last == false)
    }

    @Test("wiki links, tasks, and complete code fences retain source markup")
    func markdownInteractions() {
        let markdown = """
        # Harness
        Open [[Notes/Editor#Focus|the editor]].
        - [ ] Exercise IME
        - [x] Verify Find
        ```swift
        let source = "raw"
        ```
        """
        let highlighter = MarkdownHighlighter()
        let ranges = highlighter.scan(markdown)

        #expect(highlighter.wikiLinkTarget(in: markdown, at: 20) == "Notes/Editor")
        #expect(ranges.filter { $0.kind == .task }.count == 2)
        let fence = ranges.first { $0.kind == .codeFence }
        #expect(fence != nil)
        if let fence {
            #expect((markdown as NSString).substring(with: fence.range).contains("let source"))
        }
        #expect(EditorHostView.Coordinator.listContinuation(for: "- [x] done\n") == "- [ ] ")
        #expect(EditorHostView.Coordinator.listContinuation(for: "- [ ] \n") == "")
    }

    @Test("a one-megabyte Markdown note loads and styles within the validation budget")
    func oneMegabyteNotePerformance() {
        let (surface, textView, _) = makeSurface()
        let line = "- [ ] Validate [[Editor]] with `code` and searchable prose.\n"
        let byteTarget = 1_048_576
        let repeated = String(repeating: line, count: byteTarget / line.utf8.count + 1)
        let note = String(repeated.prefix(byteTarget))
        #expect(note.utf8.count == byteTarget)

        let clock = ContinuousClock()
        let start = clock.now
        surface.replaceBuffer(note, preservingSelectionWhenPossible: false)
        NativeMarkdownStyler.apply(to: textView, fontSize: 15, lineWidth: 720)
        let elapsed = start.duration(to: clock.now)
        let milliseconds = Self.milliseconds(elapsed)

        #expect(textView.string.utf8.count == byteTarget)
        #expect(textView.textStorage?.length == byteTarget)
        #expect(milliseconds < 5_000, "1 MB load/style took \(milliseconds) ms")
        print("PENTA-137 metric: 1MiB load+style = \(String(format: "%.2f", milliseconds)) ms")
    }

    @Test("a one-megabyte buffer keeps native edit dispatch below the keystroke budget")
    func oneMegabyteKeystrokePerformance() async throws {
        let line = "- [ ] Validate [[Editor]] with `code` and searchable prose.\n"
        let byteTarget = 1_048_576
        let note = String(String(
            repeating: line,
            count: byteTarget / line.utf8.count + 1
        ).prefix(byteTarget))
        let temporary = try TemporaryVault(emptyNamed: "editor-keystroke")
        try temporary.directWrite(note, to: "Editor.md")
        let path = try RelativePath("Editor.md")
        let initial = try await temporary.vault.read(path)
        let journal = try RecoveryJournal(
            directory: temporary.rootURL.appendingPathComponent(".recovery", isDirectory: true)
        )
        let document = EditorDocumentModel(
            vault: temporary.vault,
            saveCoordinator: SaveCoordinator(vault: temporary.vault, journal: journal)
        )
        document.open(initial)

        let surface = NativeEditorSurfaceAdapter()
        let host = NSHostingView(rootView: EditorHostView(
            document: document,
            fontSize: 15,
            lineWidth: 720,
            surface: surface,
            onFollowWikiLink: { _ in }
        ))
        let window = makeWindow(containing: host)
        host.layoutSubtreeIfNeeded()
        spinRunLoop(until: { surface.isAttached })
        surface.requestFocus()
        let textView = try #require(window.firstResponder as? MarkdownTextView)
        surface.selection = 32..<32

        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = clock.now
            textView.insertText("x", replacementRange: textView.selectedRange())
            samples.append(Self.milliseconds(start.duration(to: clock.now)))
        }
        samples.sort()
        let p95 = samples[18]
        // GitHub's shared macOS runners have materially noisier scheduling than a
        // release Mac. Keep the interactive 16 ms gate locally while retaining a
        // bounded regression check in CI.
        let budget = ProcessInfo.processInfo.environment["CI"] == "true" ? 40.0 : 16.0
        #expect(p95 < budget, "1 MiB edit dispatch p95 took \(p95) ms (budget: \(budget) ms)")
        print("PENTA-137 metric: 1MiB keystroke dispatch p95 = \(String(format: "%.2f", p95)) ms")
        document.close()
    }

    @Test("SwiftUI host installs the adapter, transfers focus, and adopts a model refresh")
    func swiftUIAppKitBridge() async throws {
        let temporary = try TemporaryVault(emptyNamed: "editor-engine")
        try temporary.directWrite("# Initial\n\nSelection anchor", to: "Editor.md")
        let path = try RelativePath("Editor.md")
        let initial = try await temporary.vault.read(path)
        let journal = try RecoveryJournal(
            directory: temporary.rootURL.appendingPathComponent(".recovery", isDirectory: true)
        )
        let document = EditorDocumentModel(
            vault: temporary.vault,
            saveCoordinator: SaveCoordinator(vault: temporary.vault, journal: journal)
        )
        document.open(initial)

        let surface = NativeEditorSurfaceAdapter()
        let host = NSHostingView(rootView: EditorHostView(
            document: document,
            fontSize: 15,
            lineWidth: 720,
            surface: surface,
            onFollowWikiLink: { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spinRunLoop(until: { surface.isAttached })
        #expect(surface.isAttached)
        #expect(surface.text == initial.content)

        surface.selection = 2..<9
        surface.requestFocus()
        #expect(window.firstResponder is MarkdownTextView)

        let refreshedText = "# External\n\nSelection anchor and more"
        let refreshed = try await temporary.vault.atomicWrite(
            refreshedText,
            to: path,
            expectedFingerprint: initial.fingerprint
        )
        document.open(refreshed)
        spinRunLoop(until: { surface.text == refreshedText })
        #expect(surface.text == refreshedText)
        #expect(surface.selection == 2..<9)
    }

    @Test("feature code contains third-party editor types behind the app-owned adapter only")
    func adapterBoundary() throws {
        let root = repositoryRoot()
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let host = try String(
            contentsOf: root.appendingPathComponent(
                "Packages/TGSidianKit/Sources/FeatureUI/MarkdownTextView.swift"
            ),
            encoding: .utf8
        )
        let adapter = try String(
            contentsOf: root.appendingPathComponent(
                "Packages/TGSidianKit/Sources/FeatureUI/EditorSurfaceAdapter.swift"
            ),
            encoding: .utf8
        )

        #expect(!package.contains("swift-markdown-engine"))
        #expect(!package.contains("STTextView"))
        #expect(host.contains("NativeEditorSurfaceAdapter"))
        #expect(adapter.contains("NativeEditorSurfaceAdapter: EditorSurface"))
    }

    private func makeSurface() -> (
        surface: NativeEditorSurfaceAdapter,
        textView: MarkdownTextView,
        scrollView: NSScrollView
    ) {
        _ = NSApplication.shared
        let surface = NativeEditorSurfaceAdapter()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let textView = surface.install(in: scrollView)
        textView.frame = scrollView.bounds
        return (surface, textView, scrollView)
    }

    private func makeWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        return window
    }

    private func spinRunLoop(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

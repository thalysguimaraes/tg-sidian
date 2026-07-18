import AppKit
@testable import FeatureUI
import Foundation
import Testing

@Suite("Live preview concealment", .serialized)
@MainActor
struct LivePreviewTests {
    // MARK: - Scanner

    @Test("heading markers conceal the prefix and keep the title visible")
    func headingMarkers() {
        let text = "## Section title\nBody"
        let ns = text as NSString
        let concealment = LivePreviewConcealment.scan(text)
        let heading = concealment.elements.first { $0.kind == .heading(level: 2) }
        #expect(heading != nil)
        if let heading {
            #expect(heading.markers.map { ns.substring(with: $0) } == ["## "])
            #expect(ns.substring(with: heading.visible) == "Section title")
        }
    }

    @Test("wiki links show the alias and resolve the target before # and |")
    func wikiLinkAlias() {
        let text = "Open [[Notes/Editor#Focus|the editor]] now, plus [[Plain]]."
        let ns = text as NSString
        let concealment = LivePreviewConcealment.scan(text)
        let links = concealment.elements.filter {
            if case .wikiLink = $0.kind { return true } else { return false }
        }
        #expect(links.count == 2)

        if case let .wikiLink(target) = links[0].kind {
            #expect(target == "Notes/Editor")
        }
        #expect(ns.substring(with: links[0].visible) == "the editor")
        #expect(links[0].markers.map { ns.substring(with: $0) } == ["[[Notes/Editor#Focus|", "]]"])

        if case let .wikiLink(target) = links[1].kind {
            #expect(target == "Plain")
        }
        #expect(ns.substring(with: links[1].visible) == "Plain")
        #expect(links[1].markers.map { ns.substring(with: $0) } == ["[[", "]]"])
    }

    @Test("markdown links show the label and conceal the destination")
    func markdownLink() {
        let text = "See [the docs](https://example.com/guide)."
        let ns = text as NSString
        let concealment = LivePreviewConcealment.scan(text)
        let link = concealment.elements.first {
            if case .markdownLink = $0.kind { return true } else { return false }
        }
        #expect(link != nil)
        if let link {
            if case let .markdownLink(destination) = link.kind {
                #expect(destination == "https://example.com/guide")
            }
            #expect(ns.substring(with: link.visible) == "the docs")
            #expect(link.markers.map { ns.substring(with: $0) } == ["[", "](https://example.com/guide)"])
        }
    }

    @Test("emphasis, strikethrough, and inline code conceal their delimiters")
    func inlineEmphasis() {
        let text = "Mix **bold**, *italic*, ~~gone~~, and `code` here."
        let ns = text as NSString
        let concealment = LivePreviewConcealment.scan(text)
        let byKind = { (kind: LivePreviewConcealment.Kind) in
            concealment.elements.first { $0.kind == kind }.map { ns.substring(with: $0.visible) }
        }
        #expect(byKind(.bold) == "bold")
        #expect(byKind(.italic) == "italic")
        #expect(byKind(.strikethrough) == "gone")
        #expect(byKind(.inlineCode) == "code")
    }

    @Test("list bullets never pair with a later asterisk as italic")
    func bulletIsNotItalic() {
        let concealment = LivePreviewConcealment.scan("* item one with a lone * star\n* item two\n")
        #expect(concealment.elements.isEmpty)
    }

    @Test("thematic breaks conceal the whole line and mark a horizontal rule")
    func thematicBreaks() {
        let text = "above\n---\n***\n___\n----  \nnot -- a rule\n*emph* stays\n"
        let ns = text as NSString
        let concealment = LivePreviewConcealment.scan(text)
        let rules = concealment.elements.filter { $0.kind == .horizontalRule }
        #expect(rules.count == 4)
        for rule in rules {
            #expect(rule.markers == [rule.range], "the entire break line is concealed")
        }
        #expect(ns.substring(with: rules[0].range) == "---")
        #expect(ns.substring(with: rules[3].range) == "----  ")
        // `***`/`___` lines are rules, not emphasis; real emphasis elsewhere still parses.
        #expect(concealment.elements.contains { $0.kind == .italic })
        #expect(!concealment.elements.contains { $0.kind == .bold })
    }

    @Test("front matter delimiters are not horizontal rules")
    func frontMatterIsNotARule() {
        let text = "---\ntitle: x\n---\nBody\n"
        let exclusions = MarkdownHighlighter().scan(text)
            .filter { $0.kind == .frontMatter }
            .map(\.range)
        let concealment = LivePreviewConcealment.scan(text, excluding: exclusions)
        #expect(!concealment.elements.contains { $0.kind == .horizontalRule })
    }

    @Test("code fences and front matter stay literal")
    func exclusionsStayLiteral() {
        let text = """
        ---
        title: **not bold**
        ---
        ```
        ## not a heading, [[not a link]]
        ```
        Real **bold**.
        """
        let highlighter = MarkdownHighlighter()
        let exclusions = highlighter.scan(text)
            .filter { $0.kind == .frontMatter || $0.kind == .codeFence }
            .map(\.range)
        let concealment = LivePreviewConcealment.scan(text, excluding: exclusions)
        #expect(concealment.elements.count == 1)
        #expect(concealment.elements.first?.kind == .bold)
    }

    @Test("emphasis inside inline code loses to the code span")
    func codeBeatsEmphasis() {
        let concealment = LivePreviewConcealment.scan("Use `let **x** = 1` verbatim.")
        #expect(concealment.elements.count == 1)
        #expect(concealment.elements.first?.kind == .inlineCode)
    }

    @Test("emphasis inside a heading title still renders")
    func headingAllowsInlineEmphasis() {
        let concealment = LivePreviewConcealment.scan("# Title with **weight**\n")
        #expect(concealment.elements.contains { $0.kind == .heading(level: 1) })
        #expect(concealment.elements.contains { $0.kind == .bold })
    }

    @Test("reusing highlighter ranges is exactly equivalent to independent scanning")
    func reusedHighlighterRangesAreEquivalent() {
        let text = """
        ---
        title: **literal front matter**
        ---
        # Heading with **weight**
        - [x] Task with [[Folder/Target#Part|alias]] and [docs](https://example.com)
        Mix *italic*, __bold__, ~~gone~~, `inline **literal**`, and #tag.
        ---
        ```
        ## literal fence [[not a link]]
        ```
        """
        let styledRanges = MarkdownHighlighter().scan(text)
        let exclusions = styledRanges
            .filter { $0.kind == .frontMatter || $0.kind == .codeFence }
            .map(\.range)

        let independent = LivePreviewConcealment.scan(text, excluding: exclusions)
        let reused = LivePreviewConcealment.scan(
            text,
            excluding: exclusions,
            reusing: styledRanges
        )

        #expect(reused == independent)
    }

    // MARK: - Surface behavior

    @Test("markers are concealed away from the caret and revealed on its line")
    func concealAndReveal() throws {
        let (textView, layoutManager) = try makeStyledSurface(
            text: "## Title\nBody [[Note|alias]] tail\n",
            caret: 0
        )
        // Caret on line one: the heading marker is revealed, the wiki markers concealed.
        let concealedWidth = lineWidth(ofLineContaining: 10, textView: textView, layoutManager: layoutManager)

        let ns = textView.string as NSString
        let lineTwoStart = ns.range(of: "Body").location
        textView.setSelectedRange(NSRange(location: lineTwoStart, length: 0))
        textView.updateConcealmentReveal()
        let revealedWidth = lineWidth(ofLineContaining: 10, textView: textView, layoutManager: layoutManager)

        #expect(revealedWidth > concealedWidth + 1, "revealing `[[Note|` and `]]` must widen the line")
        #expect(layoutManager.revealedRange == ns.lineRange(for: NSRange(location: lineTwoStart, length: 0)))
    }

    @Test("rendered wiki links are clickable; the revealed line is editable source")
    func linkAttributeFollowsReveal() throws {
        let (textView, _) = try makeStyledSurface(
            text: "## Title\nBody [[Note|alias]] tail\n",
            caret: 0
        )
        let ns = textView.string as NSString
        let aliasIndex = ns.range(of: "alias").location
        let storage = try #require(textView.textStorage)

        // Caret on the heading line: the wiki link renders as a friendly link.
        #expect(storage.attribute(.link, at: aliasIndex, effectiveRange: nil) as? String == "Note")

        // Caret moves onto the link's line: raw source is editable, no link hijacks the click.
        textView.setSelectedRange(NSRange(location: aliasIndex, length: 0))
        textView.updateConcealmentReveal()
        #expect(storage.attribute(.link, at: aliasIndex, effectiveRange: nil) == nil)
    }

    @Test("the styler sets typing attributes so the caret uses editor metrics")
    func caretTypingAttributes() throws {
        let (textView, _) = try makeStyledSurface(text: "plain body\n", caret: 0)
        let font = try #require(textView.typingAttributes[.font] as? NSFont)
        #expect(font.pointSize == 15)
        #expect(textView.font == font)
        #expect(textView.insertionPointColor == NSColor.controlAccentColor)
    }

    @Test("edits shift concealed markers until the restyle catches up")
    func editShiftsMarkers() throws {
        let (textView, layoutManager) = try makeStyledSurface(
            text: "lead\n**bold** tail\n",
            caret: 0
        )
        let ns = textView.string as NSString
        let boldStart = ns.range(of: "**bold**").location

        // Insert ahead of the element without restyling; concealment must follow the shift.
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "xx")
        let expected = NSRange(location: boldStart + 2, length: 2)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: expected.location)
        #expect(layoutManager.propertyForGlyph(at: glyphIndex) == .null)
    }

    // MARK: - Helpers

    private func makeStyledSurface(
        text: String,
        caret: Int
    ) throws -> (MarkdownTextView, ConcealingLayoutManager) {
        _ = NSApplication.shared
        let surface = NativeEditorSurfaceAdapter()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let textView = surface.install(in: scrollView)
        textView.frame = scrollView.bounds
        surface.replaceBuffer(text, preservingSelectionWhenPossible: false)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        NativeMarkdownStyler.apply(to: textView, fontSize: 15, lineWidth: 720)
        let layoutManager = try #require(textView.concealingLayoutManager)
        return (textView, layoutManager)
    }

    private func lineWidth(
        ofLineContaining characterIndex: Int,
        textView: MarkdownTextView,
        layoutManager: ConcealingLayoutManager
    ) -> CGFloat {
        let ns = textView.string as NSString
        let line = ns.lineRange(for: NSRange(location: characterIndex, length: 0))
        layoutManager.ensureLayout(forCharacterRange: line)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: line,
            actualCharacterRange: nil
        )
        let fragment = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        return fragment.width
    }
}

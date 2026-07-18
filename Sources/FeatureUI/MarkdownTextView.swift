import AppCore
import AppKit
import ExtensionSDK
import MarkdownKit
import SwiftUI

/// Syntax ranges for source-mode highlighting (SPEC §9.1: markers stay visible, with
/// syntax-aware colour and weight). Computed from text without mutating the backing string
/// (SPEC §9.2).
public struct MarkdownHighlighter: Sendable {
    public init() {}

    public enum Kind: Hashable, Sendable {
        case heading(level: Int)
        case frontMatter
        case codeFence
        case task
        case wikiLink
        case markdownLink
        case tag
    }

    public struct StyledRange: Hashable, Sendable {
        public let range: NSRange
        public let kind: Kind

        public init(range: NSRange, kind: Kind) {
            self.range = range
            self.kind = kind
        }
    }

    /// A lexical scan, not a full parse: SPEC §9.2 wants immediate delimiter colouring while a
    /// full parse is pending, and this runs on every keystroke.
    public func scan(_ text: String) -> [StyledRange] {
        var result: [StyledRange] = []
        let ns = text as NSString

        // Front matter: only when the document opens with a delimiter (SPEC §9.2).
        if ns.hasPrefix("---\n") || ns.hasPrefix("---\r\n") {
            let searchStart = 3
            let closing = ns.range(
                of: "\n---",
                options: [],
                range: NSRange(location: searchStart, length: ns.length - searchStart)
            )
            if closing.location != NSNotFound {
                result.append(StyledRange(
                    range: NSRange(location: 0, length: closing.location + closing.length),
                    kind: .frontMatter
                ))
            }
        }

        var lineStart = 0
        var openFence: (marker: String, location: Int)?
        while lineStart < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            let fenceMarker: String? = if trimmed.hasPrefix("```") {
                "```"
            } else if trimmed.hasPrefix("~~~") {
                "~~~"
            } else {
                nil
            }

            if let activeFence = openFence {
                if fenceMarker == activeFence.marker {
                    result.append(StyledRange(
                        range: NSRange(
                            location: activeFence.location,
                            length: NSMaxRange(lineRange) - activeFence.location
                        ),
                        kind: .codeFence
                    ))
                    openFence = nil
                }
            } else if let fenceMarker {
                openFence = (fenceMarker, lineRange.location)
            } else if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).first == " " {
                    result.append(StyledRange(range: lineRange, kind: .heading(level: level)))
                }
            }

            lineStart = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        if let openFence {
            result.append(StyledRange(
                range: NSRange(location: openFence.location, length: ns.length - openFence.location),
                kind: .codeFence
            ))
        }

        result.append(contentsOf: matches(
            in: ns,
            pattern: #"(?m)^\s*[-*+]\s+\[[ xX]\]"#,
            kind: .task
        ))
        result.append(contentsOf: matches(in: ns, pattern: #"\[\[[^\]\n]+\]\]"#, kind: .wikiLink))
        result.append(contentsOf: matches(in: ns, pattern: #"\[[^\]\n]*\]\([^)\n]*\)"#, kind: .markdownLink))
        result.append(contentsOf: matches(in: ns, pattern: #"(?<![\w/])#[A-Za-z][\w/-]*"#, kind: .tag))
        return result
    }

    private func matches(in ns: NSString, pattern: String, kind: Kind) -> [StyledRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex
            .matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
            .map { StyledRange(range: $0.range, kind: kind) }
    }

    /// The wiki-link target under `location`, if any. Used for click-to-follow (SPEC §6.3).
    public func wikiLinkTarget(in text: String, at location: Int) -> String? {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#) else { return nil }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard NSLocationInRange(location, match.range), match.numberOfRanges > 1 else { continue }
            let inner = ns.substring(with: match.range(at: 1))
            // `[[Note#Heading|Alias]]` — the target is the part before `#` or `|`.
            let target = inner.split(separator: "|").first.map(String.init) ?? inner
            return target.split(separator: "#").first.map(String.init) ?? target
        }
        return nil
    }
}

/// An `NSTextView` subclass that reports wiki-link clicks and keeps native behaviours intact.
///
/// SPEC §8.5 rejects web-view editors; SPEC §9.1 requires native selection, undo, copy/paste,
/// drag/drop, Services, spellcheck, substitutions, and Find — all of which come from
/// `NSTextView` and are lost the moment the text surface is reimplemented.
public final class MarkdownTextView: NSTextView {
    public var onFollowWikiLink: ((String) -> Void)?
    public var linkCompletionInsertion: (String) -> String = { "[[\($0)]]" }
    public var onFocusChange: ((Bool) -> Void)?
    public var onAppearanceChange: (() -> Void)?
    private let highlighter = MarkdownHighlighter()

    /// Live-preview elements last computed by the styler. Owned here so caret-line reveals can
    /// re-apply `.link` attributes without a full restyle.
    var concealment: LivePreviewConcealment = .empty {
        didSet {
            linkElements = concealment.elements.filter {
                switch $0.kind {
                case .wikiLink, .markdownLink: true
                default: false
                }
            }
        }
    }

    /// Link elements only, sorted and non-overlapping, so the per-keystroke reveal pass can
    /// binary-search instead of scanning every element (the 1 MiB keystroke budget depends
    /// on this).
    private var linkElements: [LivePreviewConcealment.Element] = []

    var concealingLayoutManager: ConcealingLayoutManager? {
        layoutManager as? ConcealingLayoutManager
    }

    /// The line(s) whose markers are revealed: the caret's line, extended over the selection.
    private var revealTargetRange: NSRange {
        let ns = string as NSString
        var selection = selectedRange()
        selection.location = min(selection.location, ns.length)
        selection.length = min(selection.length, ns.length - selection.location)
        return ns.lineRange(for: selection)
    }

    /// Publishes fresh concealment state after a restyle: marker set, revealed line, and the
    /// friendly-link attributes over the whole document.
    func applyConcealment() {
        guard let manager = concealingLayoutManager else { return }
        let rules = concealment.elements
            .filter { $0.kind == .horizontalRule }
            .map(\.range)
        let tokens: [ConcealingLayoutManager.InlineToken] = concealment.elements.compactMap {
            guard $0.kind == .inlineToken, let token = $0.inlineToken else { return nil }
            return ConcealingLayoutManager.InlineToken(
                location: token.carrierRange.location,
                glyph: token.glyph,
                fontName: token.fontName
            )
        }
        manager.setConcealedMarkers(concealment.markers, rules: rules, tokens: tokens)
        manager.updateRevealedRange(revealTargetRange)
        applyLinkAttributes(in: NSRange(location: 0, length: (string as NSString).length))
    }

    /// Moves the reveal to the caret's current line. Cheap: only the previous and new lines
    /// regenerate glyphs and link attributes.
    func updateConcealmentReveal() {
        guard let manager = concealingLayoutManager else { return }
        let revealed = revealTargetRange
        let previous = manager.revealedRange
        guard revealed != previous else { return }
        manager.updateRevealedRange(revealed)
        applyLinkAttributes(in: previous)
        applyLinkAttributes(in: revealed)
    }

    /// Obsidian behavior: a rendered link is clickable (pointing hand, plain click follows);
    /// on the revealed line the raw source is editable, so the `.link` attribute comes off.
    private func applyLinkAttributes(in range: NSRange) {
        guard let storage = textStorage, range.location != NSNotFound else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        let revealed = concealingLayoutManager?.revealedRange
            ?? NSRange(location: NSNotFound, length: 0)
        // Binary search for the first link that could intersect `clamped`; link elements are
        // sorted and non-overlapping, so NSMaxRange is monotonic.
        var low = 0
        var high = linkElements.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(linkElements[mid].range) <= clamped.location {
                low = mid + 1
            } else {
                high = mid
            }
        }

        storage.beginEditing()
        storage.removeAttribute(.link, range: clamped)
        for element in linkElements[low...].prefix(while: { $0.range.location < NSMaxRange(clamped) }) {
            guard revealed.location == NSNotFound
                || NSIntersectionRange(element.range, revealed).length == 0,
                NSMaxRange(element.visible) <= storage.length
            else { continue }
            switch element.kind {
            case let .wikiLink(target):
                storage.addAttribute(.link, value: target, range: element.visible)
            case let .markdownLink(destination):
                if let url = URL(string: destination), url.scheme != nil {
                    storage.addAttribute(.link, value: url, range: element.visible)
                }
            default:
                break
            }
        }
        storage.endEditing()
    }

    /// The default insertion point spans the whole 1.6-leading line fragment. Obsidian's caret
    /// hugs the glyphs, so size it to the typing font and anchor it on the baseline.
    public override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: clamped(caretRect(for: rect), within: rect), color: color, turnedOn: flag)
    }

    /// Slightly taller than the glyph box (Obsidian's caret breathes past the x-height box),
    /// scaled around the baseline so ascent and descent grow proportionally.
    private static let caretHeightScale: CGFloat = 1.15

    private func caretRect(for rect: NSRect) -> NSRect {
        guard let font = typingAttributes[.font] as? NSFont else { return rect }
        let ascent = font.ascender * Self.caretHeightScale
        let descent = font.descender * Self.caretHeightScale
        let height = ascent - descent
        guard height > 0, height < rect.height else { return rect }
        var caret = rect
        caret.size.height = height
        if let manager = layoutManager {
            let caretIndex = min(selectedRange().location, max(0, (string as NSString).length - 1))
            let glyphIndex = manager.glyphIndexForCharacter(at: caretIndex)
            if glyphIndex < manager.numberOfGlyphs {
                let fragment = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                let baseline = manager.location(forGlyphAt: glyphIndex).y
                caret.origin.y = fragment.minY + textContainerOrigin.y + baseline - ascent
                return caret
            }
        }
        // No glyphs yet (empty document): TextKit parks extra leading above the glyphs, so
        // anchor the caret to the fragment's bottom.
        caret.origin.y = rect.maxY - height
        return caret
    }

    /// AppKit erases the caret by repainting the rect it proposed. A caret drawn outside that
    /// rect leaves ghost pixels behind on blink/move, so never escape it.
    private func clamped(_ caret: NSRect, within rect: NSRect) -> NSRect {
        var result = caret
        result.size.height = min(result.height, rect.height)
        result.origin.y = max(rect.minY, min(result.origin.y, rect.maxY - result.height))
        return result
    }

    /// The measure the prose is centred on. Held here rather than applied once at styling time
    /// because the inset depends on the view's width, which changes on every pane resize.
    public var readingLineWidth: Double = 720 {
        didSet {
            guard readingLineWidth != oldValue else { return }
            centerTextContainer(forWidth: bounds.width)
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centerTextContainer(forWidth: newSize.width)
        layoutHeaderView()
    }

    private func centerTextContainer(forWidth width: CGFloat) {
        guard readingLineWidth > 0, width > 0 else { return }
        let inset = max(0, (width - CGFloat(readingLineWidth)) / 2)
        guard abs(textContainerInset.width - inset) > 0.5 else { return }
        textContainerInset = NSSize(width: inset, height: 16)
        layoutHeaderView()
    }

    // MARK: - In-document header

    /// A view pinned above the first line of prose, inside this document view, so it scrolls
    /// with the note instead of floating over it. It lives in the scroll view's top content
    /// inset (the host sets `contentInsets.top = headerHeight`) and is laid out to the same
    /// column the prose is centred on.
    public var headerHostView: NSView? {
        didSet {
            guard headerHostView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let headerHostView { addSubview(headerHostView) }
            layoutHeaderView()
        }
    }

    public var headerHeight: CGFloat = 0 {
        didSet {
            guard abs(headerHeight - oldValue) > 0.5 else { return }
            layoutHeaderView()
        }
    }

    private func layoutHeaderView() {
        guard let headerHostView else { return }
        let inset = textContainerInset.width
        headerHostView.frame = NSRect(
            x: inset,
            y: -headerHeight,
            width: max(0, bounds.width - inset * 2),
            height: headerHeight
        )
    }



    public override func mouseDown(with event: NSEvent) {
        // Command-click follows a wiki link; a plain click must still place the caret.
        guard event.modifierFlags.contains(.command) else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let target = highlighter.wikiLinkTarget(in: string, at: index) {
            onFollowWikiLink?(target)
            return
        }
        super.mouseDown(with: event)
    }

    /// A first-responder `NSTextView` receives `mouseMoved` for the entire window and asserts
    /// the I-beam without hit-testing, which is why the pointer went text-shaped over the
    /// sidebar and the floating inspector. The window's hit-test already resolves the floating
    /// panes above this view for clicks, so the same resolution decides who owns the pointer:
    /// only let AppKit's inherited cursor handling run when the mouse is truly over this view.
    public override func mouseMoved(with event: NSEvent) {
        guard let window = event.window ?? window, let root = window.contentView else { return }
        let hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
        if hit === self || hit?.isDescendant(of: self) == true {
            super.mouseMoved(with: event)
            return
        }
        // Nothing re-asserts a pointer over plain chrome, so a stale I-beam would otherwise
        // stick when the mouse leaves the editor. Views that manage their own pointer —
        // editable controls, and views tracking mouse movement (the graph) — are left alone.
        let managesOwnPointer = hit.map { view in
            view is NSText || view is NSTextField
                || view.trackingAreas.contains {
                    $0.options.contains(.mouseMoved) || $0.options.contains(.cursorUpdate)
                }
        } ?? false
        if !managesOwnPointer {
            NSCursor.arrow.set()
        }
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// Extends AppKit's completion range only while the caret is inside an unfinished `[[link`.
    /// The completion popup, keyboard navigation, acceptance, accessibility, and Undo remain the
    /// native responder-chain implementation.
    public var unfinishedWikiLinkRange: NSRange? {
        let caret = selectedRange().location
        guard caret <= (string as NSString).length else { return nil }
        let prefix = (string as NSString).substring(to: caret) as NSString
        let opening = prefix.range(of: "[[", options: .backwards)
        guard opening.location != NSNotFound else { return nil }
        let start = NSMaxRange(opening)
        let fragment = prefix.substring(from: start)
        guard !fragment.contains("]]"),
              !fragment.contains("\n"),
              !fragment.contains("#"),
              !fragment.contains("|")
        else { return nil }
        return NSRange(location: start, length: caret - start)
    }

    public override var rangeForUserCompletion: NSRange {
        unfinishedWikiLinkRange ?? super.rangeForUserCompletion
    }

    public override func insertCompletion(
        _ word: String,
        forPartialWordRange charRange: NSRange,
        movement: Int,
        isFinal flag: Bool
    ) {
        guard flag, let wikiRange = unfinishedWikiLinkRange, charRange == wikiRange else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
            return
        }
        let end = NSMaxRange(charRange)
        let replacement = linkCompletionInsertion(word)
        let replacementRange = NSRange(location: charRange.location - 2, length: end - charRange.location + 2)
        super.insertCompletion(replacement, forPartialWordRange: replacementRange, movement: movement, isFinal: flag)
    }

    /// Responder-chain action used by the Edit menu and keyboard shortcuts. The mutation goes
    /// through `insertText`, so TextKit owns selection notifications and native Undo registration.
    @objc public func toggleMarkdownTask(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        let line = ns.substring(with: lineRange)
        guard let expression = try? NSRegularExpression(pattern: #"^\s*[-*+]\s+(\[[ xX-]\])"#),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
              ),
              match.numberOfRanges > 1
        else { return }
        let localMarker = match.range(at: 1)
        let marker = (line as NSString).substring(with: localMarker)
        let replacement = marker.lowercased() == "[x]" ? "[ ]" : "[x]"
        let absolute = NSRange(location: lineRange.location + localMarker.location, length: localMarker.length)
        insertText(replacement, replacementRange: absolute)
        setSelectedRange(selection)
    }

    /// SPEC §17: the editor uses native text accessibility. Add the role description the
    /// system cannot infer.
    public override func accessibilityRoleDescription() -> String? {
        "Markdown source editor"
    }
}

/// Hosts the AppKit text surface in SwiftUI (SPEC §7.1: AppKit owns the editor).
///
/// This is the `EditorSurface` seam from SPEC §9.1 — feature code talks to
/// `EditorDocumentModel`, never to the text view, so the surface can be replaced with
/// MarkdownEngine or STTextView without touching any screen.
public struct EditorHostView: NSViewRepresentable {
    private let document: EditorDocumentModel
    private let fontSize: Double
    private let lineWidth: Double
    private let spellcheckEnabled: Bool
    private let providedSurface: NativeEditorSurfaceAdapter?
    private let header: AnyView?
    private let headerKey: String?
    private let inlineTokenDecorationRevision: UInt
    private let inlineTokenDecorations: (String, [NSRange]) -> [InlineTokenDecoration]
    private let wikiLinkCompletions: (String) -> [String]
    private let linkCompletionInsertion: (String) -> String
    private let templateInsertion: TemplateInsertion?
    private let onFollowWikiLink: (String) -> Void

    public init(
        document: EditorDocumentModel,
        fontSize: Double,
        lineWidth: Double,
        spellcheckEnabled: Bool = true,
        surface: NativeEditorSurfaceAdapter? = nil,
        header: AnyView? = nil,
        headerKey: String? = nil,
        inlineTokenDecorationRevision: UInt = 0,
        inlineTokenDecorations: @escaping (String, [NSRange]) -> [InlineTokenDecoration] = { _, _ in [] },
        wikiLinkCompletions: @escaping (String) -> [String] = { _ in [] },
        linkCompletionInsertion: @escaping (String) -> String = { "[[\($0)]]" },
        templateInsertion: TemplateInsertion? = nil,
        onFollowWikiLink: @escaping (String) -> Void
    ) {
        self.document = document
        self.fontSize = fontSize
        self.lineWidth = lineWidth
        self.spellcheckEnabled = spellcheckEnabled
        self.providedSurface = surface
        self.header = header
        self.headerKey = headerKey
        self.inlineTokenDecorationRevision = inlineTokenDecorationRevision
        self.inlineTokenDecorations = inlineTokenDecorations
        self.wikiLinkCompletions = wikiLinkCompletions
        self.linkCompletionInsertion = linkCompletionInsertion
        self.templateInsertion = templateInsertion
        self.onFollowWikiLink = onFollowWikiLink
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            document: document,
            surface: providedSurface ?? NativeEditorSurfaceAdapter(),
            inlineTokenDecorationRevision: inlineTokenDecorationRevision,
            inlineTokenDecorations: inlineTokenDecorations,
            wikiLinkCompletions: wikiLinkCompletions,
            linkCompletionInsertion: linkCompletionInsertion,
            onFollowWikiLink: onFollowWikiLink
        )
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        // The in-document header lives above the text view's bounds, inside the top content
        // inset. NSClipView's default hit-testing only descends into the document view's own
        // frame, so scroll and click events over the header would otherwise dead-end at the
        // clip view (and the widget row's horizontal scroll would never engage).
        let clipView = HeaderAwareClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        let textView = context.coordinator.surface.install(in: scrollView)
        textView.isContinuousSpellCheckingEnabled = spellcheckEnabled
        textView.onFollowWikiLink = onFollowWikiLink
        textView.linkCompletionInsertion = linkCompletionInsertion
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        let existingFocusHandler = context.coordinator.surface.onFocusChange
        context.coordinator.surface.onFocusChange = { [weak coordinator = context.coordinator] focused in
            existingFocusHandler?(focused)
            guard !focused else { return }
            Task { await coordinator?.flushPendingSave() }
        }
        let existingAppearanceHandler = context.coordinator.surface.onAppearanceChange
        context.coordinator.surface.onAppearanceChange = { [weak coordinator = context.coordinator] in
            existingAppearanceHandler?()
            coordinator?.restyle()
        }

        context.coordinator.scrollView = scrollView
        context.coordinator.updateHeader(header, key: headerKey)
        context.coordinator.apply(text: document.text, fontSize: fontSize, lineWidth: lineWidth)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onFollowWikiLink = onFollowWikiLink
        context.coordinator.wikiLinkCompletions = wikiLinkCompletions
        context.coordinator.linkCompletionInsertion = linkCompletionInsertion
        context.coordinator.updateInlineTokenDecorations(
            revision: inlineTokenDecorationRevision,
            decorations: inlineTokenDecorations
        )
        context.coordinator.updateHeader(header, key: headerKey)
        (scrollView.documentView as? MarkdownTextView)?.onFollowWikiLink = onFollowWikiLink
        (scrollView.documentView as? MarkdownTextView)?.linkCompletionInsertion = linkCompletionInsertion
        (scrollView.documentView as? MarkdownTextView)?.isContinuousSpellCheckingEnabled =
            spellcheckEnabled
        // The model is the source of truth: adopt external replacements (reload, conflict
        // resolution) without clobbering the user's in-flight typing (SPEC §9.3).
        context.coordinator.syncFromModel(fontSize: fontSize, lineWidth: lineWidth)
        context.coordinator.insertTemplateIfNeeded(templateInsertion)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: MarkdownTextView?
        weak var scrollView: NSScrollView?
        private var headerHosting: NSHostingView<AnyView>?
        private var headerHeight: CGFloat = 0
        private var headerKey: String?
        var onFollowWikiLink: (String) -> Void
        var wikiLinkCompletions: (String) -> [String]
        var linkCompletionInsertion: (String) -> String
        private var inlineTokenDecorationRevision: UInt
        private var inlineTokenDecorations: (String, [NSRange]) -> [InlineTokenDecoration]
        let surface: NativeEditorSurfaceAdapter
        private let document: EditorDocumentModel
        private var appliedRevision: Int = -1
        private var deferredRestyleTask: Task<Void, Never>?
        private var lastTemplateInsertionID: UUID?
        /// The typography currently applied. Retained because `textDidChange` restyles without
        /// a SwiftUI update pass, so it has no other source for these values.
        private var fontSize: Double = 15
        private var lineWidth: Double = 720

        init(
            document: EditorDocumentModel,
            surface: NativeEditorSurfaceAdapter,
            inlineTokenDecorationRevision: UInt = 0,
            inlineTokenDecorations: @escaping (String, [NSRange]) -> [InlineTokenDecoration] = { _, _ in [] },
            wikiLinkCompletions: @escaping (String) -> [String],
            linkCompletionInsertion: @escaping (String) -> String = { "[[\($0)]]" },
            onFollowWikiLink: @escaping (String) -> Void
        ) {
            self.document = document
            self.surface = surface
            self.inlineTokenDecorationRevision = inlineTokenDecorationRevision
            self.inlineTokenDecorations = inlineTokenDecorations
            self.wikiLinkCompletions = wikiLinkCompletions
            self.linkCompletionInsertion = linkCompletionInsertion
            self.onFollowWikiLink = onFollowWikiLink
        }

        func updateInlineTokenDecorations(
            revision: UInt,
            decorations: @escaping (String, [NSRange]) -> [InlineTokenDecoration]
        ) {
            inlineTokenDecorations = decorations
            guard revision != inlineTokenDecorationRevision else { return }
            inlineTokenDecorationRevision = revision
            restyle()
        }

        /// Installs (or tears down) the in-document header above the prose. The header's
        /// measured height drives the scroll view's top content inset, so the text always
        /// starts below it and the header scrolls away with the document.
        func updateHeader(_ header: AnyView?, key: String?) {
            guard let textView else { return }
            guard let header else {
                headerHosting?.removeFromSuperview()
                headerHosting = nil
                headerKey = nil
                textView.headerHostView = nil
                applyHeaderHeight(0)
                return
            }
            // updateNSView runs on every editor update — every keystroke moves the status
            // bar's counts. Re-diffing the whole widget hierarchy each time is pure waste:
            // the header's own state (widget data, animations) lives inside the hosting
            // view, so the root only needs replacing when it represents a different note.
            if headerHosting != nil, key != nil, key == headerKey { return }
            headerKey = key
            let root = AnyView(
                VStack(spacing: 0) { header }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { [weak self] height in
                        self?.applyHeaderHeight(height)
                    }
            )
            if let headerHosting {
                headerHosting.rootView = root
            } else {
                let hosting = NSHostingView(rootView: root)
                hosting.autoresizingMask = []
                headerHosting = hosting
                textView.headerHostView = hosting
            }
        }

        private func applyHeaderHeight(_ height: CGFloat) {
            guard abs(height - headerHeight) > 0.5 else { return }
            let wasCollapsed = headerHeight == 0
            headerHeight = height
            textView?.headerHeight = height
            guard let scrollView else { return }
            let atTop = scrollView.contentView.bounds.origin.y <= 0
            var insets = scrollView.contentInsets
            insets.top = height
            scrollView.contentInsets = insets
            // Reveal the header when it first appears (or grows while the user is parked at
            // the top); never yank the viewport while they are reading further down.
            if height > 0, wasCollapsed || atTop {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -height))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        func syncFromModel(fontSize: Double, lineWidth: Double) {
            let typographyChanged = fontSize != self.fontSize || lineWidth != self.lineWidth
            guard appliedRevision != document.revision || typographyChanged else { return }
            apply(text: document.text, fontSize: fontSize, lineWidth: lineWidth)
        }

        func insertTemplateIfNeeded(_ insertion: TemplateInsertion?) {
            guard let insertion, insertion.id != lastTemplateInsertionID, let textView else { return }
            lastTemplateInsertionID = insertion.id
            textView.insertText(insertion.content, replacementRange: textView.selectedRange())
        }

        func apply(text: String, fontSize: Double, lineWidth: Double) {
            guard let textView else { return }
            deferredRestyleTask?.cancel()
            self.fontSize = fontSize
            self.lineWidth = lineWidth
            surface.replaceBuffer(text, preservingSelectionWhenPossible: true)
            // A model refresh received during IME composition remains pending until marked text
            // commits. Do not claim that revision was applied yet.
            guard textView.string == text else { return }
            appliedRevision = document.revision
            surface.markSynchronized()
            restyle()
        }

        func restyle() {
            guard let textView, !textView.hasMarkedText() else { return }
            NativeMarkdownStyler.apply(
                to: textView,
                fontSize: fontSize,
                lineWidth: lineWidth,
                inlineTokenDecorations: inlineTokenDecorations
            )
        }

        /// A complete lexical restyle is cheap for ordinary notes but would miss the 16 ms
        /// keystroke budget on a 1 MiB buffer. Large-note restyling is therefore coalesced until
        /// input pauses; TextKit paints the edit immediately with inherited typing attributes.
        func scheduleRestyleAfterEdit() {
            deferredRestyleTask?.cancel()
            guard let textView else { return }
            if textView.textStorage?.length ?? 0 <= 262_144 {
                restyle()
                return
            }
            deferredRestyleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.restyle()
            }
        }

        func flushPendingSave() async {
            await document.flushPendingSave()
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            surface.noteUserEdit()
            document.caretOffset = textView.selectedRange().location

            // Marked text is transient input-method state. Do not autosave or restyle it because
            // replacing attributes can disrupt the candidate session.
            guard !textView.hasMarkedText() else { return }
            if surface.flushDeferredReplacementIfPossible() {
                appliedRevision = document.revision
                restyle()
                return
            }

            document.bufferDidChange(to: textView.string)
            appliedRevision = document.revision
            surface.markSynchronized()
            scheduleRestyleAfterEdit()

            if let completionRange = textView.unfinishedWikiLinkRange {
                let prefix = (textView.string as NSString).substring(with: completionRange)
                if !wikiLinkCompletions(prefix).isEmpty {
                    DispatchQueue.main.async { [weak textView] in textView?.complete(nil) }
                }
            }
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            document.caretOffset = textView.selectedRange().location
            textView.updateConcealmentReveal()
        }

        /// Plain click on a rendered link. Wiki links carry their target as a `String`;
        /// external URLs return false so AppKit opens them in the default browser.
        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let target = link as? String else { return false }
            onFollowWikiLink(target)
            return true
        }

        /// SPEC §9.1: automatic list continuation.
        public func textView(
            _ textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)),
               (textView as? MarkdownTextView)?.unfinishedWikiLinkRange != nil {
                textView.complete(nil)
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            else { return false }
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            let lineRange = ns.lineRange(for: NSRange(location: max(0, caret - 1), length: 0))
            let line = ns.substring(with: lineRange)

            let remaining = caret < ns.length ? ns.substring(from: caret) : ""
            if let marker = Self.codeFenceCompletion(for: line, followingText: remaining) {
                textView.insertText("\n\n" + marker, replacementRange: textView.selectedRange())
                textView.setSelectedRange(NSRange(location: caret + 1, length: 0))
                return true
            }

            guard let continuation = Self.listContinuation(for: line) else { return false }
            if continuation.isEmpty {
                let contentLength = (line.trimmingCharacters(in: .newlines) as NSString).length
                textView.insertText(
                    "",
                    replacementRange: NSRange(location: lineRange.location, length: contentLength)
                )
            } else {
                textView.insertText("\n" + continuation, replacementRange: textView.selectedRange())
            }
            return true
        }

        /// The prefix a new line inherits from `line`, or nil when the line is not a list item.
        /// Returns "" for an empty list item so Return ends the list instead of extending it.
        static func codeFenceCompletion(for line: String, followingText: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let marker: String? = if trimmed.hasPrefix("```") {
                "```"
            } else if trimmed.hasPrefix("~~~") {
                "~~~"
            } else {
                nil
            }
            guard let marker, !followingText.contains("\n" + marker) else { return nil }
            return marker
        }

        static func listContinuation(for line: String) -> String? {
            let withoutNewline = line.trimmingCharacters(in: .newlines)
            let indent = String(withoutNewline.prefix(while: { $0 == " " || $0 == "\t" }))
            let content = withoutNewline.dropFirst(indent.count)

            if let match = content.range(of: #"^([-*+])\s+\[[ xX]\]\s+"#, options: .regularExpression) {
                let marker = content[match].trimmingCharacters(in: .whitespaces)
                let rest = content[match.upperBound...]
                guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
                let bullet = marker.first.map(String.init) ?? "-"
                return indent + bullet + " [ ] "
            }
            if let match = content.range(of: #"^([-*+])\s+"#, options: .regularExpression) {
                let rest = content[match.upperBound...]
                guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
                let bullet = content.first.map(String.init) ?? "-"
                return indent + bullet + " "
            }
            if let match = content.range(of: #"^(\d+)([.)])\s+"#, options: .regularExpression) {
                let rest = content[match.upperBound...]
                guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
                let marker = content[match]
                let digits = marker.prefix(while: { $0.isNumber })
                let punctuation = marker.dropFirst(digits.count).prefix(1)
                let next = (Int(digits) ?? 1) + 1
                return indent + "\(next)\(punctuation) "
            }
            return nil
        }
    }
}

/// Routes events in the scroll view's top content inset to the document header hosted by
/// `MarkdownTextView`. The header sits above the document view's frame (negative y in the
/// text view's flipped coordinates), where default AppKit hit-testing never looks, so the
/// widget row's clicks and horizontal scrolling would otherwise dead-end at the clip view.
final class HeaderAwareClipView: NSClipView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let textView = documentView as? MarkdownTextView,
           let header = textView.headerHostView,
           textView.headerHeight > 0 {
            let local = textView.convert(point, from: superview)
            if header.frame.contains(local), let hit = header.hitTest(local) {
                return hit
            }
        }
        return super.hitTest(point)
    }
}

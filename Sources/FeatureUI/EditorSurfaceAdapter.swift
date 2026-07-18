import AppCore
import AppKit
import ExtensionSDK
import Foundation

/// App-owned bridge between document state and the native AppKit editor.
///
/// Feature code depends on `EditorSurface`; `NSTextView` stays confined to this adapter and
/// `EditorHostView`. A third-party editor can replace this implementation without leaking its
/// types into the workspace or document model.
@MainActor
public final class NativeEditorSurfaceAdapter: EditorSurface {
    private weak var textView: MarkdownTextView?
    private var detachedText = ""
    private var detachedSelection = 0..<0
    private var deferredReplacement: (text: String, preservesSelection: Bool)?
    private var focusRequested = false

    public private(set) var isDirty = false
    public var onFocusChange: ((Bool) -> Void)?
    public var onAppearanceChange: (() -> Void)?

    public init() {}

    public var text: String {
        textView?.string ?? detachedText
    }

    /// UTF-16 offsets, matching AppKit's `NSRange` contract.
    public var selection: Range<Int> {
        get {
            guard let textView else { return detachedSelection }
            let selected = textView.selectedRange()
            return selected.location..<(selected.location + selected.length)
        }
        set {
            let clamped = Self.clamp(newValue, toUTF16Length: (text as NSString).length)
            detachedSelection = clamped
            textView?.setSelectedRange(NSRange(location: clamped.lowerBound, length: clamped.count))
        }
    }

    public var hasMarkedText: Bool {
        textView?.hasMarkedText() ?? false
    }

    public var hasDeferredReplacement: Bool {
        deferredReplacement != nil
    }

    public var isAttached: Bool {
        textView != nil
    }

    /// Installs the production native configuration in an AppKit scroll view.
    ///
    /// The text stack is assembled explicitly on TextKit 1: live-preview marker concealment
    /// needs `ConcealingLayoutManager`'s `.null`-glyph hook, which TextKit 2 does not expose
    /// (ADR-0002 amendment).
    @discardableResult
    public func install(in scrollView: NSScrollView) -> MarkdownTextView {
        let storage = NSTextStorage()
        let layoutManager = ConcealingLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: scrollView.bounds, textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true

        // Native text services. Smart punctuation/replacement stays off because Markdown source
        // delimiters must not be rewritten behind the user's back.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
            textView.allowedWritingToolsResultOptions = .plainText
        }

        textView.usesFontPanel = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("Note editor")
        textView.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
        textView.onAppearanceChange = { [weak self] in self?.onAppearanceChange?() }

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // The status bar overlays the editor's bottom edge on a progressive blur; this inset
        // lets the final lines scroll up out from underneath it.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 28, right: 0)
        scrollView.documentView = textView
        attach(textView)
        return textView
    }

    public func requestFocus() {
        guard let textView, let window = textView.window else {
            focusRequested = true
            return
        }
        focusRequested = !window.makeFirstResponder(textView)
    }

    public func resignFocus() {
        focusRequested = false
        guard let textView, let window = textView.window, window.firstResponder === textView else {
            return
        }
        window.makeFirstResponder(nil)
    }

    /// Replaces the source buffer without putting an external refresh into the user's undo stack.
    /// A replacement is deferred while an input method owns marked text so an in-progress
    /// composition is never destroyed.
    public func replaceBuffer(_ text: String, preservingSelectionWhenPossible: Bool) {
        detachedText = text
        guard let textView else {
            if !preservingSelectionWhenPossible {
                detachedSelection = 0..<0
            } else {
                detachedSelection = Self.clamp(
                    detachedSelection,
                    toUTF16Length: (text as NSString).length
                )
            }
            isDirty = false
            return
        }
        guard !textView.hasMarkedText() else {
            deferredReplacement = (text, preservingSelectionWhenPossible)
            return
        }
        applyReplacement(text, preservingSelection: preservingSelectionWhenPossible, to: textView)
    }

    /// Called by the AppKit delegate after text input commits.
    func noteUserEdit(text: String, selection: NSRange) {
        guard textView != nil else { return }
        detachedText = text
        detachedSelection = selection.location..<(selection.location + selection.length)
        isDirty = true
    }

    /// Marks the view/model handoff complete; disk dirtiness remains owned by
    /// `EditorDocumentModel`.
    func markSynchronized() {
        isDirty = false
    }

    /// Applies a model refresh that arrived during IME composition after marked text commits.
    /// Returns true when a deferred replacement was consumed.
    @discardableResult
    func flushDeferredReplacementIfPossible() -> Bool {
        guard let textView, !textView.hasMarkedText(), let replacement = deferredReplacement else {
            return false
        }
        deferredReplacement = nil
        applyReplacement(
            replacement.text,
            preservingSelection: replacement.preservesSelection,
            to: textView
        )
        return true
    }

    private func attach(_ textView: MarkdownTextView) {
        self.textView = textView
        if textView.string != detachedText {
            applyReplacement(detachedText, preservingSelection: true, to: textView)
        } else {
            selection = detachedSelection
        }
        if focusRequested {
            requestFocus()
        }
    }

    private func applyReplacement(
        _ replacement: String,
        preservingSelection: Bool,
        to textView: MarkdownTextView
    ) {
        let previousSelection = selection
        if textView.string != replacement {
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            textView.string = replacement
            undoManager?.enableUndoRegistration()
            // Undo ranges belong to the previous model revision. Retaining them after an external
            // reload can target invalid TextKit ranges and crash; the replacement itself is not an
            // undoable user edit, so a fresh native stack is the only safe boundary.
            undoManager?.removeAllActions()
        }

        let nextSelection = preservingSelection
            ? Self.clamp(previousSelection, toUTF16Length: (replacement as NSString).length)
            : 0..<0
        detachedText = replacement
        detachedSelection = nextSelection
        textView.setSelectedRange(NSRange(
            location: nextSelection.lowerBound,
            length: nextSelection.count
        ))
        isDirty = false
    }

    private static func clamp(_ range: Range<Int>, toUTF16Length length: Int) -> Range<Int> {
        let lower = min(max(0, range.lowerBound), length)
        let upper = min(max(lower, range.upperBound), length)
        return lower..<upper
    }
}

/// Applies live-preview Markdown attributes while preserving the backing string byte-for-byte.
@MainActor
enum NativeMarkdownStyler {
    static func apply(
        to textView: MarkdownTextView,
        fontSize: Double,
        lineWidth: Double,
        inlineTokenDecorations: (String, [NSRange]) -> [InlineTokenDecoration] = { _, _ in [] }
    ) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string
        let size = Typography.clampEditorFontSize(fontSize)
        let body = NSFont.systemFont(ofSize: size)
        let mono = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = Typography.editorLineHeightMultiple()

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: body,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let subduedMonoAttributes: [NSAttributedString.Key: Any] = [
            .font: mono,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let taskAttributes: [NSAttributedString.Key: Any] = [.font: mono]
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor
        ]
        let tagAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.controlAccentColor
        ]
        let inlineCodeAttributes: [NSAttributedString.Key: Any] = [
            .font: mono,
            .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        ]
        let headingFonts = (0...6).map { level in
            let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
            let scale = max(1.0, 1.5 - Double(level) * 0.08)
            return NSFont.systemFont(ofSize: size * scale, weight: weight)
        }

        // The caret takes its metrics from the typing attributes. Without these the insertion
        // point falls back to the field default (Helvetica 12) and draws at the wrong size and
        // position — the bug this styler exists to prevent.
        textView.font = body
        textView.typingAttributes = baseAttributes
        textView.insertionPointColor = .controlAccentColor
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]

        let full = NSRange(location: 0, length: storage.length)
        let styledRanges = MarkdownHighlighter().scan(text)
        let literalRanges = styledRanges
            .filter { $0.kind == .frontMatter || $0.kind == .codeFence }
            .map(\.range)
        let concealment = LivePreviewConcealment.scan(
            text,
            excluding: literalRanges,
            inlineTokens: inlineTokenDecorations(text, literalRanges),
            reusing: styledRanges
        )

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        for styled in styledRanges {
            guard NSMaxRange(styled.range) <= storage.length else { continue }
            switch styled.kind {
            case let .heading(level):
                storage.addAttributes(
                    [.font: headingFonts[level]],
                    range: styled.range
                )
            case .frontMatter:
                storage.addAttributes(subduedMonoAttributes, range: styled.range)
            case .codeFence:
                storage.addAttributes(subduedMonoAttributes, range: styled.range)
            case .task:
                storage.addAttributes(taskAttributes, range: styled.range)
            case .wikiLink, .markdownLink:
                storage.addAttributes(linkAttributes, range: styled.range)
            case .tag:
                storage.addAttributes(tagAttributes, range: styled.range)
            }
        }

        for element in concealment.elements {
            guard NSMaxRange(element.range) <= storage.length else { continue }
            switch element.kind {
            case .heading, .wikiLink, .markdownLink, .horizontalRule:
                break // Fonts/colors come from the highlighter pass; links get `.link` later.
            case .bold:
                addFontTraits(.boldFontMask, to: storage, in: element.visible)
            case .italic:
                addFontTraits(.italicFontMask, to: storage, in: element.visible)
            case .strikethrough:
                storage.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: element.visible
                )
            case .inlineCode:
                storage.addAttributes(inlineCodeAttributes, range: element.visible)
            case .inlineToken:
                break // Layout and drawing are glyph-level, in `ConcealingLayoutManager`.
            }
        }

        // Markers render dimmed — visible only on the revealed caret line, where the glyphs
        // are not concealed.
        for marker in concealment.markers where NSMaxRange(marker) <= storage.length {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
        }
        storage.endEditing()

        textView.concealment = concealment
        textView.applyConcealment()
        textView.readingLineWidth = lineWidth
    }

    /// Layers bold/italic onto whatever font is already at each position, so emphasis inside a
    /// heading keeps the heading size.
    private static func addFontTraits(
        _ traits: NSFontTraitMask,
        to storage: NSTextStorage,
        in range: NSRange
    ) {
        guard NSMaxRange(range) <= storage.length, range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
            guard let font = value as? NSFont else { return }
            let converted = NSFontManager.shared.convert(font, toHaveTrait: traits)
            storage.addAttribute(.font, value: converted, range: subRange)
        }
    }
}

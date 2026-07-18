import AppKit
import ExtensionSDK
import Foundation

/// Obsidian-style live preview (SPEC §9.1): syntax markers are concealed everywhere except the
/// caret's line, where the raw source is revealed for editing. The backing string is never
/// mutated — concealment happens at glyph generation, so saves, search, selection offsets, and
/// the recovery journal all keep operating on canonical Markdown.
public struct LivePreviewConcealment: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case heading(level: Int)
        case wikiLink(target: String)
        case markdownLink(destination: String)
        case bold
        case italic
        case strikethrough
        case inlineCode
        case horizontalRule
        /// An extension-provided token whose carrier keeps its original source offset while
        /// the layout manager renders its value-only glyph instruction.
        case inlineToken
    }

    /// One rendered Markdown element: the full source `range`, the `markers` hidden outside the
    /// caret line, and the `visible` content that remains on screen.
    public struct Element: Hashable, Sendable {
        public let range: NSRange
        public let markers: [NSRange]
        public let visible: NSRange
        public let kind: Kind
        public let inlineToken: InlineTokenDecoration?

        public init(
            range: NSRange,
            markers: [NSRange],
            visible: NSRange,
            kind: Kind,
            inlineToken: InlineTokenDecoration? = nil
        ) {
            self.range = range
            self.markers = markers
            self.visible = visible
            self.kind = kind
            self.inlineToken = inlineToken
        }
    }

    public let elements: [Element]
    /// Every marker range, sorted and non-overlapping, for the glyph-generation lookup.
    public let markers: [NSRange]

    public static let empty = LivePreviewConcealment(elements: [])

    /// These expressions are immutable after construction. Reuse them instead of recompiling
    /// ten patterns for every document restyle.
    private enum Expressions {
        static let heading = try! NSRegularExpression(
            pattern: #"(?m)^(#{1,6}) (?=\S)"#
        )
        static let horizontalRule = try! NSRegularExpression(
            pattern: #"(?m)^ {0,3}(-{3,}|\*{3,}|_{3,})[ \t]*$"#
        )
        static let inlineCode = try! NSRegularExpression(
            pattern: #"`([^`\n]+)`"#
        )
        static let wikiLink = try! NSRegularExpression(
            pattern: #"\[\[([^\]\n]+)\]\]"#
        )
        static let markdownLink = try! NSRegularExpression(
            pattern: #"\[([^\]\n]*)\]\(([^)\n]*)\)"#
        )
        static let boldAsterisk = try! NSRegularExpression(
            pattern: #"\*\*([^\s*][^*\n]*?[^\s*]|[^\s*])\*\*"#
        )
        static let boldUnderscore = try! NSRegularExpression(
            pattern: #"__([^\s_][^_\n]*?[^\s_]|[^\s_])__"#
        )
        static let italicAsterisk = try! NSRegularExpression(
            pattern: #"(?<![*\w])\*([^\s*][^*\n]*?[^\s*]|[^\s*])\*(?![*\w])"#
        )
        static let italicUnderscore = try! NSRegularExpression(
            pattern: #"(?<![\w_])_([^\s_][^_\n]*?[^\s_]|[^\s_])_(?![\w_])"#
        )
        static let strikethrough = try! NSRegularExpression(
            pattern: #"~~([^\s~][^~\n]*?[^\s~]|[^\s~])~~"#
        )
    }

    public init(elements: [Element]) {
        self.elements = elements.sorted { $0.range.location < $1.range.location }
        self.markers = elements
            .flatMap(\.markers)
            .sorted { $0.location < $1.location }
    }

    /// Lexical scan, matching the highlighter's philosophy (SPEC §9.2): tolerant, line-local,
    /// and cheap enough to run on the restyle path. `exclusions` are ranges that must stay
    /// literal — code fences and front matter from `MarkdownHighlighter.scan`.
    public static func scan(
        _ text: String,
        excluding exclusions: [NSRange] = [],
        inlineTokens: [InlineTokenDecoration] = []
    ) -> LivePreviewConcealment {
        scan(
            text,
            excluding: exclusions,
            inlineTokens: inlineTokens,
            reusing: nil
        )
    }

    /// Module-internal fast path. The ranges come from a scan of this exact `text` in the same
    /// styling pass; keeping the reuse seam internal prevents stale extension ranges from
    /// becoming part of the public API.
    static func scan(
        _ text: String,
        excluding exclusions: [NSRange],
        inlineTokens: [InlineTokenDecoration] = [],
        reusing styledRanges: [MarkdownHighlighter.StyledRange]?
    ) -> LivePreviewConcealment {
        let ns = text as NSString
        guard ns.length > 0 else { return .empty }
        let full = NSRange(location: 0, length: ns.length)
        let sortedExclusions = exclusions.sorted { $0.location < $1.location }

        var elements: [Element] = []
        /// Element ranges accepted so far, sorted, for overlap rejection between kinds
        /// (e.g. emphasis inside an inline code span loses to the code span).
        var accepted: [NSRange] = []

        func overlapsExisting(_ range: NSRange) -> Bool {
            if overlaps(range, in: sortedExclusions) { return true }
            return overlaps(range, in: accepted)
        }

        func isValidStyledRange(_ range: NSRange) -> Bool {
            range.location != NSNotFound
                && range.location >= 0
                && range.length >= 0
                && range.location <= ns.length
                && range.length <= ns.length - range.location
        }

        /// `claimsContent` is false for headings: they own only their `## ` prefix, so inline
        /// elements inside the title can still render.
        func collect(
            _ expression: NSRegularExpression,
            claimsContent: Bool = true,
            _ build: (NSTextCheckingResult) -> Element?
        ) {
            var fresh: [NSRange] = []
            expression.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match, !overlapsExisting(match.range), let element = build(match) else { return }
                elements.append(element)
                fresh.append(claimsContent ? element.range : element.markers[0])
            }
            accepted = merge(accepted, fresh)
        }

        // Headings conceal only the `## ` prefix; the title stays visible in heading type.
        if let styledRanges {
            var fresh: [NSRange] = []
            for styled in styledRanges {
                guard case let .heading(level) = styled.kind,
                      isValidStyledRange(styled.range),
                      styled.range.location < ns.length,
                      ns.character(at: styled.range.location) == 0x23
                else { continue }
                let marker = NSRange(location: styled.range.location, length: level + 1)
                var lineEnd = 0
                var contentsEnd = 0
                ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: styled.range)
                let titleRange = NSRange(
                    location: NSMaxRange(marker),
                    length: contentsEnd - NSMaxRange(marker)
                )
                guard NSMaxRange(marker) < contentsEnd,
                      ns.character(at: NSMaxRange(marker) - 1) == 0x20,
                      ns.rangeOfCharacter(
                        from: CharacterSet.whitespacesAndNewlines.inverted,
                        options: [],
                        range: titleRange
                      ).location == titleRange.location,
                      !overlapsExisting(marker)
                else { continue }
                elements.append(Element(
                    range: NSRange(location: marker.location, length: contentsEnd - marker.location),
                    markers: [marker],
                    visible: NSRange(
                        location: NSMaxRange(marker),
                        length: contentsEnd - NSMaxRange(marker)
                    ),
                    kind: .heading(level: level)
                ))
                fresh.append(marker)
            }
            accepted = merge(accepted, fresh)
        } else {
            collect(Expressions.heading, claimsContent: false) { match in
                let hashes = match.range(at: 1)
                let marker = NSRange(location: hashes.location, length: hashes.length + 1)
                var lineEnd = 0
                var contentsEnd = 0
                ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: match.range)
                let visible = NSRange(location: NSMaxRange(marker), length: contentsEnd - NSMaxRange(marker))
                return Element(
                    range: NSRange(location: marker.location, length: contentsEnd - marker.location),
                    markers: [marker],
                    visible: visible,
                    kind: .heading(level: hashes.length)
                )
            }
        }

        // Thematic breaks (`---`, `***`, `___` and longer runs) conceal the whole line; the
        // layout manager draws a full-width divider in their place, as Obsidian does. Claiming
        // the line also keeps `***` runs out of the emphasis passes.
        collect(Expressions.horizontalRule) { match in
            Element(
                range: match.range,
                markers: [match.range],
                visible: NSRange(location: NSMaxRange(match.range), length: 0),
                kind: .horizontalRule
            )
        }

        // Inline code wins over links/emphasis inside it, so it scans first among inline kinds.
        collect(Expressions.inlineCode) { match in
            let inner = match.range(at: 1)
            return Element(
                range: match.range,
                markers: [
                    NSRange(location: match.range.location, length: 1),
                    NSRange(location: NSMaxRange(inner), length: 1)
                ],
                visible: inner,
                kind: .inlineCode
            )
        }

        // `[[Target#Heading|Alias]]` shows the alias; `[[Target]]` shows the target.
        func wikiLinkElement(range: NSRange, inner: NSRange) -> Element {
            let innerText = ns.substring(with: inner)
            let target = innerText
                .split(separator: "|").first.map(String.init)
                .flatMap { $0.split(separator: "#").first.map(String.init) } ?? innerText
            let pipe = ns.range(of: "|", options: [], range: inner)
            let visible: NSRange
            var markers: [NSRange]
            if pipe.location != NSNotFound, NSMaxRange(pipe) < NSMaxRange(inner) {
                visible = NSRange(location: NSMaxRange(pipe), length: NSMaxRange(inner) - NSMaxRange(pipe))
                markers = [NSRange(location: range.location, length: visible.location - range.location)]
            } else {
                visible = inner
                markers = [NSRange(location: range.location, length: 2)]
            }
            markers.append(NSRange(location: NSMaxRange(inner), length: 2))
            return Element(range: range, markers: markers, visible: visible, kind: .wikiLink(target: target))
        }

        if let styledRanges {
            var fresh: [NSRange] = []
            for styled in styledRanges where styled.kind == .wikiLink {
                guard isValidStyledRange(styled.range),
                      !overlapsExisting(styled.range),
                      styled.range.length >= 5
                else { continue }
                let inner = NSRange(
                    location: styled.range.location + 2,
                    length: styled.range.length - 4
                )
                let element = wikiLinkElement(range: styled.range, inner: inner)
                elements.append(element)
                fresh.append(element.range)
            }
            accepted = merge(accepted, fresh)
        } else {
            collect(Expressions.wikiLink) { match in
                wikiLinkElement(range: match.range, inner: match.range(at: 1))
            }
        }

        // `[text](destination)` shows the text.
        func markdownLinkElement(
            range: NSRange,
            label: NSRange,
            destination: NSRange
        ) -> Element? {
            guard label.length > 0 else { return nil }
            return Element(
                range: range,
                markers: [
                    NSRange(location: range.location, length: 1),
                    NSRange(location: NSMaxRange(label), length: NSMaxRange(range) - NSMaxRange(label))
                ],
                visible: label,
                kind: .markdownLink(destination: ns.substring(with: destination))
            )
        }

        if let styledRanges {
            var fresh: [NSRange] = []
            for styled in styledRanges where styled.kind == .markdownLink {
                guard isValidStyledRange(styled.range), !overlapsExisting(styled.range) else { continue }
                let separator = ns.range(of: "](", options: [], range: styled.range)
                guard separator.location != NSNotFound else { continue }
                let label = NSRange(
                    location: styled.range.location + 1,
                    length: separator.location - styled.range.location - 1
                )
                let destination = NSRange(
                    location: NSMaxRange(separator),
                    length: NSMaxRange(styled.range) - NSMaxRange(separator) - 1
                )
                guard let element = markdownLinkElement(
                    range: styled.range,
                    label: label,
                    destination: destination
                ) else { continue }
                elements.append(element)
                fresh.append(element.range)
            }
            accepted = merge(accepted, fresh)
        } else {
            collect(Expressions.markdownLink) { match in
                markdownLinkElement(
                    range: match.range,
                    label: match.range(at: 1),
                    destination: match.range(at: 2)
                )
            }
        }

        func delimited(_ expression: NSRegularExpression, markerLength: Int, kind: Kind) {
            collect(expression) { match in
                let inner = match.range(at: 1)
                return Element(
                    range: match.range,
                    markers: [
                        NSRange(location: match.range.location, length: markerLength),
                        NSRange(location: NSMaxRange(inner), length: markerLength)
                    ],
                    visible: inner,
                    kind: kind
                )
            }
        }

        // CommonMark-ish boundaries: content cannot begin or end with whitespace, which also
        // keeps `* ` list bullets from pairing with a later asterisk on the line.
        delimited(Expressions.boldAsterisk, markerLength: 2, kind: .bold)
        delimited(Expressions.boldUnderscore, markerLength: 2, kind: .bold)
        delimited(Expressions.italicAsterisk, markerLength: 1, kind: .italic)
        delimited(Expressions.italicUnderscore, markerLength: 1, kind: .italic)
        delimited(Expressions.strikethrough, markerLength: 2, kind: .strikethrough)

        // Extensions provide resolved, value-only token decorations. The core owns overlap
        // priority and defensive range validation so a malformed provider cannot conceal
        // arbitrary source text or corrupt TextKit offsets.
        for token in inlineTokens.sorted(by: { $0.sourceRange.location < $1.sourceRange.location }) {
            guard isValid(token, within: full),
                  !overlaps(token.sourceRange, in: sortedExclusions),
                  !overlaps(token.sourceRange, in: accepted)
            else { continue }
            elements.append(Element(
                range: token.sourceRange,
                markers: token.concealedRanges,
                visible: token.carrierRange,
                kind: .inlineToken,
                inlineToken: token
            ))
            accepted.append(token.sourceRange)
            accepted.sort { $0.location < $1.location }
        }

        return LivePreviewConcealment(elements: elements)
    }

    private static func isValid(_ token: InlineTokenDecoration, within full: NSRange) -> Bool {
        guard token.sourceRange.length > 1,
              token.carrierRange.length == 1,
              NSLocationInRange(token.carrierRange.location, token.sourceRange),
              NSMaxRange(token.carrierRange) <= NSMaxRange(token.sourceRange),
              token.glyph.count == 1,
              !token.fontName.isEmpty
        else { return false }
        let markers = token.concealedRanges.sorted { $0.location < $1.location }
        guard !markers.isEmpty else { return false }
        var previousEnd = token.sourceRange.location
        for marker in markers {
            guard marker.length > 0,
                  NSIntersectionRange(marker, full) == marker,
                  NSIntersectionRange(marker, token.sourceRange) == marker,
                  marker.location >= previousEnd,
                  NSIntersectionRange(marker, token.carrierRange).length == 0
            else { return false }
            previousEnd = NSMaxRange(marker)
        }
        return true
    }

    /// Binary search over sorted, non-overlapping ranges.
    static func overlaps(_ range: NSRange, in sorted: [NSRange]) -> Bool {
        var low = 0
        var high = sorted.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = sorted[mid]
            if NSMaxRange(candidate) <= range.location {
                low = mid + 1
            } else if candidate.location >= NSMaxRange(range) {
                high = mid - 1
            } else {
                return true
            }
        }
        return false
    }

    private static func merge(_ lhs: [NSRange], _ rhs: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var i = 0
        var j = 0
        while i < lhs.count || j < rhs.count {
            if j == rhs.count || (i < lhs.count && lhs[i].location <= rhs[j].location) {
                result.append(lhs[i])
                i += 1
            } else {
                result.append(rhs[j])
                j += 1
            }
        }
        return result
    }
}

/// TextKit 1 layout manager that hides marker glyphs outside the revealed (caret) line.
///
/// Only the classic `NSLayoutManager` exposes the `.null` glyph-property hook, which is why the
/// editor pins the TextKit 1 stack (ADR-0002 amendment): concealment must be zero-width without
/// touching the backing string, and TextKit 2 offers no public equivalent.
public final class ConcealingLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// A carrier character whose source stays canonical while drawing uses an extension's
    /// value-only glyph and font instruction.
    public struct InlineToken: Hashable, Sendable {
        public let location: Int
        public let glyph: String
        public let fontName: String

        public init(location: Int, glyph: String, fontName: String) {
            self.location = location
            self.glyph = glyph
            self.fontName = fontName
        }
    }

    private var markerRanges: [NSRange] = []
    /// Thematic-break lines: concealed like markers, but drawn as a full-width divider.
    private var ruleRanges: [NSRange] = []
    /// Sorted by location; positions track edits like `markerRanges`.
    private var inlineTokens: [InlineToken] = []
    public private(set) var revealedRange = NSRange(location: NSNotFound, length: 0)

    public override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
        allowsNonContiguousLayout = true
    }

    /// Replaces the concealed marker set (after a restyle). Invalidates from the first changed
    /// marker or icon onward rather than the whole document, so caret-line-only changes stay
    /// cheap.
    public func setConcealedMarkers(
        _ markers: [NSRange],
        rules: [NSRange] = [],
        tokens: [InlineToken] = []
    ) {
        ruleRanges = rules
        guard markers != markerRanges || tokens != inlineTokens else { return }
        let markerChange = Self.firstChangedLocation(
            markerRanges,
            markers
        )
        let iconChange = Self.firstChangedLocation(
            inlineTokens.map { NSRange(location: $0.location, length: 1) },
            tokens.map { NSRange(location: $0.location, length: 1) }
        )
        markerRanges = markers
        inlineTokens = tokens
        guard let invalidateFrom = [markerChange, iconChange].compactMap({ $0 }).min() else {
            return
        }
        let storageLength = textStorage?.length ?? 0
        invalidateConcealment(in: NSRange(
            location: min(invalidateFrom, storageLength),
            length: max(0, storageLength - min(invalidateFrom, storageLength))
        ))
    }

    /// The lowest character location affected by replacing `old` with `new`, or nil when they
    /// are identical.
    private static func firstChangedLocation(_ old: [NSRange], _ new: [NSRange]) -> Int? {
        var firstDifference = min(old.count, new.count)
        for index in 0..<min(old.count, new.count) where old[index] != new[index] {
            firstDifference = index
            break
        }
        guard firstDifference < old.count || firstDifference < new.count else { return nil }
        return min(
            firstDifference < old.count ? old[firstDifference].location : Int.max,
            firstDifference < new.count ? new[firstDifference].location : Int.max
        )
    }

    /// Moves the revealed (caret) line; only the old and new lines re-generate glyphs.
    public func updateRevealedRange(_ range: NSRange) {
        guard range != revealedRange else { return }
        let previous = revealedRange
        revealedRange = range
        invalidateConcealment(in: previous)
        invalidateConcealment(in: range)
    }

    /// Keeps concealed ranges aligned with the buffer between edits and the next restyle, so
    /// stale offsets never conceal the wrong characters (including in large notes, where the
    /// restyle is coalesced).
    public override func processEditing(
        for textStorage: NSTextStorage,
        edited editMask: NSTextStorageEditActions,
        range newCharRange: NSRange,
        changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange
    ) {
        if editMask.contains(.editedCharacters) {
            adjustRanges(forEditedRange: newCharRange, changeInLength: delta)
        }
        super.processEditing(
            for: textStorage,
            edited: editMask,
            range: newCharRange,
            changeInLength: delta,
            invalidatedRange: invalidatedCharRange
        )
    }

    private func adjustRanges(forEditedRange newCharRange: NSRange, changeInLength delta: Int) {
        let oldRange = NSRange(location: newCharRange.location, length: newCharRange.length - delta)
        Self.shift(&markerRanges, pastEdit: oldRange, by: delta)
        Self.shift(&ruleRanges, pastEdit: oldRange, by: delta)

        var tokenWriteIndex = 0
        let tokenCount = inlineTokens.count
        for tokenReadIndex in 0..<tokenCount {
            let token = inlineTokens[tokenReadIndex]
            let range = NSRange(location: token.location, length: 1)
            if NSMaxRange(range) <= oldRange.location {
                inlineTokens[tokenWriteIndex] = token
                tokenWriteIndex += 1
                continue
            }
            if range.location >= NSMaxRange(oldRange) {
                inlineTokens[tokenWriteIndex] = InlineToken(
                    location: token.location + delta,
                    glyph: token.glyph,
                    fontName: token.fontName
                )
                tokenWriteIndex += 1
            }
            // The edit touched the carrier; drop it until the restyle recomputes elements.
        }
        if tokenWriteIndex < inlineTokens.count {
            inlineTokens.removeSubrange(tokenWriteIndex...)
        }
        if revealedRange.location != NSNotFound, revealedRange.location >= NSMaxRange(oldRange) {
            revealedRange.location += delta
        }
    }

    /// Drops ranges touched by an edit and shifts the remaining suffix in the array's existing
    /// storage. A large note can contain tens of thousands of markers, so avoiding a new array
    /// allocation on every keystroke materially reduces dispatch work without changing offsets.
    private static func shift(
        _ ranges: inout [NSRange],
        pastEdit oldRange: NSRange,
        by delta: Int
    ) {
        var writeIndex = 0
        let rangeCount = ranges.count
        for readIndex in 0..<rangeCount {
            let range = ranges[readIndex]
            if NSMaxRange(range) <= oldRange.location {
                ranges[writeIndex] = range
                writeIndex += 1
                continue
            }
            if range.location >= NSMaxRange(oldRange) {
                ranges[writeIndex] = NSRange(
                    location: range.location + delta,
                    length: range.length
                )
                writeIndex += 1
            }
            // The edit touched this range; drop it until the restyle recomputes concealment.
        }
        if writeIndex < ranges.count {
            ranges.removeSubrange(writeIndex...)
        }
    }

    private func invalidateConcealment(in charRange: NSRange) {
        guard charRange.location != NSNotFound, charRange.length > 0 else { return }
        let length = textStorage?.length ?? 0
        let clamped = NSIntersectionRange(charRange, NSRange(location: 0, length: length))
        guard clamped.length > 0 else { return }
        invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
        // Layout invalidation alone does not repaint: without this, previously drawn rules,
        // chips, and marker glyphs linger as stale pixels that appear to drift with the caret.
        invalidateDisplay(forCharacterRange: clamped)
    }

    private func isConcealed(_ characterIndex: Int) -> Bool {
        Self.contains(characterIndex, in: markerRanges)
    }

    private func isRevealed(_ characterIndex: Int) -> Bool {
        revealedRange.location != NSNotFound && NSLocationInRange(characterIndex, revealedRange)
    }

    /// Binary search over `inlineTokens`, sorted by location.
    private func inlineToken(at characterIndex: Int) -> InlineToken? {
        var low = 0
        var high = inlineTokens.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = inlineTokens[mid]
            if characterIndex < candidate.location {
                high = mid - 1
            } else if characterIndex > candidate.location {
                low = mid + 1
            } else {
                return candidate
            }
        }
        return nil
    }

    private static func contains(_ index: Int, in sorted: [NSRange]) -> Bool {
        var low = 0
        var high = sorted.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = sorted[mid]
            if index < candidate.location {
                high = mid - 1
            } else if index >= NSMaxRange(candidate) {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    // MARK: - Drawing

    /// Draws a full-width divider where a concealed thematic break (`---`) sits, matching
    /// Obsidian. The revealed caret line shows the raw dashes instead.
    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !ruleRanges.isEmpty, let text = textStorage?.string as NSString? else { return }
        let drawnCharacters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for rule in ruleRanges {
            guard rule.location < text.length,
                  NSIntersectionRange(rule, drawnCharacters).length > 0,
                  revealedRange.location == NSNotFound
                    || NSIntersectionRange(rule, revealedRange).length == 0
            else { continue }
            // The dashes are `.null` glyphs, which do not participate in layout —
            // lineFragmentRect for them is unstable and made the rule drift as reveal state
            // regenerated glyphs. The line's terminator (newline control glyph) always stays
            // in layout, so anchor the fragment lookup there.
            let lineRange = text.lineRange(for: NSRange(location: rule.location, length: 0))
            let glyphRange = self.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let anchorGlyph = min(NSMaxRange(glyphRange) - 1, numberOfGlyphs - 1)
            let fragment = lineFragmentRect(forGlyphAt: anchorGlyph, effectiveRange: nil)
            let line = NSRect(
                x: fragment.minX + origin.x,
                y: (fragment.midY + origin.y).rounded() - 0.5,
                width: fragment.width,
                height: 1
            )
            NSColor.separatorColor.setFill()
            line.fill()
        }
    }

    /// Inline-code chips: the stock background fills the whole 1.6-leading line fragment, whose
    /// extra space sits *above* the glyphs — the chip floats high and the text pokes out the
    /// bottom. Anchor the chip to the run's baseline and size it from the font instead.
    public override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        let horizontalPadding: CGFloat = 2
        let verticalPadding: CGFloat = 1.5
        let font = textStorage.flatMap {
            charRange.location < $0.length
                ? $0.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont
                : nil
        }
        let glyphIndex = glyphIndexForCharacter(at: charRange.location)
        // Baseline offset within the line fragment; the rects passed in span the fragment's
        // vertical extent, so this is also the offset from each rect's top.
        let baselineOffset = glyphIndex < numberOfGlyphs
            ? location(forGlyphAt: glyphIndex).y
            : nil

        color.setFill()
        for index in 0..<rectCount {
            var rect = rectArray[index]
            if let font, let baselineOffset {
                let top = rect.minY + baselineOffset - font.ascender - verticalPadding
                rect = NSRect(
                    x: rect.minX - horizontalPadding,
                    y: top,
                    width: rect.width + horizontalPadding * 2,
                    height: font.ascender - font.descender + verticalPadding * 2
                )
            } else {
                rect = rect.insetBy(dx: -horizontalPadding, dy: 2)
            }
            guard rect.width > 0, rect.height > 0 else { continue }
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
    }

    // MARK: - NSLayoutManagerDelegate

    public func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard glyphRange.length > 0 else { return 0 }
        guard !markerRanges.isEmpty || !inlineTokens.isEmpty else { return 0 }
        let first = charIndexes[0]
        let last = charIndexes[glyphRange.length - 1]
        let coveredCharacters = NSRange(location: first, length: last - first + 1)
        guard LivePreviewConcealment.overlaps(coveredCharacters, in: markerRanges)
            || inlineTokens.contains(where: { NSLocationInRange($0.location, coveredCharacters) })
        else { return 0 }

        var modified = [NSLayoutManager.GlyphProperty](repeating: .null, count: glyphRange.length)
        var changed = false
        for index in 0..<glyphRange.length {
            let character = charIndexes[index]
            let revealed = revealedRange.location != NSNotFound
                && NSLocationInRange(character, revealedRange)
            if !revealed, isConcealed(character) {
                modified[index] = .null
                changed = true
            } else if !revealed, inlineToken(at: character) != nil {
                // A token carrier becomes a control glyph so the whitespace action and the
                // bounding-box delegate below can reserve glyph-sized space for it. Drawing
                // runs with the extension-provided font name, which is why the glyph cannot
                // simply be swapped here. Rendering runs draw with
                // the *attribute* font, which is why the glyph cannot simply be swapped here.
                modified[index] = .controlCharacter
                changed = true
            } else {
                modified[index] = props[index]
            }
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(
            glyphs,
            properties: &modified,
            characterIndexes: charIndexes,
            font: font,
            forGlyphRange: glyphRange
        )
        return glyphRange.length
    }

    public func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard inlineToken(at: charIndex) != nil, !isRevealed(charIndex) else { return action }
        return .whitespace
    }

    public func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard inlineToken(at: charIndex) != nil, !isRevealed(charIndex) else { return .zero }
        let size = iconPointSize(at: charIndex)
        // A font glyph fills its em square, plus a hair of trailing air before the text.
        return NSRect(x: glyphPosition.x, y: proposedRect.minY, width: size * 1.1, height: proposedRect.height)
    }

    /// The surrounding text size for a token carrier, from the storage font at its position —
    /// tokens in headings scale with the heading.
    private func iconPointSize(at charIndex: Int) -> CGFloat {
        guard let storage = textStorage, charIndex < storage.length,
              let font = storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont
        else {
            return NSFont.systemFontSize
        }
        return font.pointSize
    }

    /// Paints extension glyphs into whitespace reserved for token carriers, in the carrier's
    /// text color. Runs after the normal glyph pass so they layer like any other glyph.
    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard !inlineTokens.isEmpty, let storage = textStorage else { return }
        let drawnCharacters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for token in inlineTokens {
            guard NSLocationInRange(token.location, drawnCharacters),
                  token.location < storage.length,
                  !isRevealed(token.location)
            else { continue }
            let textFont = storage.attribute(.font, at: token.location, effectiveRange: nil)
                as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            guard let tokenFont = NSFont(name: token.fontName, size: textFont.pointSize) else { continue }
            let glyphIndex = glyphIndexForCharacter(at: token.location)
            guard glyphIndex < numberOfGlyphs else { continue }
            let fragment = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let position = location(forGlyphAt: glyphIndex)
            let color = storage.attribute(.foregroundColor, at: token.location, effectiveRange: nil)
                as? NSColor ?? .labelColor
            let baseline = fragment.minY + position.y
            // Optically center the glyph's actual ink box on the text's cap-height midpoint —
            // icon fonts do not fill their nominal ascent, so anchoring the ascender to the
            // baseline floats them visibly high next to text.
            var unit = Array(token.glyph.utf16)
            var glyph = CGGlyph(0)
            var inkBox = CGRect(
                x: 0,
                y: 0,
                width: textFont.pointSize,
                height: textFont.capHeight
            )
            if CTFontGetGlyphsForCharacters(tokenFont as CTFont, &unit, &glyph, 1) {
                inkBox = CTFontGetBoundingRectsForGlyphs(
                    tokenFont as CTFont,
                    .default,
                    [glyph],
                    nil,
                    1
                )
            }
            let drawTop = baseline - textFont.capHeight / 2 - tokenFont.ascender + inkBox.midY
            token.glyph.draw(
                at: NSPoint(
                    x: origin.x + fragment.minX + position.x,
                    y: origin.y + drawTop
                ),
                withAttributes: [.font: tokenFont, .foregroundColor: color]
            )
        }
    }
}

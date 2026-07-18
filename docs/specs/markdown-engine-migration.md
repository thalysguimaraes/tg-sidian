# Spec: Migrate the editor surface to swift-markdown-engine

- **Status:** Declined after Phase 0
- **Date:** 2026-07-16
- **Supersedes if accepted:** parts of [ADR-0002](../adr/0002-native-markdown-editor-engine.md)
- **Touches:** [ADR-0001](../adr/0001-dependency-light-foundation.md) (dependency policy)

## 1. Summary

Replace tg-sidian's hand-built Markdown editing *surface* with
[`nodes-app/swift-markdown-engine`](https://github.com/nodes-app/swift-markdown-engine)
(Apache-2.0, TextKit 2, Swift Package, 734★, v0.10.0 as of 2026-07-16).

The engine already implements the two things this project built by hand and the
one thing it did not: Obsidian-style **marker/fence hiding with caret reveal**
(our TextKit 1 `ConcealingLayoutManager`), a **centered reading column**
(our `readingLineWidth`), and **wiki-link display/storage roundtripping** — plus
task checkboxes, GFM tables, code-block highlighting, and LaTeX we do not have.

This is a **surface** migration only. The safe-editing model
(`EditorDocumentModel`: conflict detection, recovery journal, atomic saves) is
orthogonal and stays. The bet is that adopting a maintained TextKit 2 engine
removes more code and risk than it adds, and modernizes off the TextKit 1
glyph-hiding hack that forced the caret-metrics workaround (see §6.2).

This spec does **not** authorize the migration. It defines the design, the
exit criteria, and the kill switches so the work can be scheduled — or declined
— on evidence from a spike (§7, Phase 0).

## 2. Motivation

- The concealment feature (marker hiding except on the caret's line) is the
  hard part of "feels like Obsidian." We shipped it on **TextKit 1**, because
  only the classic `NSLayoutManager` exposes the `.null`-glyph hook. That choice
  cost a caret-metrics bug (the hand-built stack had no default font; the
  insertion point fell back to Helvetica 12) and leaves us on the older text
  stack while the platform moves to TextKit 2.
- The engine covers, in one dependency, features currently spread across
  `MarkdownTextView`, `ConcealingLayoutManager`, `NativeMarkdownStyler`,
  `MarkdownHighlighter`, and the reading-column code — and adds tables, task
  toggles, code highlighting, and LaTeX.
- It is actively maintained, permissively licensed, and integrates through a
  small SwiftUI wrapper plus four opt-in service protocols.

## 3. Non-goals

- **Not** replacing `EditorDocumentModel` or the recovery/conflict machinery
  (PENTA-139). The engine renders and edits text; it does not own persistence.
- **Not** replacing the index, graph, sidebar, or inspector.
- **Not** adopting the engine's LaTeX/code-block *bridges* in the first cut.
  Ship `MarkdownEngine` (zero transitive deps) first; add
  `MarkdownEngineCodeBlocks` / `MarkdownEngineLatex` later if wanted (§5.4).

## 4. What the engine provides vs. what we replace

| Capability | Today (tg-sidian) | Engine |
|---|---|---|
| Text surface | `MarkdownTextView` (NSTextView, TextKit 1) | `NativeTextViewWrapper` (TextKit 2) |
| Marker concealment | `ConcealingLayoutManager` + `LivePreviewConcealment` | built-in "marker/fence hiding, caret reveal" |
| Styling | `NativeMarkdownStyler` + `MarkdownHighlighter` | built-in live styling + `MarkdownExtension` |
| Reading column | `readingLineWidth` in `MarkdownTextView.setFrameSize` | `configuration.readingWidth` |
| Wiki links | `MarkdownHighlighter.wikiLinkTarget` + completion flow | `WikiLinkResolver` + `isWikiLinkActive` + `pendingInlineReplacement` |
| Follow link | Cmd-click in `mouseDown` | resolver id + host handles navigation |
| Task toggle / lists | `MarkdownTextView` doCommand handlers | built-in |
| Tables / code hi / LaTeX | none | built-in (code/LaTeX via optional products) |
| Theme | `Palette` (NSColor dynamic) | `MarkdownEditorTheme` (NSColor dynamic) |

### Files this migration deletes or hollows out

- `MarkdownTextView.swift` — the `ConcealingLayoutManager`,
  `LivePreviewConcealment`, `concealableMarkers`, `makeConcealing`,
  `readingLineWidth`, and most of `MarkdownHighlighter`.
- `EditorSurfaceAdapter.swift` — `NativeMarkdownStyler`; large parts of
  `NativeEditorSurfaceAdapter` (install, buffer replace, IME defer, styling).
- Reading-column logic and the AX caret/font workaround.

### Files that stay

- `EditorDocumentModel.swift`, `RecoveryJournal.swift`, `SaveCoordinator`.
- `EditorScreen.swift` toolbar/status bar (re-hosts the engine wrapper).
- `VaultSessionModel` link/completion providers (re-pointed at the resolver).

## 5. Integration design

### 5.1 The buffer bridge (the crux)

The engine exposes `NativeTextViewWrapper(text: Binding<String>)`. Our source of
truth is `EditorDocumentModel`, which owns dirty-tracking, atomic saves,
external-conflict detection, and the recovery journal (SPEC §9.3, §22). The
binding must therefore be a **projection of the model**, not a second store:

- `get`: the model's current buffer.
- `set`: route through `document.bufferDidChange(to:)` so autosave, statistics,
  and fingerprinting stay owned by the model.

External replacements (reload, conflict resolution, recovery restore) still
originate in the model and must reach the engine without entering the user's
undo stack. Confirm the engine treats a programmatic `text` change as a
non-undoable external set; if it does not, we need an engine-level
"replace without undo" entry point (open question §8.1). This is the single
highest-risk seam and Phase 0 must prove it.

### 5.2 Wiki links

- Implement `WikiLinkResolver.resolve(displayName:range:)` against the index —
  return a stable id and `exists` so the engine styles resolved vs. unresolved.
- Drive completion by observing `isWikiLinkActive` and pushing results through
  `pendingInlineReplacement`, replacing the current `unfinishedWikiLinkRange`
  completion flow.
- "Follow link" (currently Cmd-click) maps to the resolver id → `session.openNote`.

### 5.3 Reading column, theme, tuning

- `configuration.readingWidth = <preference>` replaces our centered inset. The
  engine wraps at that width and only moves the column on resize — this deletes
  the `setFrameSize`/`layout` recomputation we fought with earlier.
- Map `Palette` roles onto `MarkdownEditorTheme` (both are NSColor dynamic, so
  light/dark keeps working). Feed `Palette.Reference`/`Dark` values through the
  theme so the design tokens remain the single source.
- `configuration.headings.fontMultipliers`, `heightBehavior`,
  `safeAreaInsets` map to our toolbar/status-bar chrome.

### 5.4 Dependencies (ADR-0001 reconciliation)

- Phase 1 adds **only** `MarkdownEngine` — the README states this product has
  zero external dependencies, so ADR-0001's "dependency-light" posture holds:
  one reviewed, pinned package, no transitive graph.
- `MarkdownEngineCodeBlocks` (pulls HighlighterSwift) and `MarkdownEngineLatex`
  (pulls SwiftMath) are **deferred** and each needs its own ADR-0001 review
  before adoption.
- Pin exactly, matching the GRDB precedent in `Package.swift`.

## 6. Risks and how each is retired

### 6.1 Safe-editing invariants (PENTA-139) — HIGH

Conflict detection, recovery compare/restore, atomic writes, and file-operation
undo must behave identically. These live in `EditorDocumentModel`, but they are
*exercised through the surface*. **Retire:** re-run the entire PENTA-139 suite
against the engine-backed surface; every test passes unmodified or the migration
stops.

### 6.2 IME, undo, large-note latency (PENTA-137) — HIGH

The engine now owns marked-text handling, the undo stack, and layout. Our
direct-`MarkdownTextView` tests (marked text deferral, deferred replacement,
1 MiB note-open ≤100 ms, 20-keystroke p95 ≤16 ms) no longer target our code.
**Retire:** re-express these as behavior tests against the engine surface and
re-measure. The 1 MiB / 16 ms budgets are **exit criteria**, not aspirations —
the engine's `.fitsContent` height mode explicitly lays out the whole document,
so the default scrolling mode must be used for large notes and re-measured.

### 6.3 Accessibility — MEDIUM

The workspace guarantees a native AXTitle on every control (ArchitectureTests).
The engine's text view must expose a usable accessibility label/value and work
with VoiceOver. **Retire:** VoiceOver pass + keep the architecture test green.

### 6.4 Concealment / caret quality — MEDIUM

The reason to migrate is that the engine does §6.2-caret and concealment better.
**Retire:** Phase 0 side-by-side on the same note — the caret bug just fixed
(tall/mispositioned) must not reappear; markers reveal on the caret line with no
flicker; selection across concealed ranges behaves.

### 6.5 API churn (pre-1.0) — LOW/MEDIUM

v0.10.0 implies churn. **Retire:** pin exactly; wrap the engine behind our own
`EditorSurface`-style protocol so an API break is contained to one adapter file.

## 7. Phasing

**Phase 0 — Spike (throwaway branch, timeboxed).** Add `MarkdownEngine`, host
`NativeTextViewWrapper` behind a trivial binding to one note, no persistence.
Answer the §8 open questions, especially the non-undoable external-set (§5.1).
**Gate:** if the buffer bridge or a latency budget can't be met, stop and keep
the current editor. Output: a go/no-go note appended to this spec.

**Phase 1 — Parallel surface.** Introduce an `EditorSurface` protocol seam;
implement an engine-backed conformer alongside the existing one behind a build
flag. `EditorDocumentModel` unchanged. Port wiki-links, reading column, theme.

**Phase 2 — Validation.** Re-run/rewrite PENTA-137 and PENTA-139 against the
engine surface. Re-measure the latency budgets. VoiceOver pass. All green → go.

**Phase 3 — Cutover.** Make the engine surface default; delete
`ConcealingLayoutManager`, `LivePreviewConcealment`, `NativeMarkdownStyler`,
the concealment/marker code, and the reading-column workaround. Write ADR-0004
recording the reversal of ADR-0002 with the measured evidence.

**Phase 4 — Optional extras.** Evaluate `MarkdownEngineCodeBlocks` /
`MarkdownEngineLatex` and GFM tables, each with its own ADR-0001 review.

## 8. Open questions (Phase 0 must answer)

1. **Non-undoable external set.** Can a programmatic `text` binding change be
   applied *without* polluting the user's undo history (needed for reload /
   conflict resolution / recovery restore)? If not, what entry point exists?
2. **Byte-exact roundtrip.** Does the engine preserve the buffer byte-for-byte
   (line endings, trailing whitespace, front matter) so saves match disk? SPEC
   §22 forbids silent data loss.
3. **Caret offset fidelity.** Can we read/set the caret as a UTF-16 offset for
   `document.caretOffset` and daily-note/heading navigation?
4. **Large-note behavior.** Default scrolling mode 1 MiB open and keystroke p95
   — does it hold the PENTA-137 budgets?
5. **Front-matter styling.** Do we need a `MarkdownExtension` for YAML front
   matter, or does the engine leave it literal (acceptable) vs. mis-parse it?
6. **Diagnostics surface.** Invalid front matter / unresolved wiki links feed
   the status-bar issue count (SPEC §13). Does the resolver give us enough to
   keep that, or does diagnostics stay fully model-side?

## 9. Decision record placeholder

On cutover, add `docs/adr/0004-adopt-swift-markdown-engine.md` recording the
decision, the measured PENTA-137/139 results, and the dependency review, and
mark ADR-0002 superseded-in-part. Until then, ADR-0002 stands and the
hand-built editor remains the shipping surface.

## 10. Phase 0 spike evidence (2026-07-16)

**Decision: NO-GO. Keep the app-owned editor.**

The v0.10.0 source and an engine-backed tg-sidian surface established:

1. **External set / Undo:** a same-`documentId` binding replacement rebuilds the text storage
   without clearing that document's undo manager. The app adapter can make replacement safe by
   rotating the engine `documentId` only when `EditorDocumentModel` replaces its buffer; ordinary
   edits and autosaves retain one identity. The adapter also defers that rotation while AppKit has
   marked text.
2. **Byte-exact storage:** `NativeTextViewWrapper` keeps the binding in storage form and builds a
   separate display form for wiki links. CRLFs, front matter, trailing spaces, and opaque wiki ids
   remain in the bound model string.
3. **Caret / focus gate failed:** v0.10.0 has no public general selection binding, selection
   callback, or focus handle. A spike proved that the package's private native view can be found
   by traversing its AppKit hierarchy, but production code cannot rely on that private structure
   without violating the adapter and package boundaries. External replacement also moved native
   selection rather than preserving the app-owned UTF-16 range through public API.
4. **Front matter / diagnostics:** front matter stays literal and diagnostics remain model-side.
   The synchronous resolver API is sufficient for styling/navigation from an immutable snapshot
   of `VaultSessionModel.notes`.
5. **Dependency graph:** only the `MarkdownEngine` product is linked, but SwiftPM still resolves
   HighlighterSwift and SwiftMath because v0.10.0 declares both at package scope. The optional
   bridge products are not linked; the claim in §5.4 that the resolved graph has no transitive
   packages is therefore not literally true for this release.
6. **Large-note gate failed:** mounting the existing PENTA-137 1 MiB fixture (repeated task lines
   containing wiki links and inline code) remained CPU-bound for more than 90 seconds. A process
   sample placed the hot path in `InlineParser.scanLinkFamily` while SwiftUI/AppKit was laying out
   `NativeTextViewWrapper`. This exceeds both the 100 ms open budget and the spike's 5-second
   diagnostic ceiling by a wide margin; the 20-keystroke p95 could not be reached on that fixture.

The functional adapter and behavior tests were useful spike artifacts, but Phase 3 cutover must not
ship while items 3 and 6 remain unresolved. Acceptable ways to reopen the gate are an upstream release
that meets the unchanged fixture/budgets, or a separately reviewed fork/patch with the same
measurements and dependency review.

### Phase 0 outcome

The spike dependency and private-hierarchy adapter were removed after gathering the evidence.
`Package.swift` and `Package.resolved` do not contain swift-markdown-engine, the app-owned
`NativeEditorSurfaceAdapter` remains the shipping surface, and the existing PENTA-137/PENTA-139
validation harness remains authoritative. ADR-0002 records the accepted decision and exact
candidate revision. No ADR-0004 is created because Phase 3 cutover did not occur.

Reconsider this proposal only when a candidate release exposes public selection observation and
restoration plus focus control, and the unchanged 1 MiB surface fixture meets both the 100 ms open
budget and 16 ms keystroke p95 budget.

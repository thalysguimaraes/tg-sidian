# ADR-0002: Retain the app-owned TextKit editor surface

- **Status:** Accepted
- **Date:** 2026-07-16
- **Issue:** PENTA-137

## Context

tg-sidian needs a source-mode Markdown editor with native macOS text behavior, a single canonical plain-Markdown buffer, selection preservation across external refreshes, and a SwiftUI/AppKit focus bridge. The package survey named `swift-markdown-engine` as the first candidate and STTextView as a fallback, but required an acceptance spike before binding feature code to either package.

The checked-in implementation already contained a small `NSTextView`/TextKit 2 wrapper. This spike therefore compared three choices behind the app-owned `EditorSurface` contract:

1. `nodes-app/swift-markdown-engine`;
2. STTextView plus app-owned Markdown styling; and
3. the owned `NSTextView`/TextKit 2 wrapper plus app-owned Markdown styling.

Validation ran on macOS 26.5.2 (25F84), Xcode 26.6 (17F113), and Swift 6.3.3 on Apple silicon.

## Candidate and license review

### swift-markdown-engine

- Evaluated tag: `0.10.0`
- Exact evaluated revision: `665f7c46aa4933fdf714f558ef975067f7932421`
- Release date: 2026-07-15
- License: Apache-2.0
- Core product: 70 Swift source files; optional syntax/LaTeX products have separate dependencies, while the core target has no linked external dependency.
- Upstream validation: `swift test` passed 250 tests in 45 suites; clean-clone wall time was 28.257 seconds and test execution reported 0.313 seconds.

Apache-2.0 is acceptable: it permits commercial use, modification, and distribution, includes an express patent grant, and requires preservation of the license/notices when distributed. If this package is adopted later, include its license/NOTICE obligations and pin the exact accepted revision rather than a floating range while its API is young.

An isolated public-API adapter probe mounted `NativeTextViewWrapper` behind tg-sidian's `EditorSurface`. Text binding and external replacement compiled and ran, but revision `665f7c…` exposes no general selection binding/callback or public focus handle. After setting the native selection to `{10, 6}`, the app-owned adapter still observed `0..<0`; a full external binding replacement moved native selection to `{37, 0}` rather than preserving `{10, 6}`. Accessing the package's private native view by hierarchy inspection proved the behavior, but relying on that private hierarchy in production would violate the adapter and package boundaries.

Result: strong feature set and healthy tests, but it does not meet the mandatory selection/external-replacement/focus contract through its public API at the evaluated revision.

### STTextView

- Evaluated tag: `2.3.10`
- Exact evaluated revision: `8569251785daf1f0310eaa9235d1254264f0d249`
- Release date: 2026-04-29
- License: dual GPLv3 or paid commercial license (`NOASSERTION` in GitHub metadata)
- Package shape: 131 Swift source files plus `STTextKitPlus` and `CoreTextSwift` dependencies.
- Upstream validation on the reference environment: 93 XCTest tests ran with 4 failures, all `SizeToFitTests` comparisons on macOS 26.5; other undo/selection suites completed, but the exact revision's test run is red on the target toolchain.

GPLv3 is suitable only if the complete distributed application is licensed compatibly. tg-sidian has not made that distribution decision, and no commercial STTextView license is recorded. Pinning STTextView now would therefore add unresolved legal/ procurement work as well as two transitive dependencies. It is not an acceptable fallback unless the license is resolved first and a later revision passes the target toolchain.

### App-owned TextKit wrapper

No third-party editor package is distributed, so there is no package license or revision to pin. The selected runtime contract is Apple AppKit/TextKit 2 at the repository's pinned macOS 14 deployment floor in `Package.swift`; builds use the installed Apple SDK under its platform license. Candidate revisions above are pinned in this ADR only to make the comparison reproducible and are intentionally absent from `Package.swift`.

## Measured results

The committed harness uses the production `EditorHostView` and `NativeEditorSurfaceAdapter`. `./Scripts/validate-editor-engine.sh` runs the automated suite and builds the isolated `editor-engine-harness` executable.

| Probe | Result |
| --- | --- |
| IME/marked text | AppKit marked text remained active; external replacement deferred until `unmarkText`, then applied without a crash. |
| Selection | A non-empty UTF-16 range survived a larger replacement and clamped safely for a shorter replacement. |
| Undo grouping | Two native inserts in one `NSUndoManager` group undid together. |
| Find | Native Find bar and incremental search are enabled on the production text view. |
| Spellcheck | Continuous spelling and grammar are enabled; smart quote/dash/text replacement that can mutate Markdown is disabled. |
| Writing Tools | On macOS 15+, behavior is `.complete` and accepted results are `.plainText` only. |
| VoiceOver | Native `NSTextView` accessibility is retained with label `Note editor` and role description `Markdown source editor`. |
| Appearance | Effective-appearance changes cross the adapter boundary and reapply dynamic system colors. |
| 1 MiB load + style | Exactly 1,048,576 UTF-8 bytes: five warm runs 154.83–160.02 ms, median 158.37 ms. |
| 1 MiB keystroke dispatch | Twenty edits per run; p95 was 1.60–1.90 ms across five runs, median run p95 1.75 ms, below the 16 ms budget. Full restyling is coalesced after input pauses for buffers over 256 KiB. |
| Wiki links | Target/heading/alias resolve from visible raw markup; command-click remains an app callback. |
| Tasks | Raw task markers are detected and Return continues with an unchecked task. |
| Code fences | The complete fence, including body, receives monospaced source styling without buffer mutation. |
| External replacement | Selection is preserved, replacement does not enter user undo, and replacement waits for IME marked text. |
| SwiftUI/AppKit focus | An `NSHostingView` runtime test installs the adapter, transfers first responder, and adopts a refreshed model buffer with selection intact. |
| Adapter boundary | `NativeEditorSurfaceAdapter: EditorSurface` owns native details; feature/document state contains no third-party editor type. |

The focused tg-sidian run passes 10 tests in the `Native editor engine` suite. The complete repository run passes 46 tests in 7 suites; `swift build -c release` links both executables, and `Scripts/build-local-app.sh /tmp/tg-sidian-penta137.app debug` builds, ad-hoc signs, and verifies the sandboxed Xcode app.

## Decision

Retain the app-owned `NSTextView`/TextKit 2 implementation for the MVP. Do not add `swift-markdown-engine` or STTextView to `Package.swift`.

`NativeEditorSurfaceAdapter` is the binding point. It owns native view installation, text/selection projection, focus, IME-safe external replacement, undo-registration boundaries, native service configuration, and appearance/focus callbacks. `EditorHostView` consumes that adapter and `EditorDocumentModel`; workspace feature code and persistence do not consume editor-library types.

This decision supersedes the provisional package preference for the evaluated revision. It does not reject `swift-markdown-engine` permanently: the package can be reconsidered when its public API supports complete selection observation/restoration and focus control, and when the same harness passes without private-view introspection.

## Known gaps and mitigation

- **Physical IME UI:** automation covers marked-text state transitions, not every installed candidate window. Mitigation: run the Japanese/Chinese IME checklist before release.
- **VoiceOver output:** automation verifies the accessibility contract, not spoken navigation quality. Mitigation: perform the VoiceOver checklist on a release build.
- **Find/spelling/Writing Tools UI:** availability depends on system services, language, account, and hardware. Mitigation: manual release-machine checks; plain-text-only Writing Tools results protect canonical Markdown.
- **Large-note paint:** load/style is 158.37 ms median, while immediate edit dispatch is below 2 ms p95. Full lexical restyling is coalesced 180 ms after typing pauses for notes over 256 KiB; a future incremental/visible-range styler can replace it behind the same adapter if idle restyles are perceptible.
- **Markdown breadth:** the owned highlighter is intentionally lexical and the app-owned parser remains canonical for indexing/links/tasks. Complex CommonMark/GFM presentation is not promised by this editor decision; raw source is never rewritten.
- **Multi-range selection:** AppKit remains the authority where available, while the current app contract projects the primary UTF-16 range. Expand the app-owned selection value before exposing multi-cursor product behavior.
- **Writing Tools availability API:** configuration is deterministic, but service availability itself is environmental. The manual harness records an unavailable system as an environment gap, not a silent pass.

## Consequences

The production package remains dependency-light and license-simple, feature code has a real replaceable adapter seam, and the acceptance behaviors are regression-tested against the actual shipped surface. tg-sidian owns a modest amount of TextKit integration and lexical styling, but avoids binding canonical buffer/selection/focus semantics to private or missing third-party APIs.

Revisit this ADR when a candidate can pass `EditorEngineValidationTests` through only public APIs, has a compatible recorded license, passes its own tests on the supported Xcode/macOS matrix, and does not regress the 1 MiB keystroke budget.

## Amendment: TextKit 1 live preview (2026-07-16)

After the swift-markdown-engine migration spike was declined
([spec](../specs/markdown-engine-migration.md), Phase 0 no-go on selection API and 1 MiB
latency), the app-owned surface gained Obsidian-style live preview:

- `LivePreviewConcealment` lexically scans heading prefixes, wiki/markdown link syntax,
  emphasis, strikethrough, and inline-code delimiters (code fences and front matter stay
  literal), and `ConcealingLayoutManager` hides those marker glyphs everywhere except the
  caret's line. The backing string is never mutated; concealment is glyph-level only.
- This pins the editor to the **TextKit 1** stack, superseding this ADR's original
  "TextKit 2 wrapper" wording: only the classic `NSLayoutManager` exposes the `.null`
  glyph-property hook (`shouldGenerateGlyphs`), and TextKit 2 has no public equivalent —
  the same constraint that contributed to the migration no-go. `EditorEngineValidationTests`
  now asserts the TextKit 1 stack.
- Rendered wiki links show their alias and follow on plain click (`.link` attribute, removed
  on the revealed line so raw source stays editable); external Markdown links open in the
  browser. Cmd-click on raw source still follows.
- The styler now sets the text view's font/typing attributes and sizes the insertion point to
  the typing font on the baseline, fixing the caret drawing at Helvetica-12 metrics (wrong
  size and position) inside 15 pt / 1.6-leading lines.

The `EditorSurface` adapter seam, safe-editing model, and the PENTA-137/139 budgets are
unchanged; the 1 MiB load/style and keystroke suites pass against the concealing stack
(`LivePreviewTests` adds 12 behavioral cases). Re-measured on the 1 MiB fixture with
concealment active: load+style ≈ 1.31 s (validation ceiling 5 s; concealment scanning and
link attribution are one-time open costs), keystroke dispatch p95 ≈ 8.5 ms (budget 16 ms;
the reveal pass binary-searches a links-only index, and marker offsets shift in
`processEditing` between coalesced restyles). The original table's 158 ms / 1.75 ms figures
predate live preview.

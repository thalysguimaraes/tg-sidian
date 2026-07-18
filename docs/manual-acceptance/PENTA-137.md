# PENTA-137 native editor validation harness

## Run

```bash
./Scripts/validate-editor-engine.sh
swift run editor-engine-harness
```

The executable creates a temporary one-note vault and deletes it on exit. It does not read or mutate the user's vault. The production `EditorHostView` and `NativeEditorSurfaceAdapter` are used; the harness is not a second editor implementation.

Validation environment recorded for the ADR:

- macOS 26.5.2 (25F84), Apple silicon
- Xcode 26.6 (17F113)
- Swift 6.3.3

## Automated evidence

`Tests/TGSidianKitTests/EditorEngineValidationTests.swift` covers:

| Requirement | Automated probe |
| --- | --- |
| IME / marked text | Creates an AppKit marked-text range, proves an external buffer is deferred, commits composition, then applies the replacement. |
| Selection | Preserves and clamps a non-empty UTF-16 selection over complete-buffer replacement. |
| Undo grouping | Inserts a compound native edit and undoes it as one `NSUndoManager` group. |
| macOS Find | Verifies the production surface enables the native Find bar and incremental search. |
| Spellcheck | Verifies continuous spelling and grammar are enabled while Markdown-damaging substitutions stay disabled. |
| Writing Tools | On macOS 15+, verifies complete Writing Tools behavior with plain-text-only results. |
| VoiceOver | Verifies the native text accessibility label and Markdown role description. |
| Appearance | Drives `viewDidChangeEffectiveAppearance` through the adapter callback used to restyle dynamic system colors. |
| 1 MiB note | Loads and styles exactly 1,048,576 UTF-8 bytes; five warm runs measured 154.83–160.02 ms (median 158.37 ms). Twenty-edit keystroke-dispatch p95 was 1.60–1.90 ms across five runs (median 1.75 ms), below the 16 ms budget; large-note full restyling is coalesced after input pauses. |
| Wiki links | Resolves target, heading, and alias from visible source markup. |
| Tasks | Finds raw task markers and validates task-list Return continuation. |
| Code fences | Styles the complete fenced region, including its body, without changing source text. |
| External replacement | Defers during marked text; otherwise preserves selection and avoids registering the refresh in user undo. |
| SwiftUI/AppKit focus | Hosts the production representable in `NSHostingView`, transfers first responder through the app-owned adapter, then adopts an externally refreshed model buffer. |
| Adapter boundary | Verifies FeatureUI consumes `NativeEditorSurfaceAdapter: EditorSurface` and no third-party editor package/type appears in `Package.swift`. |

## Manual-only checklist

These checks depend on installed language services, audio/accessibility output, or visual system UI and therefore remain release-machine checks rather than deterministic CI assertions.

### 1. IME candidate UI and selection

1. Click **Focus Editor**.
2. Select a Japanese or Chinese input source.
3. Compose several characters without committing; move within the candidate list.
4. While marked text is visible, click **External Replace**, then finish/cancel composition.

Expected: the candidate window remains usable, marked text is not destroyed mid-composition, no crash occurs, and the external buffer appears only after composition ends. A valid selection remains visible.

### 2. Native undo/redo grouping

1. Type a short word continuously, pause, then type another word.
2. Use Edit › Undo and Edit › Redo.
3. Edit a task marker and a fenced-code line and repeat Undo/Redo.

Expected: edits group like a native `NSTextView`; raw Markdown delimiters return exactly and the external-replacement button itself does not pollute the typing undo stack.

### 3. macOS Find

1. Press Command-F and search for `Writing Tools`.
2. Use Return/Shift-Return to move between results, then Escape.

Expected: the native in-scroll-view Find bar appears, reports matches, preserves the buffer, and returns focus to the editor.

### 4. Spellcheck and Writing Tools

1. Control-click the sample misspelling `wrd` and apply a spelling suggestion.
2. Select a prose sentence and choose Edit › Writing Tools (macOS 15+ on supported hardware/account/locale).
3. Apply a rewrite.

Expected: spelling suggestions are available; Writing Tools availability follows the system; accepted output remains plain text and Markdown stays canonical. If the system says Writing Tools is unavailable, record the machine/account/locale as an environment gap rather than an editor failure.

### 5. VoiceOver

1. Enable VoiceOver.
2. Navigate to the editor and read several lines, the selection, a task, and fenced code.
3. Type, use Command-F, and leave/return to the editor.

Expected: VoiceOver announces **Note editor**, role description **Markdown source editor**, text/selection changes, and native Find controls. Focus does not become trapped.

### 6. Appearance and accessibility settings

1. Switch Light → Dark → Light while the harness is open.
2. Toggle Increase Contrast and Reduce Transparency.

Expected: body, links, tags, front matter, and code restyle immediately with dynamic system colors; text remains legible and selection/caret remain intact.

### 7. One-megabyte note

1. Click **Load 1 MiB**.
2. Scroll to several positions, select text, type, undo, run Find, and return to the top.
3. Note the harness-reported model-load time.

Expected: no beachball/crash or source corruption. CI's deterministic load+style budget is 5 seconds; the recorded machine median is 158.37 ms. The automated keystroke-dispatch p95 range is 1.60–1.90 ms against the 16 ms release-machine budget. Shared CI runners record this latency metric without gating because scheduler variance overwhelms the interaction budget. Smoothness, scrolling, and final paint feel remain manual release checks.

### 8. Wiki link, task, code fence, focus, and external refresh

1. Click **Reset Sample**.
2. Command-click `[[Notes/Editor#Focus|this wiki link]]`.
3. Edit/check tasks and edit inside the Swift fence.
4. Select a non-empty range, click **External Replace**, then click **Focus Editor**.

Expected: the footer reports target `Notes/Editor`; task/fence text stays raw; replacement preserves a valid selection; SwiftUI's button moves AppKit first responder to the editor.

## Manual residual to report

Until a release-machine pass is signed off, the residual is: physical candidate-window behavior for installed IMEs, audible VoiceOver navigation, visible Find/spelling/Writing Tools UI, visual appearance/contrast review, and subjective 1 MiB scrolling/typing smoothness. Automated plumbing and deterministic state transitions are covered in CI.

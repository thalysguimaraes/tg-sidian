# PENTA-139 — safe Markdown editing acceptance

## Automated safety evidence

Run from the repository root:

```bash
swift test
Scripts/validate-editor-engine.sh
```

`PENTA139SafeEditingTests` deterministically verifies:

- clean external revisions replace the model buffer while preserving its caret; dirty buffers remain local and enter the Compare / Keep Mine / Reload state machine;
- Compare shows base, local, and disk revisions, and an editable merged draft uses explicit conflict markers when both sides diverge;
- the latest edits made while conflicted are the bytes written by Keep Mine;
- UTF-8 content (including emoji and Japanese input) survives atomic save, journal encode/decode, recovery, and editor statistics using native UTF-16 selection offsets;
- saves write and fsync a complete sibling temporary, use `renamex_np(RENAME_SWAP)` as a filesystem compare-and-swap for existing notes, roll a late external revision back into place, and use `RENAME_EXCL` for collision-safe creation;
- an injected write failure leaves the original canonical file, removes the temporary, and retains a complete durable recovery record that can be restored;
- a crash after replacement but before journal cleanup is recognized by matching complete disk bytes and safely pruned;
- malformed journal JSON is quarantined without hiding other recoverable edits;
- rename, move, and delete update the SQLite index; delete is an atomic move to a non-Markdown sibling until Undo is restored or dismissed, so a crash cannot lose the removed bytes;
- native completion ranges, task toggling, list continuation, code-fence closure, TextKit Undo, Find/spelling/Writing Tools configuration, IME deferral, selection, and accessibility stay behind the native responder/editor adapter;
- invalid front matter plus unresolved and ambiguous wiki links appear as note diagnostics without making the editor read-only;
- a 1 MiB note-open read is measured against a deterministic 100 ms p95 test budget; the existing 1 MiB keystroke dispatch test remains below the 16 ms p95 budget.

### Verification record — 2026-07-16

- `swift test`: **66 tests / 9 suites passed**; 1 MiB load+style **173.76 ms**, keystroke dispatch **1.94 ms p95**, note-open **0.72 ms p95**.
- `swift build -c release`: passed.
- `Scripts/validate-editor-engine.sh`: **10 editor tests passed**; validation harness built.
- Xcode `TGSidian` Debug and Release builds with signing disabled: `BUILD SUCCEEDED` for both configurations.
- `Scripts/build-local-app.sh .artifacts/tg-sidian-penta139.app release`: passed and produced the release app bundle.
- The only Xcode diagnostic was the expected AppIntents metadata skip because this app has no AppIntents dependency; no Swift warning or test failure remained.

## External-change UI

1. Open a note and leave it unedited.
2. Change the same file in another editor.
3. Expected: tg-sidian reloads the complete disk revision, keeps the native selection when it still fits, and remains **Saved**.
4. Type a local edit, then change the file externally again before autosave completes.
5. Expected: a persistent conflict banner appears and autosave pauses. The local editor bytes remain visible.
6. Choose **Compare…**.
7. Expected: local and disk versions are selectable side-by-side. The merged draft is editable; divergent versions contain visible conflict markers rather than an unsafe automatic merge.
8. Exercise **Keep my edits**, **Reload from disk**, and **Use merged draft** on separate conflicts.
9. Expected: each choice is explicit, atomic, and reflected by the status text and on-disk UTF-8 file.

## Recovery UI

1. Use a debug-injected write failure or make the vault temporarily read-only immediately before an autosave.
2. Expected: the buffer remains editable, a persistent **Save failed** banner offers **Retry**, and the previous canonical file remains complete.
3. Relaunch with write access restored.
4. Expected: a recovery banner names only the relative note filename and offers **Compare…**, **Restore**, and **Dismiss**.
5. Compare, then restore.
6. Expected: recovered and current disk versions are both selectable; Restore atomically writes the recovered bytes and refreshes search, backlinks, and diagnostics.

## Rename, move, delete, and Undo

1. Open a clean note and use its sidebar context menu to rename it.
2. Move it to another vault-relative folder.
3. Expected: existing destinations are never overwritten, the open editor follows the new path, and search/sidebar/backlinks update.
4. Delete the note and cancel once to verify destructive confirmation.
5. Confirm deletion.
6. Expected: the note disappears from canonical Markdown discovery and the index, while an **Undo** recovery banner remains.
7. Invoke Edit > Undo (or the banner's **Undo**) before dismissing recovery.
8. Expected: the exact staged bytes return to the original path and the index/editor reopen them. If another file now occupies that path, Undo stops with both versions preserved.

## Native macOS checks (OS-only)

These require a real app window and installed macOS services, so automated tests cover configuration and deterministic state transitions while release acceptance covers presentation:

- compose Japanese or Chinese marked text while an external clean refresh arrives; the candidate window must remain active and the refresh must apply only after commit;
- use Shift/Option/Command selection, drag selection, copy/paste, Services, native Undo/Redo, and the macOS Find bar;
- verify misspelling underlines, Writing Tools on macOS 15+, and that Markdown delimiters are not rewritten by smart quotes/dashes;
- type `[[` and use arrow keys, Tab/Return, Escape, and VoiceOver in the native completion popup; accepted entries close with `]]` in one Undo step;
- press Return after bullets, ordered items, tasks, empty list items, and opening backtick/tilde fences; verify native Undo groups each command as one edit;
- use Command-Return / **Markdown > Toggle Task** and confirm the text mutation participates in TextKit Undo;
- navigate the conflict, recovery, diagnostics, and destructive-confirmation controls with keyboard and VoiceOver; status must never be communicated by color alone;
- repeat appearance, Increase Contrast, Reduce Transparency, Reduce Motion, and 200% text-size checks;
- on release hardware, record 1 MiB note-open and keystroke samples and confirm no beachball, selection jump, IME loss, or audible VoiceOver regression.

## Residual release checks

Physical IME candidate-window placement, audible VoiceOver phrasing, visible Find/spelling/Writing Tools UI, system alert/context-menu presentation, and subjective large-note scrolling remain OS-only release checks. No network service or user vault is required for this procedure.

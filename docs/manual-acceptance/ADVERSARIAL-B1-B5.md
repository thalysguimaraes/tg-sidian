# Final adversarial review remediation — B1 through B5

Date: 2026-07-16

## Result

All five blocking findings in `.artifacts/adversarial-review-final.md` are fixed and covered by real package adapters in `AdversarialBlockingRegressionTests.swift`. Canonical Markdown remains untouched by index migration/rebuild logic; conflict navigation preserves the in-memory buffer and a durable app-support recovery record.

## B1 — duplicate normalized path/title dictionary trap

**Fix**

- Added the shared `AppCore.NotePathIdentity` filesystem/link key: Unicode precomposition plus case folding only, with no whitespace trim and no diacritic folding.
- `VaultActor` discovery/collision checks, `NoteID`, `IndexActor` path/filename/title link resolution, and `VaultSessionModel` wiki-link navigation now use that shared identity rule.
- Replaced `Dictionary(uniqueKeysWithValues:)` in `refreshLinkResolutions` with `Dictionary(_:uniquingKeysWith:)` and a deterministic lexical ID tie-break, so a legacy/external duplicate can never trap the process.

**Exact proof**

`B1 legal whitespace-distinct note paths never trap link resolution` creates the reproduced crash pair `Note.md` / `Note .md` plus ` Note.md`, rebuilds through the real `VaultActor` and SQLite `IndexActor`, resolves links, and asserts four independent rows. It passed in 0.020 seconds; no `fatalError` remains on this path.

## B2 — NoteID diacritic collision and broken reconciliation

**Fix**

- Removed `.diacriticInsensitive` from NoteID/filesystem identity, so `Cafe.md` remains `cafe` while `Café.md` becomes `café`.
- Kept search normalization diacritic-insensitive in a clearly separate `searchKey`; search friendliness no longer controls filesystem identity.
- Reconciliation now compares both stored path and fingerprint. This migrates a legacy collided row even when its fingerprint happens to equal the newly canonical file, before inserting the second accented row.

**Exact proof**

`B2 accented filenames keep distinct stable rows across incremental and reconcile paths` first preserves the historical `cafe` row, incrementally adds `Café.md`, verifies two rows, reconciles, then directly seeds the exact legacy silent-loss database shape (`id=cafe`, `path=Café.md`, no `café` row). `restoreOrRebuild` repairs it to `Cafe.md -> cafe` and `Café.md -> café`; the test passed in 0.018 seconds.

## B3 — conflicted navigation discarded unsaved work

**Fix**

- `SaveCoordinator.checkpointRecovery` durably stores the latest conflict buffer before superseded records are removed.
- External edit/deletion detection checkpoints immediately; a navigation/focus flush checkpoints later edits made while the conflict is visible.
- `EditorDocumentModel.canReplaceBuffer` is false for dirty, saving, conflicted, and write-failed states.
- Note, daily-note, and vault switching refuse to replace the document until save/reload/merge/recovery is explicit.
- Keep Mine, Reload, Merge, and successful save clear only the conflict checkpoint they resolved.

**Exact proof**

`B3 conflicted navigation keeps the buffer and durably checkpoints latest edits` uses the real `VaultSessionModel`, `VaultActor`, `SaveCoordinator`, journal, and index. It reproduces A.md local edits plus an external rewrite, edits the conflicted buffer again, attempts to open B.md, and verifies: A remains open, the latest local bytes remain in the buffer, disk still contains the external bytes, and exactly one durable recovery record contains the latest local bytes. Explicit Reload clears recovery and only then allows B.md to open; the test passed in 0.012 seconds.

## B4 — symlink root discovered zero notes and dropped FSEvents

**Fix**

- `VaultRoot` exposes its canonical `resolvedURL`.
- `VaultActor.rootURL` is the validated resolved root, so enumeration, collision checks, and index watcher setup all target the directory that actually contains the notes.
- `FSEventsVaultWatcher` resolves both its root and callback paths before containment/prefix conversion.

**Exact proof**

`B4 symlink vault discovery, clean reload, FSEvents, and status use the resolved root` creates `Linked Vault -> Real Vault`, then uses real enumeration, session load, SQLite indexing, and the production FSEvents stream. It verifies two initial files, truthful `.idle(noteCount: 2)`, a clean external edit reloading the open buffer, a newly created third note appearing through FSEvents, and `.idle(noteCount: 3)`; the test passed in 0.337 seconds.

## B5 — hosted release runner lacked Swift 6.2

**Fix**

- Release CI now pins `runs-on: macos-26`.
- `maxim-lobanov/setup-xcode@v1` explicitly selects Xcode `26.6`.
- A fail-fast Python version assertion requires Swift 6.2 or newer before `swift test`.

**Exact proof**

`B5 release workflow pins Xcode 26.6 and asserts Swift 6.2` checks the tools-version/workflow contract and passed in 0.001 seconds. The workflow parses as YAML locally, and its assertion passes against Apple Swift 6.3.3; the remaining external check is the next hosted GitHub Actions execution because hosted runners cannot be invoked locally.

## Full verification record

- `swift test`: **77 tests / 11 suites passed**, no errors or unexpected warnings.
- Performance: 1 MiB load+style **193.71 ms**; keystroke dispatch **1.76 ms p95**; note-open **1.08 ms p95**.
- `Scripts/validate-editor-engine.sh`: **10 tests passed**, harness built, load+style **160.91 ms**, keystroke dispatch **1.64 ms p95**.
- `swift build -c release`: passed.
- Xcode `TGSidian` Debug: `BUILD SUCCEEDED`.
- Xcode `TGSidian` Release: `BUILD SUCCEEDED`.
- `Scripts/build-local-app.sh .artifacts/tg-sidian-b1-b5.app release`: passed.
- `codesign --verify --deep --strict`: app is valid on disk and satisfies its Designated Requirement; identifier `design.thalys.tg-sidian`, ad-hoc signature.
- `git diff --check`: passed.

## Residual

No known code or test blocker remains for B1-B5. Only the external hosted GitHub Actions run is not locally executable; its runner, Xcode selection, and fail-fast Swift version contract are deterministic and statically regression-tested.

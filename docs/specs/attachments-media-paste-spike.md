# Attachments and media paste spike (P1)

Attachments need to be designed together with paste/import, not as a folder-only preference.

## Required scope

- Define a paste/import pipeline for images, PDFs, audio, and arbitrary files, including naming,
  duplicate handling, atomic writes, undo/recovery, and security-scoped vault access.
- Resolve the configured destination relative to the current note, vault root, or a dedicated
  attachments folder; create it safely and keep it out of new-note/template discovery where
  appropriate.
- Insert a portable Markdown reference after the write succeeds. Image previews, drag/drop,
  transcoding, and non-file clipboard providers need their own acceptance criteria.
- Decide how the index treats binary files and whether copied files should be included in Git
  workflows, backups, and vault-trash behavior.

## Recommendation

First spike a single PNG paste with an explicit destination folder, collision-safe filename,
atomic write, Markdown insertion, cancellation, and a 10 MB size guard. Confirm sandbox and
Finder behavior on a real security-scoped vault. Then split production work into import pipeline,
editor insertion/undo, and preview/indexing slices. Do not expose an attachments-folder setting
until that first vertical slice defines what the setting actually controls.

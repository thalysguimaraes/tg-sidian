# ADR-0003: Production derived index with GRDB, SQLite, FTS5, and FSEvents

- **Status:** Accepted
- **Date:** 2026-07-16
- **Linear:** PENTA-138

## Context

ADR-0001 deliberately shipped a deterministic in-memory index with an optional JSON snapshot. That seam proved search, backlinks, graph, and canonical-file safety, but a whole-index JSON rewrite and a snapshot without migrations are not production storage for a 10,000-note vault. `SPEC.md` §9 requires a disposable index for title, path, tags, headings, front matter, body, links, diagnostics, reconciliation, and external file changes.

Markdown in the authorized vault remains the sole canonical note store. The database is derived data under Application Support (`Vaults/<vault-id>/index.sqlite`), outside the vault, and can always be quarantined, deleted, or rebuilt.

## Decision

Use [GRDB.swift](https://github.com/groue/GRDB.swift) with system SQLite and FTS5. SwiftPM pins **exactly 7.11.1**, reviewed at tag commit `b83108d10f42680d78f23fe4d4d80fc88dab3212`; `Package.resolved` records the same revision. The reviewed patch is migration-registration performance only, and the exact pin prevents an unreviewed database/migration behavior change.

`IndexActor` owns one `DatabaseQueue`, all mutations, reconciliation, and link resolution. `VaultActor` remains the only filesystem boundary. Rebuild parses canonical snapshots first and swaps all derived rows in one transaction, so cancellation preserves the previous complete database.

### Schema and migrations

GRDB records applied identifiers in `grdb_migrations`.

#### `v1-core`

- `notes`
  - primary identity: `id` (normalized vault-relative path without extension)
  - result fields: `path`, `title`, `tags_json`, `note_type`, `modified_at`
  - searchable fields: `tags`, `headings`, `front_matter`, `body`
  - deterministic rank/filter fields: normalized title/path/tags/headings/front matter/type
  - reconciliation fields: byte count, modification date, SHA-256 content hash
  - recovery/graph fields: encoded `IndexedNote`, diagnostic count, unresolved-link flag
- `links`
  - `(source_id, ordinal)` primary key, raw target, heading, source line
  - derived target and `resolved`/`unresolved`/`ambiguous` status
- `metadata`
  - key/value derived state, currently the last durable FSEvents event ID
- indexes on normalized path/type, modification date, and backlink target/status

#### `v2-fts5`

- external-content `note_fts` virtual table over title, path, tags, headings, front matter, and body
- `unicode61 remove_diacritics 2` tokenizer
- insert/update/delete triggers that keep FTS rows transactionally aligned with `notes`
- one FTS rebuild command to populate rows when migrating an existing `v1-core` database

A failed open, `PRAGMA quick_check`, or migration quarantines `index.sqlite` plus its WAL/SHM companions to `index.corrupt-<uuid>.sqlite*`. A new schema is then migrated and rebuilt from Markdown. No recovery path moves, rewrites, or deletes a vault file.

### Ranking contract

FTS5 selects candidates and `bm25` breaks ties inside a tier. The explicit, stable tiers are:

1. exact normalized title — `1,000,000`
2. normalized title prefix — `700,000`
3. title substring — `500,000`
4. exact tag — `450,000`
5. exact heading — `400,000`
6. heading substring — `250,000`
7. path substring — `150,000`
8. front-matter substring — `100,000`
9. body-only candidate — `50,000`

Further ties sort by FTS rank, descending modification date, then case-insensitive and byte-stable path. Results expose title, canonical relative path, a body excerpt, type, tags, and modification date. Arrow keys move a persistent result selection; Return opens the selected Markdown path; Tab navigation and VoiceOver actions remain available.

### Reconciliation and events

Initial vault open performs reconciliation (or a full rebuild for a new/quarantined DB). `FSEventsVaultWatcher` uses recursive file events, root watching, no-defer delivery, and a persisted event ID.

- create/edit: read and upsert the canonical snapshot;
- move/rename: FSEvents reports old and new paths independently; a missing old path is removed and an existing new path is upserted;
- delete: remove the derived note row;
- directory events, dropped events, wrapped IDs, or root changes: run a full reconciliation scan;
- app-authored saves still upsert immediately, while later FSEvents delivery is idempotent.

Events are injectable as `VaultFileEvent` for deterministic create/edit/move/rename/delete/gap coverage. The real adapter performs no database or vault mutation itself.

### Progress, cancellation, and rebuild

Initial reconciliation and rebuild emit `IndexProgress` at start, every 25 files, and completion. The sidebar shows completed/total progress and a Cancel action. Cancellation is checked between canonical reads; the database transaction happens only after parsing succeeds. “Rebuild Index” and “Cancel Indexing” are also exposed in the Vault menu.

### Performance budget

The automated budget is **under 100 ms** for the first exact-title result after indexing a deterministic 10,000-note fixture. Three 2026-07-16 local debug verification runs measured **1.060–1.128 ms** (`0.001059541`–`0.001127958 seconds`); the complete 10k test, including fixture creation and rebuild, took 8.7–9.0 seconds. The test measures the search call only and verifies `Note 9999` is first.

## Consequences

- Search and link state are restart-safe, transactional, and disposable.
- FSEvents is advisory rather than trusted; reconciliation remains the correctness mechanism.
- Large-vault work stays behind actor boundaries and stale UI queries are discarded after cancellation.
- The app now has one reviewed third-party runtime dependency. Upgrading GRDB requires reviewing its changelog, changing the exact pin, updating this ADR, resolving `Package.resolved`, and running schema/recovery/performance tests.

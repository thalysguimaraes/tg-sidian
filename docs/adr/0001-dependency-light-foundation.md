# ADR-0001: Dependency-light Obsidian-client foundation

- **Status:** Accepted for the clarified tg-sidian MVP
- **Date:** 2026-07-15

## Context

tg-sidian is a native macOS client for an existing Obsidian-compatible Markdown vault. The Paper file also contains tg-inspo, a different product. Only the `tg-sidian — Main Window` artboard is authoritative for this repository.

The MVP needs reliable local Markdown parsing, filesystem access, search, editing, backlinks, daily notes, and a local graph. Resolving every eventual third-party dependency in the first slice would couple domain safety to package availability and unfinished app-shell work.

Earlier foundation work also introduced modules and models for tg-inspo-derived capture, Inbox triage, typed collections, custom Settings, and optional AI. Those capabilities do not belong to the clarified tg-sidian MVP and have been removed rather than retained as speculative architecture.

## Decision

Create one Swift 6 multi-target package targeting macOS 14. Keep public domain values `Sendable`, isolate mutable file/index/save/layout state in actors, and depend only on Apple frameworks in the foundation.

For this phase:

- keep Markdown files as the only canonical note store;
- parse the required front matter, wiki-link, task, heading, and tag subset while preserving raw source;
- use a deterministic in-memory index with an optional disposable snapshot and ranked search;
- implement backlinks, daily-note creation, and a bounded local graph because they are present in the sole tg-sidian design;
- expose module and protocol boundaries that permit production index, parser, filesystem-watching, and editor implementations to replace foundation implementations;
- instrument only design-backed client operations;
- do not add capture, Inbox triage, typed product collections, recommendation/commerce, AI-provider, or tg-inspo navigation abstractions.

## Consequences

The package builds and tests without fetching third-party code, and canonical Markdown remains the source of truth. The disposable foundation index is not a promise that its current storage format is production-ready for a very large vault. Complex YAML/GFM constructs remain raw and produce diagnostics rather than being destructively rewritten.

Production integration may still add GRDB/FTS5, a full parser, FSEvents reconciliation, a native editor adapter, app signing, and update infrastructure behind the existing seams. Adding any new product screen or workflow requires a tg-sidian-specific design/spec change; presence in the shared tg-inspo Paper file is not evidence of scope.

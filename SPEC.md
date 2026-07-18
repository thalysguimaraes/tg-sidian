# tg-sidian — MVP Product & Engineering Specification

**Status:** Clarified MVP baseline  
**Product:** Native macOS Obsidian client  
**Minimum OS:** macOS 14  
**Language/toolchain:** Swift 6.x, Swift Package Manager  
**Only design reference:** [tg-sidian — Main Window](https://app.paper.design/file/01KXDG7D6RGPGQ3N7YZAPBRCG3/1-0/1OD-0)

## 1. Product identity and source of truth

tg-sidian is a native macOS client for an existing Obsidian-compatible, folder-backed Markdown vault. It is not a shopping, inspiration, recommendation, or read-later product.

The Paper file is named `tg-inspo`, but it contains two different products. For tg-sidian, **only** the artboard named **“tg-sidian — Main Window”** is authoritative. Every other artboard in that file belongs to tg-inspo and is excluded from this specification, including:

- Buying List
- Inbox
- Capture Widget
- Tools and Bookmarks
- Reading List
- Watches
- Home
- Settings

Authority order for MVP decisions:

1. This clarified specification.
2. The single linked tg-sidian artboard.
3. Existing code that still agrees with 1 and 2.

Earlier plans, analyses, issue descriptions, or implementations derived from the other eight artboards are superseded.

## 2. MVP promise

Open a local Obsidian vault, browse its folders and Markdown notes, search it, edit notes safely, navigate daily notes, and understand the current note through backlinks and a bounded local graph.

Markdown files in the selected vault remain canonical. tg-sidian may build disposable local indexes and local preferences, but it must not require a hosted account, proprietary document format, or network connection.

## 3. MVP scope

### 3.1 Required capabilities

- Select and authorize a folder-backed Markdown vault.
- Restore access to a previously selected vault.
- Recursively discover `.md` and `.markdown` files while respecting ignored paths.
- Browse folders and notes in the left sidebar with disclosure state and note counts.
- Search note titles, paths, tags, headings, front matter, and body text.
- Open, create, edit, rename, move, and delete Markdown notes safely.
- Preserve unknown front-matter fields and ordinary Markdown source.
- Support source-of-truth Markdown editing with native selection, undo, find, spellcheck, keyboard input, and accessibility.
- Parse headings, tags, tasks, front matter, and Obsidian-style wiki links.
- Resolve wiki links deterministically and surface ambiguous or unresolved links.
- Create or open daily notes from the calendar and browse recent daily notes in the vault tree.
- Show backlinks for the current note.
- Show a bounded, interactive local graph for the current note.
- Detect external edits and prevent silent data loss.
- Keep the local index rebuildable from canonical Markdown.
- Work offline.

### 3.2 Explicitly out of scope

The following are not part of the tg-sidian MVP unless a future tg-sidian design and specification explicitly add them:

- tg-inspo Home, Inbox, Buying List, Tools and Bookmarks, Reading List, or Watches screens.
- Typed shopping, bookmark, reading, watch, idea, or meeting collection views.
- A global capture widget, capture-to-Inbox workflow, or Inbox triage.
- Recommendation engines, commerce data, price badges, cover-card feeds, or browser companions.
- AI providers, API-key storage, AI metadata suggestions, or background AI indexing.
- A custom Settings screen copied from tg-inspo.
- Hosted accounts, cloud vaults, or a proprietary sync service.
- Mobile clients.
- Real-time collaboration or CRDT synchronization.
- Obsidian plugin execution or arbitrary JavaScript.
- Full compatibility with every Obsidian plugin or theme.
- Git history management or automatic merge-conflict resolution.

Basic local preferences required by the main window—appearance, editor font size, editor line width, and ignored paths—may use native platform storage without introducing a new product screen.

## 4. Core journeys

1. **Open a vault:** choose a folder, grant access, index it, and restore it on the next launch.
2. **Browse:** expand folders in the sidebar and open a real Markdown note.
3. **Search:** invoke vault search, type a phrase, and open a result using the keyboard.
4. **Write:** edit Markdown and save atomically with visible save/index status.
5. **Use today’s note:** choose a date in the inspector calendar and open or create the configured daily note.
6. **Follow context:** inspect backlinks or the local graph and navigate to a connected note.
7. **Recover safely:** resolve external-write conflicts without silently discarding either version.

## 5. Main-window contract

The single Paper artboard defines a three-region macOS window.

### 5.1 Left vault sidebar

- Native macOS traffic-light/titlebar area.
- Vault name and vault-switch action.
- `Search vault` field with Command-K shortcut hint.
- Folder/note hierarchy only; it is not a product-destination menu.
- Folder disclosure controls and note counts.
- Selected-note treatment matching the design.
- Footer showing note count and local index/filesystem status.

The footer text `synced` means the local derived index is current with the filesystem. It does not imply a cloud-sync service.

### 5.2 Center editor

- Back and forward navigation.
- Note tabs and new-tab affordance as shown.
- The current Markdown note as the primary content.
- Readable centered line width derived from the design.
- Wiki links, headings, lists, tasks, code, and front matter remain backed by plain Markdown.
- Status bar with backlinks, edit state, word count, character count, save state, and applicable local editor indicators.

Rich visual treatment must never replace the canonical Markdown representation.

### 5.3 Right inspector

- Inspector toolbar.
- Daily-note calendar.
- Backlinks for the current note.
- Bounded local graph for the current note with depth and fit controls.

The artboard visibly shows Calendar and Local Graph and references backlinks in the editor metadata/status. Backlinks may occupy the inspector’s available middle region; no unrelated tg-inspo panel may be substituted.

### 5.4 Visual baseline

Implementation should translate exact values from the linked artboard where practical. The current reference uses a restrained light macOS palette, Inter/system typography, compact sidebar rows, subtle separators, and blue-gray selection/accent states. Native accessibility settings take precedence over pixel matching.

## 6. Vault and note model

### 6.1 Canonical storage

- The authorized filesystem folder is the vault.
- Markdown files are the source of truth.
- Derived indexes live outside the vault and may be deleted and rebuilt.
- tg-sidian must not create product-specific collection databases or proprietary note records.

### 6.2 Note identity

- A note is identified by its normalized vault-relative path without the Markdown extension.
- Display title precedence: front-matter `title`, first level-one heading, filename.
- Unknown front matter and body bytes are preserved whenever tg-sidian changes a known field.

### 6.3 Links

Support `[[Note]]`, `[[Folder/Note]]`, `[[Note#Heading]]`, and `[[Note|Alias]]`.

Resolution order:

1. exact normalized relative path;
2. unique filename match;
3. unique display-title match;
4. otherwise unresolved or ambiguous.

The client must never silently choose among ambiguous candidates.

## 7. Architecture

Use one Swift package with inward dependency flow:

- **AppCore** — identifiers, models, protocols, preferences, errors, recovery contracts.
- **InstrumentationKit** — privacy-safe performance instrumentation.
- **SecurityKit** — vault authorization/bookmark persistence only.
- **MarkdownKit** — Markdown/front-matter parsing and non-destructive updates.
- **VaultKit** — the sole filesystem boundary, atomic writes, moves, daily notes, recovery journal.
- **IndexKit** — disposable search/link/backlink index.
- **GraphKit** — bounded local-graph extraction and layout.
- **FeatureUI** — the single design-backed workspace UI and main-actor state.
- **TestSupport** — temporary fixture-vault helpers.

There is no CaptureKit, collection feature module, AI provider layer, or tg-inspo destination router in the MVP architecture.

Mutable filesystem, index, save, and graph-layout state should remain actor-isolated. Feature code consumes app-owned protocols rather than third-party types.

## 8. Editing and persistence

- Use a native AppKit/TextKit-backed editing surface inside SwiftUI as needed.
- Maintain a single plain-Markdown buffer.
- Preserve selection when external state refreshes the editor.
- Autosave atomically using a sibling temporary file and replace.
- Compare the expected fingerprint before replacing an externally changed file.
- On conflict, preserve both versions and require an explicit keep-local, reload-disk, or merge choice.
- Recovery journals must never become a second canonical store.

## 9. Index, search, backlinks, and graph

### 9.1 Index

The index is derived and disposable. It may store note identity, path, title, tags, headings, searchable body text, modified time, outgoing wiki links, and parse diagnostics.

Initial indexing and reconciliation must not modify source files. External create, edit, rename, move, and delete events must update or rebuild derived state.

### 9.2 Search

- Command-K focuses vault search.
- Results include title, path, excerpt, and relevant metadata.
- Exact title and title-prefix matches rank above body-only matches.
- Stale queries are cancellable.

### 9.3 Backlinks

Backlinks identify source note, excerpt, heading context when available, and target. Selecting a backlink opens its canonical Markdown note.

### 9.4 Local graph

- Rooted at the current note.
- Default depth 2.
- Bounded to 150 nodes and 500 edges.
- Cancellation-aware and deterministic for the same graph snapshot.
- Keyboard/VoiceOver alternatives expose the same connections as a navigable list.

## 10. Daily notes and calendar

- Daily-note folder, filename pattern, template, locale, and time zone are local preferences.
- Opening a date is idempotent.
- If a note does not exist, create it atomically from the template or a minimal heading.
- The calendar and recent daily notes open canonical Markdown files in the same editor.

## 11. Privacy and security

- No note content leaves the Mac in MVP.
- No analytics, AI request, recommendation request, or commerce lookup is required.
- Persist only security-scoped vault authorization and non-secret local preferences.
- Resolve symlinks and verify containment before filesystem access.
- Never log note bodies, front matter, vault names, or full paths.

## 12. Accessibility and performance

- All core journeys are keyboard operable.
- Custom controls have VoiceOver labels, values, traits, and actions.
- Respect Increase Contrast, Reduce Transparency, Reduce Motion, and system appearance.
- Do not encode status by color alone.
- Keep large-vault work off the main actor and cancel stale search/graph work.
- Instrument launch, note open, save, parse, indexing, search, and graph layout without logging user content.

## 13. Error and recovery behavior

The client must provide clear local recovery for:

- missing or revoked vault permission;
- unreadable or malformed Markdown;
- index corruption;
- external edits during an unsaved local edit;
- disk-full or write failure;
- unresolved or ambiguous links;
- graph-layout failure.

Index or graph failure must not block direct Markdown editing. Destructive file actions require confirmation and should participate in Undo where feasible.

## 14. Verification

Required automated coverage:

- relative-path containment and symlink escape rejection;
- Markdown/front-matter preservation;
- wiki-link resolution and backlinks;
- atomic save, external conflict, and recovery journal;
- index rebuild, search ranking, and corruption recovery;
- daily-note idempotence;
- bounded deterministic local graph;
- module dependency direction;
- main-window navigation that exposes only design-backed routes.

Release verification must prove that a fixture vault can be opened, indexed, searched, edited, navigated by date/backlink/graph, closed, and restored without modifying unrelated files.

## 15. MVP definition of done

- The app opens and restores an authorized Obsidian-compatible vault.
- The main window matches the linked tg-sidian artboard’s structure and hierarchy.
- The sidebar contains the vault tree, not tg-inspo product destinations.
- A user can search, open, edit, and safely persist real Markdown files.
- Daily notes, backlinks, and the local graph navigate to canonical notes.
- The index can be deleted and rebuilt without data loss.
- The app works without network access, accounts, AI, capture, Inbox triage, or typed collections.
- Automated tests cover canonical-file safety and the design-backed MVP journeys.

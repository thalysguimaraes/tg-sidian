<div align="center">
  <img src="docs/assets/tg-sidian-icon.png" width="128" height="128" alt="tg-sidian app icon">

  <h1>tg-sidian</h1>

  <p><strong>A fast, native macOS workspace for your Markdown vault.</strong></p>
  <p>Open a folder, write in plain Markdown, and keep full ownership of every note.</p>

  <p>
    <a href="https://github.com/thalysguimaraes/tg-sidian/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/thalysguimaraes/tg-sidian/actions/workflows/ci.yml/badge.svg"></a>
    <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple">
    <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white">
  </p>
</div>

tg-sidian is a privacy-first Markdown editor built in SwiftUI and AppKit. It works
directly with an existing folder-backed vault: no import, proprietary database,
account, or cloud service required.

> **Early release:** tg-sidian is under active development. Back up important vaults
> and review the [known scope](#current-scope) before making it your primary editor.

## Highlights

- **Native macOS experience** — a focused three-pane workspace designed for the Mac.
- **Your files stay yours** — canonical Markdown remains the source of truth.
- **Fast local search** — a disposable SQLite/FTS5 index can always be rebuilt from
  the vault.
- **Safe editing** — atomic writes, external-change detection, recovery journaling,
  and conflict handling help prevent silent data loss.
- **Connected notes** — wiki links, backlinks, tags, daily notes, and a bounded local
  graph are built in.
- **Thoughtful preferences** — appearance, editor behavior, files and links, sidebar,
  daily notes, hotkeys, and extension host settings live in one native settings
  window.
- **Sandboxed by default** — tg-sidian only receives access to folders you explicitly
  choose.

## Requirements

- macOS 14 Sonoma or newer
- Xcode 26.6 / Swift 6.2 to build from source

## Build from source

Clone the repository and run:

```bash
swift test
xcodebuild \
  -project TGSidian.xcodeproj \
  -scheme TGSidian \
  -configuration Debug \
  build \
  CODE_SIGNING_ALLOWED=NO
```

To create an ad-hoc signed app you can open locally:

```bash
Scripts/build-local-app.sh
open .artifacts/tg-sidian.app
```

Pass an output path and `release` for an optimized bundle:

```bash
Scripts/build-local-app.sh .artifacts/tg-sidian-release.app release
```

The checked-in `TGSidian.xcodeproj` is ready to open directly. `project.yml` is its
XcodeGen source of truth; XcodeGen is only needed when changing the target structure.

## How it works

tg-sidian separates durable user data from disposable app state:

| Layer | Responsibility |
| --- | --- |
| Markdown vault | Notes, folders, attachments, and links you own |
| App support | Security-scoped bookmark and per-vault workspace preferences |
| Local index | Rebuildable search, backlinks, tags, and graph data |
| Recovery journal | Protection around interrupted or conflicting writes |

The package keeps module boundaries explicit:

- `AppCore` — shared models, preferences, protocols, and recovery contracts
- `MarkdownKit` — front matter, headings, tags, tasks, and wiki-link parsing
- `VaultKit` — contained filesystem access, atomic writes, moves, and daily notes
- `IndexKit` — GRDB-backed SQLite/FTS5 indexing and filesystem reconciliation
- `GraphKit` — bounded graph extraction and deterministic layout
- `SecurityKit` — sandbox bookmark persistence
- `FeatureUI` — the native workspace, editor, settings, backlinks, and graph
- `ExtensionSDK` — neutral, opt-in host interfaces for separately maintained add-ons

The only runtime dependency is
[GRDB.swift 7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1),
pinned exactly for reproducible index behavior.

## Current scope

The first public release focuses on the core local-vault workflow: choosing and
restoring a vault, browsing and editing Markdown, search, daily notes, backlinks,
tags, templates, and a local graph.

Dynamic plugin discovery, third-party extension distribution, mobile clients,
collaboration, sync, and hosted AI services are not part of the initial release.
The extension SDK is included as an architectural boundary; personal integrations
are intentionally not part of the public repository or app.

## Contributing

Issues and focused pull requests are welcome. Start with
[CONTRIBUTING.md](CONTRIBUTING.md) for the local workflow and architecture rules.
For security concerns, follow the private reporting guidance in
[SECURITY.md](SECURITY.md).

Useful design and implementation context lives in [`docs/adr`](docs/adr) and the
release checklist is tracked in
[`docs/OPEN_SOURCE_LAUNCH.md`](docs/OPEN_SOURCE_LAUNCH.md).

## License

tg-sidian is available under the [MIT License](LICENSE).

---

<div align="center">
  Built for people who want a beautiful native editor without giving up plain files.
</div>

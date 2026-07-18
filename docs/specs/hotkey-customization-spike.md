# Hotkey customization spike (P1)

## Recommendation

Keep P0 read-only. Full Obsidian-style customization is a medium-sized interaction and platform-integration project, not a settings-field follow-up. It should be scheduled only after the command registry becomes the single source of truth for both menus and in-app handlers.

## Required design

- Define stable command IDs (for example, `vault.search`, `markdown.toggle-task`) separate from labels and default bindings.
- Persist per-vault or app-wide overrides as versioned JSON: command ID, key equivalent, modifier set, and an explicit disabled state. Defaults remain in code and malformed/unknown overrides are ignored safely.
- Resolve effective bindings centrally at launch and validate conflicts across scopes. A duplicate within the same active scope must block saving; a narrower contextual binding may coexist only when its precedence is explicit and visible.
- Generate SwiftUI `Commands` from the effective registry. Contextual AppKit/SwiftUI handlers need the same registry or a small dispatcher bridge; otherwise menus and in-app behavior will drift.
- Provide capture UI that records modifiers, reserves macOS/system shortcuts, supports Reset and Clear, and explains conflicts before committing.

## Main risks and estimated shape

The difficult part is not persistence: it is rebuilding menus and keeping responder-chain/contextual shortcuts synchronized after an override changes. SwiftUI command rebuilding may require replacing the command set through observable state or an AppKit menu bridge; this needs a proof-of-concept before promising live editing.

Suggested spike: 2–3 days for a registry proof-of-concept with one menu command and one contextual command, live override application, collision validation, and relaunch persistence. A production P1 is likely 1–2 additional weeks including migration, accessibility, reserved-key behavior, and regression coverage.

# PENTA-140 — contextual navigation acceptance

## Automated evidence

Run from the repository root:

```bash
swift test
swift build -c release
Scripts/validate-editor-engine.sh
xcodebuild -project TGSidian.xcodeproj -scheme TGSidian -configuration Debug -derivedDataPath .build/xcode-app CODE_SIGNING_ALLOWED=NO build
xcodebuild -project TGSidian.xcodeproj -scheme TGSidian -configuration Release -derivedDataPath .build/xcode-app CODE_SIGNING_ALLOWED=NO build
Scripts/build-local-app.sh .artifacts/tg-sidian-penta140.app release
```

`PENTA140ContextualNavigationTests` verifies:

- configurable folder, Unicode filename pattern, optional template, locale, calendar, and time zone resolve to one canonical Markdown path;
- patterns without `.md`/`.markdown` are normalized to Markdown, and 12 concurrent opens create exactly one file with one fingerprint;
- per-vault daily-note preferences round-trip through workspace state and drive a newest-first list of existing recent daily notes;
- backlinks expose their canonical source path, nearest heading, and the previous/current/next surrounding lines, then replace all three after an indexed edit;
- the graph hard-caps untrusted requests at 150 nodes and 500 edges, remains deterministic, returns exact cached positions for an unchanged snapshot, and throws `CancellationError` for stale layout work;
- the production SpriteKit surface implements pointer pan, wheel/pinch zoom, keyboard focus/open, fit/focus/open controls, and has no SwiftUI Canvas fallback;
- the accessible outline enumerates every visible node and all of its visible neighbors, while every custom SwiftUI button passes through the native titled accessibility bridge;
- Reduce Motion rebuilds at final positions and uses a 120 ms opacity transition instead of node or camera travel.

### Performance record — 2026-07-16

On the development Apple Silicon Mac, the final full-suite run produced the deterministic 240-note capped graph (**150 nodes / 149 edges**) in **574.46 ms** including actor extraction and the first force layout. The separate 150-node/149-edge, 80-iteration layout took **1,237.67 ms** cold and **0.11 ms** from the exact-snapshot cache; both results were byte-for-byte position equivalent. These are deterministic XCTest/Swift Testing guardrails, not claims about every vault or release machine.

### Verification record — 2026-07-16

- `swift test --skip-build`: **72 tests / 10 suites passed** in 9.362 s; PENTA-140 suite passed in 2.758 s.
- `swift build -c release`: passed in 16.76 s.
- `Scripts/validate-editor-engine.sh`: **10 editor tests passed** and the isolated manual harness built; 1 MiB load+style was 153.55 ms and keystroke dispatch was 1.69 ms p95.
- Xcode `TGSidian` Debug and Release builds with signing disabled: `BUILD SUCCEEDED` for both configurations.
- `Scripts/build-local-app.sh .artifacts/tg-sidian-penta140.app release`: built the app; strict deep signature, executable, and icon checks passed.
- The only Xcode diagnostic was the expected AppIntents metadata skip because this app has no AppIntents dependency; no Swift warning or test failure remained.

## Daily notes and recent dates

1. Open the daily-note gear control with keyboard only.
2. Set a non-default folder, filename pattern without an extension, template path, locale, time zone, and calendar. Save, quit, and relaunch.
3. Expected: all values persist for this vault; selecting a date creates `<configured folder>/<formatted filename>.md` from the template and opens it in the same editor.
4. Select the same date repeatedly, including rapid repeated clicks.
5. Expected: one canonical file exists, existing content is never replaced, and the selected date receives both visible and VoiceOver selected state.
6. Create several matching dated notes plus an unrelated similarly named note in another folder.
7. Expected: **Recent daily notes** shows up to seven matching canonical notes newest-first; the unrelated note is excluded and each row opens the real file.
8. Verify previous month, next month, Today, settings, all 42 date cells, and recent-note rows using Tab/Shift-Tab, Return/Space, and VoiceOver.

## Live backlinks

1. Open a target note and a source containing a wiki link below a level-two heading with prose on the lines immediately before and after it.
2. Expected: Backlinks names the source, shows `under <heading>`, and includes a concise surrounding excerpt.
3. Activate the backlink with keyboard and VoiceOver.
4. Expected: the canonical source Markdown opens in the same editor.
5. Change the source heading and surrounding prose, wait for autosave, then return to the target. Repeat with an external editor.
6. Expected: the old heading/excerpt disappears after the save or FSEvents update; the new source, heading, and context appear without rebuilding the whole vault.

## Native local graph

1. Open a note with depth-two connections and switch between **Graph** and **Outline**.
2. On the SpriteKit graph, drag to pan, scroll or pinch to zoom, single-click a node to focus, and double-click to open it.
3. Exercise Zoom In, Zoom Out, Fit, Focus Current Note, Open Focused Note, and depth −/+ with keyboard only.
4. Expected: viewport commands are interruptible; focused state has a non-color focus ring; Open Focused Note names its target to VoiceOver; changing depth never exceeds 150 nodes/500 edges.
5. Change depth away and back, navigate away and back, and trigger an index refresh without changing links.
6. Expected: unchanged snapshots reuse stable positions and do not visibly jump; stale work never replaces the newly selected note's graph.
7. In Outline, inspect every row with VoiceOver.
8. Expected: the current note is identified, each row states every visible connected-note title, and activating a row opens the same canonical note as its graph node.

## Accessibility and Reduce Motion (manual-only)

These checks require a real macOS window and installed assistive services; automated tests cover the structural contracts and deterministic transitions.

- With VoiceOver on, confirm the SpriteKit drawing is not duplicated as unlabeled AX children and **Show connection outline** is immediately discoverable.
- Confirm every calendar, backlink, outline, graph viewport, depth, settings, and recent-note action has an audible title, value where applicable, enabled state, help, and press action.
- Turn on Reduce Motion, change graph depth, Fit, and Focus. Graph replacement must cross-fade at final positions; Fit/Focus must update immediately rather than flying the camera.
- Repeat with Increase Contrast, Reduce Transparency, dark appearance, Full Keyboard Access, and enlarged system text. Focus, root, selected date, truncation, and index state must not rely on color alone.
- Use a trackpad and mouse to confirm pinch/wheel zoom direction, bounded zoom, drag panning, single-click focus, and double-click open.
- During rapid note/depth changes, confirm the editor stays responsive, the graph never flashes an older root, and graph failure leaves Markdown editing available.

## Residual release checks

Audible VoiceOver phrasing/order, physical trackpad gesture feel, visible focus-ring contrast, Reduce Motion transition perception, and subjective 150-node legibility remain OS-only checks. The performance test is intentionally capped and content-free; release hardware should additionally record Instruments traces for graph layout and SpriteKit frame pacing without logging note titles, bodies, vault names, or full paths.

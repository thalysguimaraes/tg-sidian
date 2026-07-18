# PENTA-136 production app acceptance

## Automated evidence

Validated on 2026-07-15 with Xcode 26.6 and Swift 6.3.3:

| Check | Command | Result |
| --- | --- | --- |
| Package build and unit/integration tests | `swift test` | PASS — 36 tests in 6 suites |
| Production target and asset catalog | `xcodebuild -project TGSidian.xcodeproj -scheme TGSidian -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-debug CODE_SIGNING_ALLOWED=NO clean build` | PASS |
| Release bundle packaging | `Scripts/build-local-app.sh .artifacts/tg-sidian-release.app release` | PASS |
| Bundle signature | `codesign --verify --deep --strict --verbose=2 .artifacts/tg-sidian-release.app` | PASS |
| Bundle architecture | `file .artifacts/tg-sidian-release.app/Contents/MacOS/tg-sidian` | PASS — arm64 and x86_64 |
| Production entitlements | `codesign --display --entitlements :- .artifacts/tg-sidian-release.app` | PASS — sandbox, app-scoped bookmarks, and user-selected read/write are `true` |
| App icon | `test -f .artifacts/tg-sidian-release.app/Contents/Resources/AppIcon.icns` | PASS |
| Launch smoke | `open -n .artifacts/tg-sidian-release.app`, then process check after 3 seconds | PASS — app remained alive |

Automated tests specifically cover disk-backed security-scoped bookmark round-tripping; relaunch restoration of split widths, inspector visibility, folder disclosures, and last-open note; corrupt workspace-state recovery; default/custom ignore rules; final and intermediate symlink escape rejection; path normalization; unreadable Markdown visibility/accessibility metadata; the checked-in Xcode target, entitlements, and icon source set; native AXTitle coverage for every FeatureUI button; and zero/non-finite split-width clamping.

## Live computer-use evidence

The release app was inspected through Orca computer use after the accessibility corrections:

- A fresh app-container launch exposed `button Choose Vault…` with no unlabeled application buttons.
- Relaunching the coordinator-prepared `/tmp/tg-sidian-acceptance` authorization exposed titled controls for the vault switcher, folder/note/unreadable rows, recovery, navigation, inspector, every calendar day, backlinks, graph view, and both graph-depth actions; the automated unlabeled-button scan returned zero.
- Activating `button Folder` through the accessibility action expanded it and exposed `button Last`, proving the native accessibility bridge retains its press action.
- The selected vault exposed its hierarchy with the left splitter at 292 points.
- After injecting persisted sidebar and inspector widths of zero and relaunching, the hierarchy remained visible and the left splitter was clamped to 220 points; the prior test state was then restored.

## Manual-only folder picker, relaunch, and accessibility acceptance

The live accessibility-tree and relaunch checks above were executed. The following full procedure remains useful for release acceptance where physical pointer placement and VoiceOver speech are observed directly.

1. Build and prepare a disposable vault:

   ```bash
   Scripts/build-local-app.sh .artifacts/tg-sidian-release.app release
   VAULT="$(mktemp -d /tmp/tg-sidian-acceptance.XXXXXX)"
   mkdir -p "$VAULT/Folder"
   printf '# Home\n\nOpen [[Folder/Last]].\n' > "$VAULT/Home.md"
   printf '# Last\n\nRelaunch target.\n' > "$VAULT/Folder/Last.md"
   printf '\377\376\375' > "$VAULT/Unreadable.md"
   OUTSIDE="$(mktemp -d /tmp/tg-sidian-outside.XXXXXX)"
   printf '# Must not appear\n' > "$OUTSIDE/Escape.md"
   ln -s "$OUTSIDE" "$VAULT/Escaping Folder"
   find "$VAULT" -type f ! -name Unreadable.md -exec shasum -a 256 {} + | sort > /tmp/tg-sidian-before.sha
   open -n .artifacts/tg-sidian-release.app
   ```

2. On the fresh-launch screen, use Tab until **Choose Vault…** is focused, press Space, choose `$VAULT` in the native folder picker, and press Return on **Open Vault**.
   - Expected: focus is keyboard-visible; VoiceOver announces the empty/open-vault state, button, native picker, then the loading/index status.
   - Expected: `Home`, `Folder`, and `Unreadable.md` appear; `Escaping Folder/Escape.md` never appears.
   - Expected: selecting `Unreadable.md` announces it as an unreadable file and exposes a textual recovery message rather than color alone.

3. Expand **Folder**, open **Last**, drag both split dividers to visibly non-default widths, and hide then show the inspector with Option-Command-I. Leave the inspector in the desired final visibility state.
   - Expected: all actions work with keyboard focus and VoiceOver; folder state is announced as expanded/collapsed.

4. Quit with Command-Q, relaunch with `open -n .artifacts/tg-sidian-release.app`, and do not choose the folder again.
   - Expected: the bookmark restores automatically, **Last** reopens, **Folder** remains expanded, both dividers return to their previous widths, and inspector visibility matches the state before quitting.

5. Confirm opening/indexing did not mutate ordinary Markdown:

   ```bash
   find "$VAULT" -type f ! -name Unreadable.md -exec shasum -a 256 {} + | sort > /tmp/tg-sidian-after.sha
   diff -u /tmp/tg-sidian-before.sha /tmp/tg-sidian-after.sha
   ```

   - Expected: no diff.

6. Permission-loss recovery using only the disposable vault: quit the app, remove `$VAULT`, and relaunch.
   - Expected: VoiceOver announces **Vault access needs attention** and the reason; **Select Vault Again…** is keyboard reachable and opens the native folder picker.
   - Choose a new disposable vault and expect the workspace to recover without a crash.

7. Cleanup:

   ```bash
   rm -rf "$VAULT" "$OUTSIDE"
   ```

## Genuine manual residual

A human still needs to record the native `NSOpenPanel` interaction, physical divider dragging, and VoiceOver speech/focus order on a normal signed/local macOS session. The built app's live accessibility tree, native accessibility actions, real process relaunch, restored security extension, and zero-width recovery were verified through Orca computer use as described above.

# Open-source launch checklist

## Code and product

- [x] Personal integrations are excluded from public source, targets, tests, and UI.
- [x] The public app retains only the neutral extension SDK and host surfaces.
- [x] General, Editor, Sidebar, Daily Notes, Hotkeys, and Extensions settings exist.
- [x] Pull requests run package tests and an unsigned macOS app build.
- [x] Contribution and private security-reporting guidance is present.
- [x] No credentials or vault content are tracked.
- [x] Complete the Files & Links P0 settings.
- [x] Verify a clean first launch and the extension host in the built app.

## Repository and governance

- [x] Publish from a fresh/scrubbed Git history; earlier private commits remain in a separate private repository.
- [x] Verify the final public history, not only `HEAD`, contains no personal integration source or identifiers.
- [x] Choose and add the project `LICENSE` before making the repository public.
- [x] Enable GitHub private vulnerability reporting.
- [x] Protect `main` and require the CI workflow.
- [x] Confirm the public issue tracker and discussion policy.
- [ ] Add repository topics, description, social preview, and release notes.

## Release

- [ ] Confirm the minimum supported macOS and Xcode versions in release notes.
- [ ] Run `swift test` and the Release CI workflow from the public repository.
- [ ] Validate the uploaded app bundle, entitlements, icon, and ad-hoc signature.
- [ ] Publish a tagged pre-release for external smoke testing before announcing 1.0.

The license choice is intentionally unresolved here because it determines downstream
permissions and must be made by the project owner.

# Contributing to tg-sidian

Thanks for helping improve tg-sidian.

## Before opening a change

- Use macOS 14 or newer with Swift 6.2.
- Keep the core app dependency-light and place optional integrations behind `ExtensionSDK`.
- Do not commit vault contents, credentials, API tokens, signing material, or generated build output.
- Discuss large product or architecture changes in an issue before investing in an implementation.

## Build and test

```bash
swift build
swift test
xcodebuild \
  -project TGSidian.xcodeproj \
  -scheme TGSidian \
  -configuration Debug \
  build \
  CODE_SIGNING_ALLOWED=NO
```

When target structure changes, update `project.yml`, run:

```bash
xcodegen generate --spec project.yml
```

and commit the regenerated `TGSidian.xcodeproj` with the source change.

## Pull requests

- Keep changes focused and explain the user-visible behavior.
- Add or update tests for behavior and architecture boundaries.
- Include manual verification steps for macOS UI changes.
- Preserve canonical Markdown and vault containment guarantees.
- Keep personal or deployment-specific integrations out of the public repository.
- Add-ons should depend on the neutral `ExtensionSDK` instead of changing core UI.

By contributing, you agree that your contribution may be distributed under the
repository's project license.

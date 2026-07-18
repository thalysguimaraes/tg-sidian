#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/.artifacts/tg-sidian.app}"
CONFIGURATION="${2:-${CONFIGURATION:-debug}}"
PROJECT="$ROOT/TGSidian.xcodeproj"
SCHEME="TGSidian"
ENTITLEMENTS="$ROOT/App/Resources/TGSidian.entitlements"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.build/xcode-app}"

case "$CONFIGURATION" in
  debug) XCODE_CONFIGURATION="Debug" ;;
  release) XCODE_CONFIGURATION="Release" ;;
  *)
    printf 'Unsupported configuration: %s (expected debug or release)\n' "$CONFIGURATION" >&2
    exit 2
    ;;
esac

cd "$ROOT"
plutil -lint "$ROOT/App/Resources/Info.plist" >/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null
test -f "$PROJECT/project.pbxproj"

# Build the checked-in production target so resources, the app icon, deployment metadata, and
# sandbox settings are exercised exactly as they are when the project is opened in Xcode.
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$XCODE_CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

BUILT_APP="$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/tg-sidian.app"
test -d "$BUILT_APP"
rm -rf "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
ditto "$BUILT_APP" "$OUTPUT"

# CI and local smoke builds are ad-hoc signed but retain the production sandbox/bookmark rights.
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$OUTPUT" >/dev/null
codesign --verify --deep --strict "$OUTPUT"
test -x "$OUTPUT/Contents/MacOS/tg-sidian"
test -f "$OUTPUT/Contents/Resources/AppIcon.icns"

SIGNED_ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$SIGNED_ENTITLEMENTS"' EXIT
codesign --display --entitlements :- "$OUTPUT" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
for entitlement in \
  com.apple.security.app-sandbox \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.files.user-selected.read-write; do
  test "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$SIGNED_ENTITLEMENTS")" = "true"
done

printf '%s\n' "$OUTPUT"

#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

echo "==> Running PENTA-137 automated editor validations"
swift test --filter EditorEngineValidationTests

echo "==> Building the isolated manual harness"
swift build --product editor-engine-harness

cat <<'EOF'

Automated validation passed.
Run the manual-only checks with:
  swift run editor-engine-harness

Checklist and expected results:
  docs/manual-acceptance/PENTA-137.md
EOF

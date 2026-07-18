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
Launch the isolated manual harness with:
  swift run editor-engine-harness
EOF

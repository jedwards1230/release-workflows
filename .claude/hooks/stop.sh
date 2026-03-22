#!/bin/bash
# Hook: Stop
# Fires when Claude finishes a response.
# Use for running linters or tests on changed files.

set -euo pipefail

# Validate YAML files
CHANGED=$(git diff --name-only HEAD 2>/dev/null | grep -E '\.ya?ml$' || true)
if [ -n "$CHANGED" ]; then
  for f in $CHANGED; do
    yq '.' "$f" > /dev/null 2>&1 || echo "YAML validation failed: $f"
  done
fi

exit 0

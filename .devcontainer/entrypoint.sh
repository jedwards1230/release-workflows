#!/bin/bash
# Devcontainer entrypoint - runs on every container start.
# Keep this idempotent (safe to run multiple times).

set -euo pipefail

echo "=== Release Workflows Devcontainer Health Check ==="

# Tool version validation
check_tool() {
  local name="$1"
  local cmd="$2"
  if version=$($cmd 2>/dev/null); then
    printf "  %-18s %s\n" "$name" "$version"
  else
    printf "  %-18s %s\n" "$name" "NOT FOUND"
  fi
}

echo "Tools:"
check_tool "shellcheck" "shellcheck --version"
check_tool "yq" "yq --version"

echo "=== Health Check Complete ==="

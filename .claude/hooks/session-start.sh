#!/bin/bash
# Hook: SessionStart
# Fires once when a fresh Claude Code session begins (not on resume).
#
# In Claude Code Web (ephemeral containers), installs required tools.
# In local devcontainers, tools are pre-installed via Dockerfile.

set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
  echo "[hook:session-start] Running in Claude Code Web (ephemeral container)"
  
  # Install shellcheck if not present
  if ! command -v shellcheck &>/dev/null; then
    echo "[hook:session-start] Installing shellcheck..."
    apt-get update && apt-get install -y shellcheck 2>/dev/null || true
  fi

  # Install yq if not present
  if ! command -v yq &>/dev/null; then
    echo "[hook:session-start] Installing yq..."
    curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
      -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
  fi
else
  echo "[hook:session-start] Running in local devcontainer -- tools pre-installed"
fi

echo "[hook:session-start] Done"
exit 0

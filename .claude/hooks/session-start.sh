#!/bin/bash
# Hook: SessionStart
# Fires once when a fresh Claude Code session begins (not on resume).
#
# In Claude Code Web (ephemeral containers), installs required tools.
# In local devcontainers, tools are pre-installed via Dockerfile.

set +e  # Never exit on error in session-start

if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
  echo "[session-start] Running in Claude Code Web (ephemeral container)" >&2
  
  # Install shellcheck if not present
  if ! command -v shellcheck &>/dev/null; then
    echo "[session-start] Installing shellcheck..." >&2
    apt-get update && apt-get install -y shellcheck 2>/dev/null || true
  fi

  # Install yq if not present
  if ! command -v yq &>/dev/null; then
    echo "[session-start] Installing yq..." >&2
    curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.52.4/yq_linux_amd64 \
      -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
  fi
else
  echo "[session-start] Running in local devcontainer -- tools pre-installed" >&2
fi

echo "[session-start] Done" >&2
exit 0

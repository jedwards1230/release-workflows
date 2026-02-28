#!/bin/bash
# Hook: PostToolUse
# Fires after every tool call. Read JSON from stdin.
# Use for auto-formatting modified files.

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")



exit 0

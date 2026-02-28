#!/bin/bash
# Hook: PreToolUse
# Fires before every tool call. Read JSON from stdin.
# Exit 0 = allow, exit 2 = block with message.

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

# Example: block dangerous patterns
# if [[ "$TOOL_NAME" == "Bash" ]]; then
#   COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
#   if [[ "$COMMAND" == *"rm -rf /"* ]]; then
#     echo "Blocked: dangerous rm command"
#     exit 2
#   fi
# fi

exit 0

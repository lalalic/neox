#!/bin/bash
# error-occurred.sh — Report errors to user's phone
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

ERROR_MSG=$(echo "$INPUT" | jq -r '.error.message // "Unknown error"')
ERROR_NAME=$(echo "$INPUT" | jq -r '.error.name // "Error"')

echo '{"name":"report_progress","arguments":{"title":"❌ Agent Error","message":"['"$ERROR_NAME"'] '"$ERROR_MSG"'","status":"error"}}' \
  | "$SCRIPT_DIR/mcp-call.sh"

#!/bin/bash
# session-start.sh — Report session start to user's phone
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

SOURCE=$(echo "$INPUT" | jq -r '.source // "new"')

echo '{"name":"report_progress","arguments":{"title":"🚀 Session Started","message":"Coding agent session started ('"$SOURCE"')","status":"info"}}' \
  | "$SCRIPT_DIR/mcp-call.sh"

# Initialize tool usage log
mkdir -p .github/hooks/tmp
echo "0" > .github/hooks/tmp/tool-count.txt
date +%s > .github/hooks/tmp/session-start-ts.txt

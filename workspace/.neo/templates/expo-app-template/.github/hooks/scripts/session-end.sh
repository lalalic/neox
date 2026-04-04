#!/bin/bash
# session-end.sh — Report session completion to user's phone
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

REASON=$(echo "$INPUT" | jq -r '.reason // "complete"')

# Calculate duration
DURATION="unknown"
if [ -f .github/hooks/tmp/session-start-ts.txt ]; then
  START_TS=$(cat .github/hooks/tmp/session-start-ts.txt)
  END_TS=$(date +%s)
  ELAPSED=$((END_TS - START_TS))
  MINS=$((ELAPSED / 60))
  SECS=$((ELAPSED % 60))
  DURATION="${MINS}m ${SECS}s"
fi

# Report completion
if [ "$REASON" = "complete" ]; then
  STATUS="success"
  TITLE="✅ Session Complete"
  MSG="Finished in $DURATION."
else
  STATUS="warning"
  TITLE="⚠️ Session Ended"
  MSG="Ended ($REASON) after $DURATION."
fi

echo '{"name":"report_progress","arguments":{"title":"'"$TITLE"'","message":"'"$MSG"'","status":"'"$STATUS"'"}}' \
  | "$SCRIPT_DIR/mcp-call.sh"

# Cleanup
rm -rf .github/hooks/tmp

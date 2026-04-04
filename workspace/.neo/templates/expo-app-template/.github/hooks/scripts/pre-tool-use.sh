#!/bin/bash
# pre-tool-use.sh — Notify user about significant tool calls
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.toolName // "unknown"')

# Only notify for significant actions (skip view, list, etc.)
case "$TOOL_NAME" in
  bash)
    CMD=$(echo "$INPUT" | jq -r '.toolArgs' | jq -r '.command // .description // ""' 2>/dev/null | head -c 120)
    [ -n "$CMD" ] && echo '{"name":"send_response","arguments":{"message":"🔧 Running: '"$(echo "$CMD" | sed 's/"/\\"/g')"'"}}' | "$SCRIPT_DIR/mcp-call.sh"
    ;;
  edit)
    FILE=$(echo "$INPUT" | jq -r '.toolArgs' | jq -r '.path // .file // ""' 2>/dev/null)
    [ -n "$FILE" ] && echo '{"name":"send_response","arguments":{"message":"✏️ Editing: '"$FILE"'"}}' | "$SCRIPT_DIR/mcp-call.sh"
    ;;
  create)
    FILE=$(echo "$INPUT" | jq -r '.toolArgs' | jq -r '.path // .file // ""' 2>/dev/null)
    [ -n "$FILE" ] && echo '{"name":"send_response","arguments":{"message":"📄 Creating: '"$FILE"'"}}' | "$SCRIPT_DIR/mcp-call.sh"
    ;;
esac

# Always allow — never output a deny decision

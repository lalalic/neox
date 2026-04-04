#!/bin/bash
# mcp-call.sh — Call an MCP tool on the relay server via JSON-RPC
# Usage: echo '{"name":"tool","arguments":{...}}' | ./mcp-call.sh
# Requires: PROJECT_TOKEN env var or .github/copilot-mcp.json
set -e

MCP_URL="${MCP_URL:-https://relay.ai.qili2.com/mcp}"

# Fallback: read token from copilot-mcp.json if env var not set
if [ -z "$PROJECT_TOKEN" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
  MCP_JSON="$REPO_ROOT/.github/copilot-mcp.json"
  if [ -f "$MCP_JSON" ] && command -v jq >/dev/null 2>&1; then
    PROJECT_TOKEN=$(jq -r '.mcpServers["neox-relay"].headers.Authorization // empty' "$MCP_JSON" | sed 's/^Bearer //')
  fi
fi

if [ -z "$PROJECT_TOKEN" ]; then
  exit 0  # Silently skip if no token — don't break the agent
fi

PARAMS=$(cat)
TOOL_NAME=$(echo "$PARAMS" | jq -r '.name')
TOOL_ARGS=$(echo "$PARAMS" | jq -c '.arguments')

curl -s -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $PROJECT_TOKEN" \
  -d "$(jq -n \
    --arg tool "$TOOL_NAME" \
    --argjson args "$TOOL_ARGS" \
    '{jsonrpc:"2.0", id:1, method:"tools/call", params:{name:$tool, arguments:$args}}')" \
  > /dev/null 2>&1 || true

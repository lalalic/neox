#!/bin/bash
# mcp-call.sh — Call an MCP tool on the relay server via JSON-RPC
# Usage: echo '{"name":"tool","arguments":{...}}' | ./mcp-call.sh
# Requires: PROJECT_TOKEN env var, MCP_URL env var (or defaults to relay)
set -e

MCP_URL="${MCP_URL:-https://relay.ai.qili2.com/mcp}"

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

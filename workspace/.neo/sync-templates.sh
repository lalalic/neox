#!/bin/bash
# sync-templates.sh — Sync local templates to their GitHub repos
# Usage: ./sync-templates.sh [template-name] [commit-message]
# If template-name is omitted, syncs all templates.

set -eo pipefail

TEMPLATES_DIR="$(cd "$(dirname "$0")/templates" && pwd)"
MSG="${2:-Update template}"

# Map template dirs to GitHub repos
get_repo() {
  case "$1" in
    expo-app-template) echo "neos-apps/expo-app-template" ;;
    *) echo "" ;;
  esac
}

ALL_TEMPLATES="expo-app-template"

sync_template() {
  local name="$1"
  local repo
  repo=$(get_repo "$name")
  local src="$TEMPLATES_DIR/$name"

  if [ -z "$repo" ]; then
    echo "❌ Unknown template: $name"
    return 1
  fi

  if [ ! -d "$src" ]; then
    echo "❌ Template dir not found: $src"
    return 1
  fi

  echo "📦 Syncing $name → $repo"
  
  TMP=$(mktemp -d)

  gh repo clone "$repo" "$TMP/repo" -- --depth=1 2>/dev/null

  rsync -av --exclude='.git' --exclude='node_modules' --exclude='package-lock.json' --delete "$src/" "$TMP/repo/"

  cd "$TMP/repo"
  if git diff --quiet && git diff --cached --quiet; then
    echo "  ✅ No changes to sync."
    return 0
  fi

  git add -A
  echo "  Changes:"
  git diff --cached --stat | sed 's/^/    /'
  
  git commit -m "$MSG"
  git push
  echo "  ✅ Pushed to $repo"
  rm -rf "$TMP"
}

# Sync specific template or all
TEMPLATE="${1:-}"
if [ -n "$TEMPLATE" ]; then
  sync_template "$TEMPLATE"
else
  for name in $ALL_TEMPLATES; do
    sync_template "$name"
  done
fi

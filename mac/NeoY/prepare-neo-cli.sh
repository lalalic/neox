#!/bin/zsh
set -euo pipefail
HERE="${0:A:h}"
DEST="$HERE/Resources/Packages/neo-cli.tgz"
if [[ -n "${NEOY_NEO_CLI_TARBALL:-}" ]]; then
  [[ -f "$NEOY_NEO_CLI_TARBALL" ]] || { print -u2 "Missing explicitly configured CLI tarball"; exit 2; }
  cp "$NEOY_NEO_CLI_TARBALL" "$DEST"
elif [[ -d "$HOME/Workspace/neo/.git" && -f "$HOME/Workspace/neo/scripts/stage-neo-cli.mjs" ]]; then
  STAGE="$(mktemp -d /tmp/neoy-cli-stage.XXXXXX)"
  trap 'rm -rf "$STAGE"' EXIT
  node "$HOME/Workspace/neo/scripts/stage-neo-cli.mjs" "$STAGE/package"
  (cd "$STAGE/package" && npm pack --ignore-scripts --pack-destination "$STAGE" >/dev/null)
  set -A tarballs "$STAGE"/*.tgz
  [[ ${#tarballs} -eq 1 ]] || { print -u2 "Expected exactly one Neo CLI tarball"; exit 2; }
  cp "$tarballs[1]" "$DEST"
else
  print -u2 "Set NEOY_NEO_CLI_TARBALL to a verified Neo CLI artifact; no developer checkout found."
  exit 2
fi
node - "$DEST" <<'JS'
const fs=require('fs');const p=process.argv[2];if(!fs.statSync(p).size)process.exit(2);
JS
print "Staged CLI artifact: $DEST"

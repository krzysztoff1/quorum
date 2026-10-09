#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [path/to/Quorum.app]" >&2
  echo "  no argument     build engine/dist/quorum-engine for dev (QUORUM_ENGINE_BIN)" >&2
  echo "  with a .app     also copy the binary into the bundle's Contents/Resources" >&2
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

cd "$(dirname "$0")/../engine"
bun install --frozen-lockfile
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD -- . 2>/dev/null || BUILD="$BUILD-dirty"
bun run build:bin --define "QUORUM_ENGINE_BUILD=\"$BUILD\""
BIN="$PWD/dist/quorum-engine"
chmod +x "$BIN"

if [[ $# -ge 1 ]]; then
  APP="$1"
  [[ -d "$APP/Contents" ]] || { echo "error: $APP is not an .app bundle" >&2; exit 1; }
  DEST="$APP/Contents/Resources"
  mkdir -p "$DEST"
  cp "$BIN" "$DEST/quorum-engine"
  echo "bundled: $DEST/quorum-engine"
else
  echo "built: $BIN"
  echo "dev run: QUORUM_ENGINE_BIN=$BIN swift run Quorum"
fi

#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--no-build] [--open]" >&2
  echo "  builds Quorum.app (scripts/make-app.sh) and replaces ~/Applications/Quorum.app with it" >&2
  echo "  --no-build  install the existing build/Quorum.app instead of rebuilding" >&2
  echo "  --open      launch the installed app afterwards" >&2
  exit 1
}

BUILD=1
OPEN=0
for argument in "$@"; do
  case "$argument" in
    --no-build) BUILD=0 ;;
    --open) OPEN=1 ;;
    *) usage ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/build/Quorum.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Quorum.app"

[[ "$BUILD" == 1 ]] && "$ROOT/scripts/make-app.sh"
[[ -d "$SOURCE" ]] || { echo "error: $SOURCE does not exist; run scripts/make-app.sh" >&2; exit 1; }

if pgrep -x Quorum >/dev/null; then
  osascript -e 'tell application "Quorum" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x Quorum >/dev/null || break; sleep 0.5; done
  pgrep -x Quorum >/dev/null && { echo "error: Quorum is still running; quit it and retry" >&2; exit 1; }
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$SOURCE" "$DEST"
echo "installed: $DEST"
/usr/libexec/PlistBuddy -c "Print :QuorumAppBuild" "$DEST/Contents/Info.plist" | sed 's/^/app build /'
"$DEST/Contents/Resources/quorum-engine" version

[[ "$OPEN" == 1 ]] && open "$DEST"
exit 0

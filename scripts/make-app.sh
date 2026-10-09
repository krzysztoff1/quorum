#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [output-dir]" >&2
  echo "  builds a release Quorum.app (default: build/Quorum.app) with the engine bundled and stamped" >&2
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/Quorum.app"
CONTENTS="$APP/Contents"
BUNDLE_ID="io.github.krzysztoff1.quorum"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

"$ROOT/scripts/bundle-engine.sh" "$APP"
ENGINE="$CONTENTS/Resources/quorum-engine"
ENGINE_BUILD="$("$ENGINE" version | plutil -extract build raw -o - -)"

cd "$ROOT"
swift build -c release --product Quorum
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/Quorum" "$CONTENTS/MacOS/Quorum"
for resources in "$BIN_DIR"/*.bundle; do
  [[ -d "$resources" ]] && cp -R "$resources" "$CONTENTS/Resources/"
done

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
SOURCE_ICON="$ROOT/Sources/Quorum/Resources/AppIcon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

APP_BUILD="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$ROOT" diff --quiet HEAD -- . 2>/dev/null || APP_BUILD="$APP_BUILD-dirty"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Quorum</string>
  <key>CFBundleDisplayName</key><string>Quorum</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Quorum</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>QuorumEngineBuild</key><string>$ENGINE_BUILD</string>
  <key>QuorumAppBuild</key><string>$APP_BUILD</string>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null

codesign --force --sign - --timestamp=none "$ENGINE"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "built: $APP"
echo "app build $APP_BUILD · engine build $ENGINE_BUILD"

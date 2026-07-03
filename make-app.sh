#!/bin/sh
# Build Quorum.app — a real bundle (bundle id → notifications work; icon; version).
# Dev is `swift run`; this is the production artifact. Distribution = Developer-ID sign + notarize.
#
#   ./make-app.sh                      # release build + bundle + ad-hoc sign → runs on THIS Mac
#   DEVELOPER_ID="Developer ID Application: You (TEAMID)" ./make-app.sh   # notarization-ready sign
#
# ponytail: hand-rolled bundle over an Xcode project — SPM has no .app target, and the plist is 10 keys.
set -eu

APP_NAME=Quorum
BUNDLE_ID="${BUNDLE_ID:-com.krzysztofduda.quorum}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT="${OUT:-build}"
APP="$OUT/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [ -n "${DEVELOPER_ID:-}" ]; then
	echo "==> signing (Developer ID + hardened runtime — notarization-ready)"
	codesign --force --deep --options runtime --timestamp \
		--sign "$DEVELOPER_ID" "$APP"
	echo "    next: ditto -c -k --keepParent \"$APP\" $APP_NAME.zip"
	echo "          xcrun notarytool submit $APP_NAME.zip --keychain-profile <profile> --wait"
	echo "          xcrun stapler staple \"$APP\""
else
	echo "==> ad-hoc signing (this Mac only; no Gatekeeper distribution)"
	codesign --force --deep --sign - "$APP"
fi

echo "==> done: $APP"

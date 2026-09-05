#!/usr/bin/env bash
set -euo pipefail

# Build a standalone Apple Silicon developer artifact. This intentionally uses
# an ad-hoc signature: bundle integrity is verified, but Gatekeeper/notarization
# trust is not provided without a Developer ID signing identity.

APP_NAME="ClipSyncControl"
BUNDLE_ID="io.clipsync.control"
MIN_SYSTEM_VERSION="13.0"
VERSION="${1:?usage: $0 <version> [output-directory]}"
OUTPUT_DIR="${2:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT_DIR/dist/release"
fi

case "$VERSION" in
  *[!0-9A-Za-z._-]*|"")
    echo "version must contain only letters, numbers, '.', '_' or '-'" >&2
    exit 2
    ;;
esac

OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
ZIP_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-arm64.zip"

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_BUNDLE" "$ZIP_PATH"

cd "$ROOT_DIR"
swift build -c release --arch arm64
BUILD_BINARY="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

mkdir -p "$APP_MACOS"
install -m 0755 "$BUILD_BINARY" "$APP_MACOS/$APP_NAME"

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ClipSync Control</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$APP_CONTENTS/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "artifact=$ZIP_PATH"
shasum -a 256 "$ZIP_PATH"
echo "signature: ad-hoc (not notarized; requires user approval on first launch)"

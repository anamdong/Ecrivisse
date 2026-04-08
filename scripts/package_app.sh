#!/bin/zsh
set -euo pipefail

EXECUTABLE_NAME="Ecrivisse"
APP_DISPLAY_NAME="Écrivisse"
APP_BUNDLE_NAME="Écrivisse"
APP_BUNDLE_ID="com.ecrivisse.app"
APP_ICON_PNG_RELATIVE_PATH="app_icon/1x/CrawfishWriter_icon_04.png"
APP_ICON_BASENAME="Ecrivisse"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_CONFIG="${1:-debug}" # debug or release
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_BUNDLE_NAME.app"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
APP_ICON_PNG="$ROOT_DIR/$APP_ICON_PNG_RELATIVE_PATH"
APP_ICON_ICNS="$APP_DIR/Contents/Resources/$APP_ICON_BASENAME.icns"

if [[ "$BUILD_CONFIG" != "debug" && "$BUILD_CONFIG" != "release" ]]; then
  echo "Usage: $0 [debug|release]"
  exit 1
fi

cd "$ROOT_DIR"

swift build -c "$BUILD_CONFIG"

BIN_CANDIDATE="$ROOT_DIR/.build/arm64-apple-macosx/$BUILD_CONFIG/$EXECUTABLE_NAME"

if [[ ! -f "$BIN_CANDIDATE" ]]; then
  echo "Could not locate built executable at: $BIN_CANDIDATE"
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_CANDIDATE" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"

if [[ -f "$APP_ICON_PNG" ]]; then
  ICONSET_DIR="$(mktemp -d "$DIST_DIR/iconset.XXXXXX.iconset")"
  trap 'rm -rf "$ICONSET_DIR"' EXIT

  # Build a complete macOS iconset from a single source PNG.
  sips -z 16 16 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$APP_ICON_ICNS"
fi

cat > "$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_BUNDLE_ID</string>
  <key>CFBundleVersion</key>
  <string>14</string>
  <key>CFBundleShortVersionString</key>
  <string>Beta 1.4</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_BASENAME</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Text Documents</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.markdown</string>
        <string>net.multimarkdown.text</string>
        <string>public.plain-text</string>
        <string>public.text</string>
        <string>public.rtf</string>
        <string>public.html</string>
        <string>public.xml</string>
        <string>public.json</string>
        <string>public.comma-separated-values-text</string>
        <string>public.tab-separated-values-text</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>md</string>
        <string>markdown</string>
        <string>txt</string>
        <string>text</string>
        <string>rtf</string>
        <string>html</string>
        <string>htm</string>
        <string>xml</string>
        <string>json</string>
        <string>csv</string>
        <string>tsv</string>
        <string>log</string>
        <string>yaml</string>
        <string>yml</string>
      </array>
      <key>LSTypeIsPackage</key>
      <false/>
    </dict>
  </array>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS treats the bundle like a normal local app.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Created app bundle:"
echo "$APP_DIR"

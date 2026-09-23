#!/bin/zsh
# Builds Jayson and wraps it into build/Jayson.app.
# usage: Scripts/build-app.sh [debug|release] [--universal]
#
# Environment:
#   JAYSON_VERSION     override the version (default: contents of VERSION)
#   JAYSON_BUILD       override the build number (default: git commit count)
#   CODESIGN_IDENTITY  "Developer ID Application: …" for distribution; ad-hoc when unset
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "unknown argument $arg" >&2; exit 1 ;;
  esac
done
export SDKROOT="$(Scripts/sdk.sh)"
VERSION="${JAYSON_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${JAYSON_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

ARCH_FLAGS=()
if [[ $UNIVERSAL -eq 1 ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product Jayson 2>&1 | grep -vE "ld: warning: search path" || true
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Jayson"
if [[ ! -x "$BIN" ]]; then
  echo "error: build did not produce $BIN" >&2
  exit 1
fi

APP="build/Jayson.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Jayson"
if [[ -f Assets/AppIcon.icns ]]; then
  cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Jayson</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.luccasoftware.Jayson</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Jayson</string>
  <key>CFBundleDisplayName</key><string>Jayson</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>JSON</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.json</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP/Contents/PkgInfo"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
  echo "Signed with $CODESIGN_IDENTITY"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc codesign failed (app will still run locally)" >&2
fi
echo "Built $APP ($CONFIG, v$VERSION build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/Jayson"))"

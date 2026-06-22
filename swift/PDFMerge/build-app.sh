#!/usr/bin/env bash
# Bundle the SwiftPM-built executable into a macOS .app package.
#
# Usage:
#   ./build-app.sh            # release build + package
#   ./build-app.sh debug      # use existing debug build
#
# Produces: build/PDFMerge.app
set -euo pipefail

cd "$(dirname "$0")"

MODE="${1:-release}"
APP_NAME="PDFMerge"
APP_ID="com.rexob.pdftools"
ROOT="$(pwd)"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Locate the source icon: prefer the repo-root one, fall back to none.
ICON_SRC=""
for candidate in "$ROOT/../../Icon.png" "$ROOT/Icon.png" "$ROOT/Resources/Icon.png"; do
    if [[ -f "$candidate" ]]; then
        ICON_SRC="$candidate"
        break
    fi
done

echo "==> Building ($MODE)..."
if [[ "$MODE" == "debug" ]]; then
    BIN="$ROOT/.build/debug/$APP_NAME"
    if [[ ! -x "$BIN" ]]; then
        swift build
    fi
else
    swift build -c release
    BIN="$ROOT/.build/release/$APP_NAME"
fi

if [[ ! -x "$BIN" ]]; then
    echo "error: executable not found at $BIN" >&2
    exit 1
fi

echo "==> Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Icon: convert PNG to .icns via sips/iconutil if available.
if [[ -n "$ICON_SRC" ]]; then
    ICONSET_DIR="$BUILD_DIR/Icon.iconset"
    rm -rf "$ICONSET_DIR"; mkdir -p "$ICONSET_DIR"
    # Generate the required sizes from the 1024 source PNG.
    sips -z 16 16     "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16.png"     >/dev/null
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16@2x.png"  >/dev/null
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32.png"     >/dev/null
    sips -z 64 64     "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32@2x.png"  >/dev/null
    sips -z 128 128   "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128.png"   >/dev/null
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256.png"   >/dev/null
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET_DIR/icon_512x512.png"   >/dev/null
    cp "$ICON_SRC"       "$ICONSET_DIR/icon_512x512@2x.png"
    if iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/icon.icns" >/dev/null 2>&1; then
        ICON_FILE="icon.icns"
    else
        echo "warn: iconutil failed, falling back to PNG icon" >&2
        cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
        ICON_FILE="AppIcon.png"
    fi
fi

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_ID}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    $(if [[ -n "${ICON_FILE:-}" ]]; then
        echo "<key>CFBundleIconFile</key>"
        echo "<string>${ICON_FILE}</string>"
    fi)
    <key>NSScreenUsesPerMonitorVSync</key>
    <true/>
</dict>
</plist>
PLIST

# Refresh LaunchServices icon cache so the new icon shows up immediately.
touch "$APP_BUNDLE"

# Ad-hoc sign (matches the Go build's signature level).
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo ""
echo "==> Done"
du -sh "$APP_BUNDLE"
echo "    $APP_BUNDLE"
echo ""
echo "Run with: open '$APP_BUNDLE'"

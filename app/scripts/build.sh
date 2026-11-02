#!/bin/bash
# Builds Burrow.app (SwiftUI wrapper + bundled Mole CLI) and a drag-to-install DMG.
#
#   app/scripts/build.sh            # release build, app + dmg in app/dist/
#   app/scripts/build.sh --no-dmg   # app only
#
# No Apple Developer account needed: the app is ad-hoc signed. On first launch
# macOS will block it; open System Settings > Privacy & Security and click
# "Open Anyway" once.
set -euo pipefail

APP_NAME="Burrow"
BUNDLE_ID="dev.burrow.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
DIST="$APP_DIR/dist"
BUILD_TMP="$APP_DIR/.build-bundle"
MAKE_DMG=true
[[ "${1:-}" == "--no-dmg" ]] && MAKE_DMG=false

MOLE_VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$REPO_DIR/mole" | head -1)"
APP_VERSION="${BURROW_VERSION:-1.0.0}"

echo "==> Building Mole Go helpers (analyze, status)"
(cd "$REPO_DIR" && make build >/dev/null)

echo "==> Building $APP_NAME (release)"
(cd "$APP_DIR" && swift build -c release)
BIN_PATH="$(cd "$APP_DIR" && swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Assembling bundle"
rm -rf "$BUILD_TMP" && mkdir -p "$BUILD_TMP"
APP="$BUILD_TMP/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/mole"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"

# Bundle the CLI exactly as it ships: entry scripts, bin/ and lib/.
cp "$REPO_DIR/mole" "$REPO_DIR/mo" "$APP/Contents/Resources/mole/"
rsync -a --exclude '.DS_Store' "$REPO_DIR/bin" "$REPO_DIR/lib" "$APP/Contents/Resources/mole/"
cp "$REPO_DIR/LICENSE" "$APP/Contents/Resources/mole/LICENSE"
chmod +x "$APP/Contents/Resources/mole/mole" "$APP/Contents/Resources/mole/mo"

echo "==> Rendering icon"
ICONSET="$BUILD_TMP/AppIcon.iconset"
swift "$SCRIPT_DIR/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$APP_VERSION</string>
    <key>BurrowBundledMoleVersion</key><string>$MOLE_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Wrapper for the GPL-3.0 Mole CLI (github.com/tw93/Mole). Source of the CLI is bundled in Resources/mole.</string>
    <key>NSAppleEventsUsageDescription</key><string>Burrow asks macOS for an administrator prompt when you toggle a system background service.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
# Sign nested executables first, then the bundle.
find "$APP/Contents/Resources/mole/bin" -type f -perm -111 -name '*-go' -exec codesign --force --sign - --timestamp=none {} \;
codesign --force --sign - --timestamp=none --options runtime "$APP/Contents/MacOS/$APP_NAME"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$DIST"
rm -rf "$DIST/$APP_NAME.app"
ditto "$APP" "$DIST/$APP_NAME.app"
echo "    $DIST/$APP_NAME.app"

if $MAKE_DMG; then
    echo "==> Creating DMG"
    STAGE="$BUILD_TMP/dmg"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"
    cat > "$STAGE/READ ME FIRST.txt" <<TXT
Install Burrow
==============

1. Drag Burrow into the Applications folder.
2. Open Burrow. macOS says it cannot verify the developer (the app is not
   notarized because it is built without a paid Apple Developer account).
3. Open System Settings > Privacy & Security, scroll down, and click
   "Open Anyway" next to the Burrow message. Confirm once.

Burrow is a window for the open-source Mole CLI (GPL-3.0,
https://github.com/tw93/Mole). The CLI ships inside the app at
Burrow.app/Contents/Resources/mole. Burrow is not affiliated with or
endorsed by the Mole project.
TXT
    DMG="$DIST/$APP_NAME-$APP_VERSION.dmg"
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    echo "    $DMG"
fi

rm -rf "$BUILD_TMP"
echo "==> Done"

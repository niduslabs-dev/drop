#!/bin/sh
# Builds Drop.app into .build/Drop.app: compiles the DropApp target through scripts/swift.sh,
# assembles the bundle (Info.plist, a placeholder icon) and signs it ad hoc with the hardened
# runtime. No keychain or signing identity is used; Developer ID signing comes with shipping.
#
# Usage: scripts/build-app.sh            release build
#        scripts/build-app.sh --debug    debug build (has --demo for screenshots)
set -eu
cd "$(dirname "$0")/.."

CONFIG=release
[ "${1:-}" = "--debug" ] && CONFIG=debug
# Debug builds are a separate app to macOS (own bundle ID, name and preferences), so a
# debug or demo copy never meets a release copy, such as a trial install, in the
# single-instance check or in Launch Services.
BUNDLE_ID=dev.niduslabs.drop
DISPLAY_NAME=Drop
if [ "$CONFIG" = debug ]; then BUNDLE_ID=dev.niduslabs.drop.debug; DISPLAY_NAME="Drop (Debug)"; fi

VERSION=0.1.0
BUILD_NUMBER=1
MIN_MACOS=15.0
APP=.build/Drop.app

scripts/swift.sh build -c "$CONFIG" --product Drop
BIN_DIR=$(scripts/swift.sh build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Drop" "$APP/Contents/MacOS/Drop"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Drop</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Nidus Labs</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <!-- Listed in Open With, never the default unless the user turns on
                 Settings > Open disk images with Drop. Not the generic
                 com.apple.disk-image: DiskImageMounter doesn't claim it, so Launch
                 Services would make Drop its default without asking. -->
            <key>CFBundleTypeName</key><string>Disk Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.apple.disk-image-udif</string>
                <string>com.apple.disk-image-sparse</string>
                <string>com.apple.disk-image-sparse-bundle</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Manrope (onboarding headings and the byline), registered at launch by Typeface.swift.
# Source: github.com/google/fonts, ofl/manrope at commit b31870aff700ab7a1d74fa0c6887d95beb9e0037
# (2026-09-14), SIL Open Font License 1.1; the licence ships beside it.
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/Manrope-Variable.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

# App icon ("The Slot"): generated in the Nidus Labs assets repo and copied here by
# scripts/sync-icon.sh, so this repo builds on its own.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIG)"

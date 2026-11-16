#!/bin/sh
# Builds Drop.app into .build/Drop.app: compiles the DropApp target through scripts/swift.sh,
# assembles the bundle (Info.plist, icon, fonts, Sparkle.framework) and signs it inside out
# with the hardened runtime: ad hoc by default, Developer ID in the release workflow.
#
# Usage: scripts/build-app.sh            release build
#        scripts/build-app.sh --debug    debug build (has --demo for screenshots)
#
# Environment (all optional):
#   VERSION             CFBundleShortVersionString (default 1.0.0)
#   BUILD               CFBundleVersion, what Sparkle compares (default: VERSION)
#   SIGN_IDENTITY       codesign identity (default "-", ad hoc, no keychain); a real identity
#                       also gets a secure timestamp
#   SPARKLE_PUBLIC_KEY  SUPublicEDKey (default: the release key); a local update test
#                       passes a throwaway key's public half
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

VERSION=${VERSION:-1.0.0}
BUILD_NUMBER=${BUILD:-$VERSION}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
# The public half of the EdDSA key that signs release DMGs (private half: the
# SPARKLE_ED_PRIVATE_KEY repo secret). Sparkle refuses any update not signed with it.
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-Xpg3Rqae374NnCgOel6deZTIslj/4pwSC6YVxESI/5A=}
FEED_URL=https://github.com/niduslabs-dev/drop/releases/latest/download/appcast.xml
MIN_MACOS=15.0
APP=.build/Drop.app

scripts/swift.sh build -c "$CONFIG" --product Drop
BIN_DIR=$(scripts/swift.sh build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Drop" "$APP/Contents/MacOS/Drop"
# SwiftPM links Sparkle with an @rpath install name but only adds @loader_path (where it
# leaves the framework in .build); the bundle keeps it in Contents/Frameworks.
# The build also leaves an absolute rpath to its own PackageFrameworks folder: removed, so
# the bundle can only ever load the Sparkle it carries.
for RPATH in $(otool -l "$APP/Contents/MacOS/Drop" | awk '/LC_RPATH/{getline; getline; print $2}' | grep '/\.build/' || true); do
    install_name_tool -delete_rpath "$RPATH" "$APP/Contents/MacOS/Drop" 2>/dev/null
done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Drop" 2>/dev/null
# Sparkle's XPC services exist for sandboxed apps only (Sparkle's Sandboxing guide, "Removing
# XPC Services"); Drop isn't sandboxed, so they're left out: less to sign and notarize.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
rm -f "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

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
    <!-- Sparkle: Drop draws every surface (UpdateDriver). Checks daily without asking,
         downloads in the background unless the user turns that off in Settings.
         No SUEnableInstallerLauncherService: that's for sandboxed apps. -->
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUEnableSystemProfiling</key><false/>
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

# Inside out, as Sparkle's guide lists it, never --deep: each nested executable gets the
# hardened runtime and the identity, then the framework, then the app.
if [ "$SIGN_IDENTITY" = - ]; then TIMESTAMP=--timestamp=none; else TIMESTAMP=--timestamp; fi
sign() { codesign --force --sign "$SIGN_IDENTITY" --options runtime "$TIMESTAMP" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
if [ "$SIGN_IDENTITY" = - ]; then
    # Ad hoc signatures carry no Team ID, so the hardened runtime's library validation would
    # refuse to load the embedded Sparkle. Local and CI builds only; a Developer ID build
    # signs both with one team and keeps library validation on.
    ENTITLEMENTS=$(mktemp -t drop-entitlements)
    trap 'rm -f "$ENTITLEMENTS"' EXIT
    cat > "$ENTITLEMENTS" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
XML
    sign --entitlements "$ENTITLEMENTS" "$APP"
else
    sign "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIG, $VERSION ($BUILD_NUMBER), signed ${SIGN_IDENTITY})"

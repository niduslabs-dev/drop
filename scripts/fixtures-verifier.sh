#!/bin/bash
# Builds the app bundles Tests/VerifierTests checks, into .build/fixtures/verifier/.
#
# Outputs:
#   real/<Name>.app        apps copied out of DMGs already on disk (.claude/spike, .claude/samples).
#                          Untrusted: nothing here is ever launched, only read by codesign/spctl.
#   real/<Name>.dmg        a symlink to the DMG each app came from (for the ticket tests)
#   real/<Name>.codesign   `codesign -dv` output for the app, which the tests compare against
#   synthetic/Unsigned.app a tiny swiftc-built app with no signature
#   synthetic/AdHoc.app    the same app signed ad hoc (`codesign -s -`)
#   synthetic/Tampered.app AdHoc.app with one byte of a sealed resource changed after signing
#
# Never uses a signing identity or the keychain. Mounts read-only, -nobrowse, and detaches
# by device node; a DMG that is missing is skipped with a note.
set -euo pipefail
. "$(dirname "$0")/lib/hdi.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/fixtures/verifier"
REAL="$OUT/real"
SYN="$OUT/synthetic"
MNT="$OUT/mnt"
SPIKE="$ROOT/.claude/spike"
SAMPLES="$ROOT/.claude/samples"

# name|dmg. The spike DMGs cover the DMG-only ticket case (Rectangle, KeePassXC), apps stapled
# themselves (Stats, MonitorControl, Clipy) and nothing stapled (boringNotch).
SOURCES=(
    "Rectangle|$SPIKE/dl-Rectangle2.0.4/Rectangle2.0.4.dmg"
    "KeePassXC|$SPIKE/dl-KeePassXC-2.8.0-1-arm64/KeePassXC-2.8.0-1-arm64.dmg"
    "Stats|$SPIKE/dl-Stats/Stats.dmg"
    "MonitorControl|$SPIKE/dl-MonitorControl.4.4.0/MonitorControl.4.4.0.dmg"
    "Clipy|$SPIKE/dl-Clipy_1.4.2/Clipy_1.4.2.dmg"
    "boringNotch|$SPIKE/dl-boringNotch/boringNotch.dmg"
    "Slack|$SAMPLES/slack/Slack-4.53.287-macOS.dmg"
    "Firefox|$SAMPLES/firefox/Firefox-160.0.dmg"
    "Zed|$SAMPLES/zed/Zed-aarch64.dmg"
    "Transmission|$SAMPLES/transmission/Transmission-4.1.4.dmg"
    "VLC|$SAMPLES/vlc/vlc-3.0.24-arm64.dmg"
)

rm -rf "$OUT"
mkdir -p "$REAL" "$SYN" "$MNT"

# Detaches every image under $MNT still attached (by device node), so a failed run never
# leaves a mount behind.
cleanup() {
    hdiutil info | awk -v mnt="$MNT" '
        /^\/dev\/disk[0-9]+/ { dev = $1 }
        index($0, mnt) > 0 { print dev }' | sort -u |
        while read -r dev; do hdiutil detach "$dev" -force >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

# ---------------------------------------------------------------- real apps
for source in "${SOURCES[@]}"; do
    name="${source%%|*}"
    dmg="${source#*|}"
    if [ ! -f "$dmg" ]; then
        echo "skip $name: $dmg missing"
        continue
    fi
    plist="$(hdi_attach "$dmg" -nobrowse -readonly -noverify -noautoopen -mountrandom "$MNT" -plist)"
    # The whole-disk node is the first dev-entry; detaching it detaches every slice.
    dev="$(printf '%s' "$plist" | plutil -extract system-entities.0.dev-entry raw -o - -)"
    mnt="$(printf '%s' "$plist" | grep -A1 '<key>mount-point</key>' | sed -n 's:.*<string>\(.*\)</string>.*:\1:p' | head -1)"
    app="$(find "$mnt" -maxdepth 1 -name '*.app' -type d | head -1)"
    if [ -z "$app" ]; then
        echo "skip $name: no app at the root of $dmg"
    else
        ditto "$app" "$REAL/$name.app"
        ln -s "$dmg" "$REAL/$name.dmg"
        codesign -dv "$REAL/$name.app" >"$REAL/$name.codesign" 2>&1 || true
        echo "copied $name"
    fi
    hdi detach "$dev"
    if hdiutil info | grep -q "^$dev[[:space:]]"; then
        echo "error: $dev still attached" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------- synthetic app
make_app() {
    local app="$1"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Tiny</string>
    <key>CFBundleIdentifier</key><string>dev.niduslabs.drop.fixture.tiny</string>
    <key>CFBundleName</key><string>Tiny</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
    printf 'a sealed resource\n' >"$app/Contents/Resources/note.txt"
}

make_app "$SYN/Unsigned.app"
printf 'print("tiny")\n' >"$OUT/tiny.swift"
# -Xlinker -no_adhoc_codesign: the linker ad hoc signs arm64 binaries by default, and the
# unsigned fixture must carry no signature at all.
swiftc -O -o "$SYN/Unsigned.app/Contents/MacOS/Tiny" "$OUT/tiny.swift" -Xlinker -no_adhoc_codesign
rm "$OUT/tiny.swift"
if codesign -dv "$SYN/Unsigned.app/Contents/MacOS/Tiny" >/dev/null 2>&1; then
    codesign --remove-signature "$SYN/Unsigned.app/Contents/MacOS/Tiny"
fi

ditto "$SYN/Unsigned.app" "$SYN/AdHoc.app"
codesign -s - --force "$SYN/AdHoc.app"
codesign --verify --deep --strict "$SYN/AdHoc.app"

ditto "$SYN/AdHoc.app" "$SYN/Tampered.app"
printf 'A sealed resource\n' >"$SYN/Tampered.app/Contents/Resources/note.txt"
if codesign --verify --deep --strict "$SYN/Tampered.app" 2>/dev/null; then
    echo "error: Tampered.app still verifies" >&2
    exit 1
fi

echo "fixtures in $OUT"

#!/bin/bash
# Makes reference copies of real apps for the Extractor's opt-in fidelity tests
# (DROP_CORPUS=1) in .build/fixtures/reference/<name>/<App>.app, the way a Finder-style
# copy would: mount the sample DMG read-only and `ditto` the app out.
#
#   scripts/reference-apps.sh            # all of them
#   scripts/reference-apps.sh gimp zed   # just these
#
# The samples are untrusted downloads: they are mounted read-only, hidden from Finder,
# never verified (that would run nothing, but costs minutes) and never run. Every image is
# detached by its device node, and `hdiutil info` must confirm it. Writes `dmg.txt` next to
# each copy with the DMG's path, so the test knows what to extract.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLES="$ROOT/.claude/samples"
OUT="$ROOT/.build/fixtures/reference"
MNT="$OUT/mnt"

# name:dmg:app. A mix of containers and filesystems: HFS+ with zlib/lzfse (Rectangle,
# Slack), APM (Firefox), big lzma (Docker), APFS with 12k files (GIMP), APFS with a
# licence (Zed), HFSX (Spotify), bzip2 (VLC).
APPS=(
    "rectangle:Rectangle2.0.4.dmg:Rectangle.app"
    "slack:Slack-4.53.287-macOS.dmg:Slack.app"
    "firefox:Firefox-160.0.dmg:Firefox.app"
    "docker:Docker.dmg:Docker.app"
    "gimp:gimp-3.2.8-arm64.dmg:GIMP.app"
    "zed:Zed-aarch64.dmg:Zed.app"
    "spotify:Spotify.dmg:Spotify.app"
    "vlc:vlc-3.0.24-arm64.dmg:VLC.app"
)

ATTACHED=""
cleanup() {
    if [ -n "$ATTACHED" ]; then hdiutil detach "$ATTACHED" -force >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

mkdir -p "$OUT" "$MNT"
for spec in "${APPS[@]}"; do
    IFS=: read -r name dmg app <<<"$spec"
    if [ $# -gt 0 ] && [[ " $* " != *" $name "* ]]; then continue; fi
    src="$SAMPLES/$name/$dmg"
    if [ ! -f "$src" ]; then
        echo "$name: $src missing, skipped"
        continue
    fi
    rm -rf "$OUT/$name"
    mkdir -p "$OUT/$name"
    # `yes` answers a licence agreement prompt (Zed); the plist goes to a file.
    yes | hdiutil attach "$src" -nobrowse -readonly -noverify -noautoopen -mountrandom "$MNT" -plist \
        >"$OUT/$name/attach.plist" 2>/dev/null || true
    read -r dev mount < <(python3 -I - "$OUT/$name/attach.plist" <<'PY'
import plistlib, sys
raw = open(sys.argv[1], "rb").read()
start = raw.find(b"<?xml")
entities = plistlib.loads(raw[start:])["system-entities"]
whole = min((e["dev-entry"] for e in entities), key=len)
mount = next(e["mount-point"] for e in entities if "mount-point" in e)
print(whole, mount)
PY
    )
    ATTACHED="$dev"
    ditto "$mount/$app" "$OUT/$name/$app"
    hdiutil detach "$dev" >/dev/null
    if hdiutil info | grep -q "^$dev[[:space:]]"; then
        echo "error: $dev still attached" >&2
        exit 1
    fi
    ATTACHED=""
    rm "$OUT/$name/attach.plist"
    printf '%s\n%s\n' "$src" "$app" >"$OUT/$name/dmg.txt"
    echo "$name: $(find "$OUT/$name/$app" | wc -l | tr -d ' ') items"
done
rmdir "$MNT" 2>/dev/null || true

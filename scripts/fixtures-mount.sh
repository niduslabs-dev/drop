#!/bin/bash
# Builds the images the hidden-mount tests use (Tests/MounterTests, Tests/InstallerTests),
# into .build/fixtures/mount/. Needs scripts/fixtures-verifier.sh first (for AdHoc.app).
#
# Outputs, each holding AdHoc.app as "Tiny.app" (an ad hoc signed app: valid, not notarized):
#   encrypted.dmg        AES-256 UDZO; password in THROWAWAY_PASSWORD below
#   sparse.sparseimage   UDSP
#   bundle.sparsebundle  UDSB
#   compressed.dmg       UDZO whose app was copied with `ditto --hfsCompression` onto the
#                        mounted read-write image, so its files are decmpfs-compressed
#   licence.dmg          UDZO with a plain-text licence agreement added by `hdiutil udifrez`
#   source/Tiny.app      the app every image holds, for comparing installed copies
#
# Mounts only the read-write image it just created, -nobrowse, and detaches it by device node.
set -euo pipefail
. "$(dirname "$0")/lib/hdi.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYN="$ROOT/.build/fixtures/verifier/synthetic"
OUT="$ROOT/.build/fixtures/mount"
MNT="$OUT/mnt"
# Not a secret: it only locks a test image of a test app.
THROWAWAY_PASSWORD="drop-mount-fixture-only"
[ -d "$SYN/AdHoc.app" ] || { echo "run scripts/fixtures-verifier.sh first" >&2; exit 1; }

cleanup() {
    hdiutil info | awk -v mnt="$MNT" '
        /^\/dev\/disk[0-9]+/ { dev = $1 }
        index($0, mnt) > 0 { print dev }' | sort -u |
        while read -r dev; do hdiutil detach "$dev" -force >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

rm -rf "$OUT"
mkdir -p "$OUT/source" "$MNT"
src="$OUT/source"
ditto "$SYN/AdHoc.app" "$src/Tiny.app"

HDI_STDIN="$THROWAWAY_PASSWORD" hdi_create -fs HFS+ -format UDZO -encryption AES-256 -stdinpass \
    -volname Encrypted -srcfolder "$src" "$OUT/encrypted.dmg"
hdi_create -fs HFS+ -format UDSP -volname Sparse -srcfolder "$src" "$OUT/sparse.sparseimage"
hdi_create -fs HFS+ -format UDSB -volname Bundle -srcfolder "$src" "$OUT/bundle.sparsebundle"

# decmpfs: hdiutil -srcfolder doesn't keep compression, so ditto writes the app onto the
# mounted read-write image itself.
hdi_create -fs HFS+ -type UDIF -size 16m -volname Compressed "$OUT/compressed-rw.dmg"
plist="$(hdi_attach -nobrowse -noautoopen -noverify -mountrandom "$MNT" -plist "$OUT/compressed-rw.dmg")"
dev="$(printf '%s' "$plist" | plutil -extract system-entities.0.dev-entry raw -)"
mnt="$(printf '%s' "$plist" | grep -A1 '<key>mount-point</key>' | sed -n 's:.*<string>\(.*\)</string>.*:\1:p' | head -1)"
ditto --hfsCompression "$src/Tiny.app" "$mnt/Tiny.app"
if ! ls -lOR "$mnt/Tiny.app" | grep -q compressed; then
    echo "ditto did not compress any file in compressed.dmg" >&2
    exit 1
fi
sync
hdi detach "$dev"
hdi convert "$OUT/compressed-rw.dmg" -format UDZO -o "$OUT/compressed.dmg"
rm -f "$OUT/compressed-rw.dmg"

# A licence agreement: LPic (one language, region 0, resource 5000), its TEXT and STR#.
hdi_create -fs HFS+ -format UDZO -volname Licence -srcfolder "$src" "$OUT/licence.dmg"
python3 -I - "$OUT/licence.plist" <<'PY'
import plistlib, sys
def pascal(s):
    b = s.encode("mac_roman")
    return bytes([len(b)]) + b
strings = ["English", "Agree", "Disagree", "Print", "Save...", "Drop fixture licence. Agree?"]
resources = {
    "LPic": [{"Attributes": "0x0000", "ID": "5000", "Name": "", "Data": bytes.fromhex("00000001000000000000")}],
    "TEXT": [{"Attributes": "0x0000", "ID": "5000", "Name": "English",
              "Data": b"Drop fixture licence agreement.\rThis image exists only for tests.\r"}],
    "STR#": [{"Attributes": "0x0000", "ID": "5000", "Name": "English",
              "Data": len(strings).to_bytes(2, "big") + b"".join(pascal(s) for s in strings)}],
}
with open(sys.argv[1], "wb") as f:
    plistlib.dump(resources, f)
PY
# udifrez takes the image before its options on macOS 27 (deprecated, still works).
hdi udifrez "$OUT/licence.dmg" -xml "$OUT/licence.plist"
rm -f "$OUT/licence.plist"

rmdir "$MNT"
if hdiutil info | grep -q "$OUT"; then
    echo "a fixture image is still attached; detach it by hand" >&2
    exit 1
fi
ls -l "$OUT"

#!/bin/bash
# Builds the DiskImage test fixtures into .build/fixtures/diskimage/ (gitignored).
#
# For each filesystem (HFS+, APFS) and layout (GPTSPUD = GPT, SPUD = Apple Partition
# Map, NONE = bare filesystem) it makes one image with `hdiutil create -srcfolder`,
# converts it to every UDIF format, and writes the matching raw reference
# (`hdiutil convert -format UDTO`) next to each. Also an encrypted image, a sparse
# image and an ad-hoc signed image. APFS on an Apple Partition Map is skipped: hdiutil
# refuses it. UDRW and UDTO come out as plain raw images without a koly trailer. Mounts
# one image read-only once to check the source folder made it in, then detaches it by
# device node.
#
# Usage: scripts/fixtures-diskimage.sh
set -euo pipefail
. "$(dirname "$0")/lib/hdi.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/fixtures/diskimage"
SRC="$OUT/src"
FORMATS=(UDZO UDBZ ULFO ULMO UDCO UDRO UDRW UDTO)
LAYOUTS=(GPTSPUD SPUD NONE)
FILESYSTEMS=(HFS+ APFS)
THROWAWAY_PASSWORD="drop-fixture-only"

rm -rf "$OUT"
mkdir -p "$SRC/Folder"
printf 'hello from drop\n' > "$SRC/hello.txt"
printf 'nested\n' > "$SRC/Folder/nested.txt"
head -c 393216 /dev/urandom > "$SRC/random.bin"
dd if=/dev/zero of="$SRC/zeros.bin" bs=1024 count=768 status=none
ln -s hello.txt "$SRC/link"

fs_tag() { [ "$1" = "HFS+" ] && echo hfs || echo apfs; }

for fs in "${FILESYSTEMS[@]}"; do
    for layout in "${LAYOUTS[@]}"; do
        # hdiutil refuses APFS on an Apple Partition Map ("Invalid argument").
        [ "$fs" = APFS ] && [ "$layout" = SPUD ] && continue
        base="$OUT/$(fs_tag "$fs")-$layout"
        hdi_create -srcfolder "$SRC" -volname DropFixture -fs "$fs" \
            -layout "$layout" -format UDRW "$base-master.dmg"
        for format in "${FORMATS[@]}"; do
            image="$base-$format.dmg"
            # UDTO writes `<name>.cdr`; keep the .dmg name so tests find every format alike.
            hdi convert "$base-master.dmg" -format "$format" -ov -o "$image"
            [ -f "$image.cdr" ] && mv "$image.cdr" "$image"
            hdi convert "$image" -format UDTO -ov -o "$image.ref"
            mv "$image.ref.cdr" "$image.cdr"
        done
        rm -f "$base-master.dmg"
    done
done

HDI_STDIN="$THROWAWAY_PASSWORD" hdi_create -srcfolder "$SRC" -fs HFS+ \
    -format UDZO -encryption AES-128 -stdinpass "$OUT/encrypted.dmg"
hdi_create -size 8m -fs HFS+ -volname DropSparse -type SPARSE "$OUT/sparse"
cp "$OUT/hfs-GPTSPUD-UDZO.dmg" "$OUT/signed.dmg"
codesign -s - "$OUT/signed.dmg"

# One read-only mount to confirm the fixture holds the source folder.
plist="$(hdi_attach -nobrowse -readonly -noautoopen -mountrandom "$OUT" -plist "$OUT/hfs-GPTSPUD-UDZO.dmg")"
device="$(printf '%s' "$plist" | plutil -extract system-entities.0.dev-entry raw -)"
mount_point="$(printf '%s' "$plist" | grep -A1 '<key>mount-point</key>' | sed -n 's:.*<string>\(.*\)</string>.*:\1:p' | head -1)"
status=0
cmp -s "$SRC/random.bin" "$mount_point/random.bin" || status=1
hdi detach "$device"
if hdiutil info | grep -q "$OUT"; then
    echo "fixture image still attached; detach it by hand" >&2
    exit 1
fi
[ "$status" -eq 0 ] || { echo "mounted fixture does not match the source folder" >&2; exit 1; }

echo "fixtures in $OUT"

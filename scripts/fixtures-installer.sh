#!/bin/bash
# Builds the small DMGs Tests/InstallerTests uses, into .build/fixtures/installer/.
# Needs scripts/fixtures-verifier.sh first (for its synthetic apps).
#
# Outputs (all UDZO, made with `hdiutil create -srcfolder`; nothing is attached by hand):
#   one-app.dmg     AdHoc.app as "Tiny.app" plus an Applications symlink: valid, not notarized
#   tampered.dmg    Tampered.app as "Tiny.app": a broken signature
#   pkg-only.dmg    a stand-in "Tiny Installer.pkg" file and no app
#   two-apps.dmg    AdHoc.app and Unsigned.app side by side
#   no-app.dmg      only a text file
#   apple-signed.dmg  a copy of /System/Applications/Stickies.app as "Stickies.app": a real
#                     certificate signature (Apple's own) for the fast signer read
#   unsigned.dmg    Unsigned.app as "Tiny.app": no signature at all
set -euo pipefail
. "$(dirname "$0")/lib/hdi.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYN="$ROOT/.build/fixtures/verifier/synthetic"
OUT="$ROOT/.build/fixtures/installer"
[ -d "$SYN/AdHoc.app" ] || { echo "run scripts/fixtures-verifier.sh first" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/src"

make_dmg() {
    local name="$1" folder="$2"
    hdi_create -fs HFS+ -format UDZO -volname "$name" -srcfolder "$folder" "$OUT/$name.dmg"
}

src="$OUT/src/one-app"; mkdir -p "$src"
ditto "$SYN/AdHoc.app" "$src/Tiny.app"; ln -s /Applications "$src/Applications"
make_dmg one-app "$src"

src="$OUT/src/tampered"; mkdir -p "$src"
ditto "$SYN/Tampered.app" "$src/Tiny.app"
make_dmg tampered "$src"

src="$OUT/src/pkg-only"; mkdir -p "$src"
printf 'not a real package\n' >"$src/Tiny Installer.pkg"
make_dmg pkg-only "$src"

src="$OUT/src/two-apps"; mkdir -p "$src"
ditto "$SYN/AdHoc.app" "$src/Tiny.app"; ditto "$SYN/Unsigned.app" "$src/Other.app"
make_dmg two-apps "$src"

src="$OUT/src/no-app"; mkdir -p "$src"
printf 'hello\n' >"$src/readme.txt"
make_dmg no-app "$src"

src="$OUT/src/apple-signed"; mkdir -p "$src"
cp -R /System/Applications/Stickies.app "$src/Stickies.app"
make_dmg apple-signed "$src"

src="$OUT/src/unsigned"; mkdir -p "$src"
ditto "$SYN/Unsigned.app" "$src/Tiny.app"
make_dmg unsigned "$src"

rm -rf "$OUT/src"
ls -l "$OUT"

#!/bin/bash
# Builds the HFS+ and HFSX test volumes for Tests/HFSPlusTests into .build/fixtures/hfsplus/.
#
# Outputs:
#   hfsplus.cdr, hfsx.cdr          raw volumes (-layout NONE, so the volume header is at 1024)
#   manifest-hfsplus.jsonl, ...    what the kernel shows when each volume is mounted read-only;
#                                  the tests compare the reader against these
#   source.jsonl                   the same listing of the source folder
#   preservation.txt               how the mounted volumes differ from the source folder
#   corpus/<name>.cdr              raw copies of three HFS+ sample DMGs (skipped if missing)
#
# Mounts only to build and verify, always -nobrowse, and detaches by device node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/fixtures/hfsplus"
STAGE="$OUT/DropHFS"
VOLNAME="DropHFS"
SAMPLES="$ROOT/.claude/samples"

rm -rf "$OUT"
mkdir -p "$OUT"

# Detaches every image under $OUT that is still attached (by device node), so a failed
# run never leaves a mount behind. `attach` runs in a subshell, so it can't record devices.
cleanup() {
    hdiutil info | awk -v out="$OUT" '
        /^image-path/ { mine = index($0, out) > 0 }
        mine && /^\/dev\/disk[0-9]+[ \t]/ { print $1; mine = 0 }' |
        while read -r dev; do hdiutil detach "$dev" -force >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

# attach <image> <ro|rw>: prints "<device> <mountpoint>".
attach() {
    local flags=(-nobrowse -noautoopen -mountrandom "$OUT/mnt")
    [ "$2" = ro ] && flags+=(-readonly)
    mkdir -p "$OUT/mnt"
    local line
    line="$(hdiutil attach "$1" "${flags[@]}" 2>/dev/null | grep -E '/dev/disk[0-9]+' | grep -E 'Apple_HFS|/' | tail -1)"
    local dev mnt
    dev="$(echo "$line" | awk '{print $1}')"
    mnt="$(echo "$line" | sed -E 's/^[^\t]*\t[^\t]*\t//; s/^[[:space:]]+//')"
    echo "$dev|$mnt"
}

detach() {
    hdiutil detach "$1" >/dev/null 2>&1
    if hdiutil info | grep -q "^$1[[:space:]]"; then
        echo "error: $1 still attached" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------- source folder
python3 -I - "$STAGE" <<'PY'
import ctypes, ctypes.util, os, subprocess, sys, unicodedata
root = sys.argv[1]
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
XATTR_NOFOLLOW = 1

def setxattr(path, name, value):
    if libc.setxattr(path.encode(), name.encode(), value, len(value), 0, XATTR_NOFOLLOW) != 0:
        raise OSError(ctypes.get_errno(), "setxattr " + path)

def write(rel, data, mode=0o644):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data)
    os.chmod(p, mode)
    return p

os.makedirs(root)
# Keep fseventsd and Spotlight out of the volumes while they are mounted read-write.
write(".fseventsd/no_log", b"")
write(".metadata_never_index", b"")

write("a/b/c/d/e/deep.txt", b"deep\n")
for d in ["a", "a/b", "a/b/c", "a/b/c/d", "a/b/c/d/e"]:
    os.chmod(os.path.join(root, d), 0o755)

# Enough catalog records for many leaf nodes and at least two index levels.
for i in range(2000):
    write("many/file-with-a-fairly-long-name-%04d.txt" % i, b"file %d\n" % i)

# Unicode: one name created NFC, one NFD; HFS+ stores both decomposed.
write(unicodedata.normalize("NFC", "unicode/café-nfc.txt"), b"nfc\n")
write(unicodedata.normalize("NFD", "unicode/naïve-nfd.txt"), b"nfd\n")
write("unicode/emoji-\U0001F600-\U0001F468‍\U0001F469‍\U0001F467.txt", b"emoji\n")
write("unicode/日本語.txt", b"cjk\n")
write("unicode/colon:name.txt", b"colon\n")

# Modes.
write("modes/exec.sh", b"#!/bin/sh\necho hi\n", 0o755)
write("modes/private.txt", b"private\n", 0o600)
write("modes/group.txt", b"group\n", 0o640)
write("modes/readonly.txt", b"readonly\n", 0o444)
write("modes/owner-exec", b"x\n", 0o700)
os.makedirs(os.path.join(root, "modes/locked-dir"))
os.chmod(os.path.join(root, "modes/locked-dir"), 0o700)
write("modes/empty.txt", b"")

# Links.
write("links/target.txt", b"symlink target\n")
os.symlink("target.txt", os.path.join(root, "links/relative-link"))
os.symlink("../a/b/c/d/e/deep.txt", os.path.join(root, "links/deep-link"))
os.symlink("does/not/exist", os.path.join(root, "links/dangling-link"))
write("links/hard-a.txt", b"hard link contents\n" * 10)
os.link(os.path.join(root, "links/hard-a.txt"), os.path.join(root, "links/hard-b.txt"))

# Extended attributes: inline and fork-data sized, plus a resource fork.
p = write("xattrs/small.txt", b"small xattr\n")
setxattr(p, "com.example.small", b"hello")
setxattr(p, "com.example.empty", b"")
p = write("xattrs/large.txt", b"large xattr\n")
setxattr(p, "com.example.large", bytes((i * 7) % 251 for i in range(5000)))
setxattr(p, "com.example.small", b"also small")
p = write("xattrs/rsrc.txt", b"has a resource fork\n")
setxattr(p, "com.apple.ResourceFork", bytes((i * 13) % 256 for i in range(3000)))

# The decmpfs source. `ditto --hfsCompression` leaves files on APFS uncompressed (macOS
# 27), so the compressed copy is written onto each mounted volume instead.
with open(os.path.join(root, "..", "compress-src.txt"), "wb") as f:
    f.write(b"compress me please " * 20000)
PY

# Fragmented file: written later, straight onto the mounted HFS+ volume, by appending in
# turns with a filler file so its extents interleave. Its source copy lives outside the
# stage until the manifests are taken.
FRAG="$OUT/frag-stage"
mkdir -p "$FRAG"
python3 -I - "$FRAG" <<'PY'
import os, sys
root = sys.argv[1]
chunk = 128 * 1024
with open(os.path.join(root, "big.bin"), "wb") as f:
    for i in range(24):
        f.write(bytes([(i * 31 + j) % 256 for j in range(256)]) * (chunk // 256))
for i in range(24):
    with open(os.path.join(root, "fill-%02d.bin" % i), "wb") as f:
        f.write(bytes([i]) * 8192)
PY

# ---------------------------------------------------------------- manifest tool
manifest() {
    python3 -I - "$1" <<'PY'
import ctypes, ctypes.util, hashlib, json, os, stat, sys
root = sys.argv[1]
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
UF_COMPRESSED = 0x20

def xattrs(path):
    size = libc.listxattr(path.encode(), None, 0, 1)
    if size <= 0:
        return []
    buf = ctypes.create_string_buffer(size)
    size = libc.listxattr(path.encode(), buf, size, 1)
    return sorted(n.decode() for n in buf.raw[:size].split(b"\0") if n)

class _AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_ushort), ("commonattr", ctypes.c_uint32),
                ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                ("forkattr", ctypes.c_uint32)]
libc.getattrlist.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
def birthtime(p):
    # ATTR_CMN_CRTIME with FSOPT_NOFOLLOW: [seconds, nanoseconds], which os.lstat's float would round.
    import struct
    al = _AttrList(5, 0, 0x200, 0, 0, 0, 0)
    buf = ctypes.create_string_buffer(64)
    if libc.getattrlist(os.fsencode(p), ctypes.byref(al), buf, 64, 1) != 0: return None
    return list(struct.unpack_from("<qq", buf.raw, 4))

def walk(dir, rel):
    for name in sorted(os.listdir(dir)):
        p = os.path.join(dir, name)
        r = rel + [name]
        st = os.lstat(p)
        e = {"path": "/".join(r), "mode": st.st_mode & 0o7777, "xattrs": xattrs(p),
             "compressed": bool(st.st_flags & UF_COMPRESSED), "nlink": st.st_nlink, "ino": st.st_ino,
             "birthtime": birthtime(p)}
        if stat.S_ISLNK(st.st_mode):
            e.update(kind="symlink", target=os.readlink(p))
        elif stat.S_ISDIR(st.st_mode):
            e.update(kind="directory")
        else:
            with open(p, "rb") as f:
                data = f.read()
            e.update(kind="file", size=len(data), sha256=hashlib.sha256(data).hexdigest())
        print(json.dumps(e, ensure_ascii=False))
        if stat.S_ISDIR(st.st_mode):
            walk(p, r)

walk(root, [])
PY
}

add_compressed() {
    mkdir "$1/compressed"
    ditto --hfsCompression "$OUT/compress-src.txt" "$1/compressed/text.txt"
    if ! ls -lO "$1/compressed/text.txt" | grep -q compressed; then
        echo "warning: ditto did not compress compressed/text.txt" >&2
    fi
}

# ---------------------------------------------------------------- HFSX (case-sensitive)
hdiutil create -quiet -layout NONE -fs "Case-sensitive HFS+" -format UDRW -size 64m -volname "$VOLNAME" \
    -srcfolder "$STAGE" "$OUT/hfsx-rw.dmg"
IFS='|' read -r dev mnt <<<"$(attach "$OUT/hfsx-rw.dmg" rw)"
mkdir "$mnt/case"
printf 'lower\n' >"$mnt/case/readme.txt"
printf 'upper\n' >"$mnt/case/README.txt"
printf 'mixed\n' >"$mnt/case/ReadMe.txt"
add_compressed "$mnt"
sync
detach "$dev"
hdiutil convert -quiet "$OUT/hfsx-rw.dmg" -format UDTO -o "$OUT/hfsx"
rm "$OUT/hfsx-rw.dmg"

# ---------------------------------------------------------------- HFS+ (with fragmentation)
hdiutil create -quiet -layout NONE -fs HFS+ -format UDRW -size 64m -volname "$VOLNAME" \
    -srcfolder "$STAGE" "$OUT/hfsplus-rw.dmg"
IFS='|' read -r dev mnt <<<"$(attach "$OUT/hfsplus-rw.dmg" rw)"
mkdir "$mnt/frag"
add_compressed "$mnt"
python3 -I - "$FRAG" "$mnt/frag" <<'PY'
import os, sys
src, dst = sys.argv[1:]
chunk = 128 * 1024
with open(os.path.join(src, "big.bin"), "rb") as f:
    big = f.read()
out = os.open(os.path.join(dst, "big.bin"), os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(24):
    os.write(out, big[i * chunk:(i + 1) * chunk])
    os.fsync(out)
    with open(os.path.join(src, "fill-%02d.bin" % i), "rb") as f:
        data = f.read()
    with open(os.path.join(dst, "fill-%02d.bin" % i), "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
os.close(out)
PY
sync
detach "$dev"
hdiutil convert -quiet "$OUT/hfsplus-rw.dmg" -format UDTO -o "$OUT/hfsplus"
rm "$OUT/hfsplus-rw.dmg"

# ---------------------------------------------------------------- manifests
mv "$FRAG" "$STAGE/frag"
mkdir "$STAGE/compressed"
cp "$OUT/compress-src.txt" "$STAGE/compressed/text.txt"
manifest "$STAGE" >"$OUT/source.jsonl"
for name in hfsplus hfsx; do
    IFS='|' read -r dev mnt <<<"$(attach "$OUT/$name.cdr" ro)"
    manifest "$mnt" >"$OUT/manifest-$name.jsonl"
    detach "$dev"
done
rmdir "$OUT/mnt" 2>/dev/null || true

# ---------------------------------------------------------------- what hdiutil kept
python3 -I - "$OUT" >"$OUT/preservation.txt" <<'PY'
import json, os, sys
out = sys.argv[1]
load = lambda n: {e["path"]: e for e in map(json.loads, open(os.path.join(out, n)))}
src, img = load("source.jsonl"), load("manifest-hfsplus.jsonl")
fields = ["kind", "mode", "size", "sha256", "target", "xattrs", "compressed"]
print("source entries:", len(src), "image entries:", len(img))
print("missing from image:", sorted(set(src) - set(img))[:20])
print("extra in image:", sorted(set(img) - set(src))[:20])
for p in sorted(set(src) & set(img)):
    for k in fields:
        if src[p].get(k) != img[p].get(k):
            print("%s: %s source=%r image=%r" % (p, k, src[p].get(k), img[p].get(k)))
inos = {}
for p, e in img.items():
    if e["kind"] == "file" and e["nlink"] > 1:
        inos.setdefault(e["ino"], []).append(p)
print("hard link groups in image:", list(inos.values()))
PY
cat "$OUT/preservation.txt"

# ---------------------------------------------------------------- corpus (opt-in tests)
mkdir -p "$OUT/corpus"
for pair in rectangle:Rectangle2.0.4.dmg slack:Slack-4.53.287-macOS.dmg firefox:Firefox-160.0.dmg; do
    name="${pair%%:*}"
    dmg="$SAMPLES/$name/${pair#*:}"
    if [ -f "$dmg" ]; then
        hdiutil convert -quiet "$dmg" -format UDTO -o "$OUT/corpus/$name"
    else
        echo "corpus: $dmg missing, skipped"
    fi
done

echo "fixtures ready in $OUT"

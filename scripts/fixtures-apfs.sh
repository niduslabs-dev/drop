#!/bin/bash
# Builds the APFS test fixtures into .build/fixtures/apfs/ (gitignored).
#
#   scripts/fixtures-apfs.sh            # synthetic images (case-insensitive and case-sensitive)
#
# Outputs:
#   src/                      the source folder handed to `hdiutil create -srcfolder`
#   source-manifest.jsonl     manifest of src/
#   ci.img, cs.img            raw APFS containers (no partition map, NXSB at byte 32)
#   ci-manifest.jsonl, ...    manifest of each image as macOS mounts it: the tests' ground truth
#   preserved.txt             what hdiutil kept from src/ (sparse, hard links, compression, xattrs)
#
# After `hdiutil create` each image is attached read-write once to add what a plain copy
# can't produce reliably: a file fragmented into many extents, a sparse file written in
# place, and (case-sensitive image only) names that differ only by case. It is then
# converted to UDTO and attached read-only to record the manifest. Every attach is
# detached by its device node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/fixtures/apfs"
SRC="$OUT/src"
WORK="$OUT/work"
VOLNAME="DropAPFS"
ATTACHED=()

detach_all() {
    for dev in "${ATTACHED[@]:-}"; do
        [ -n "$dev" ] && hdiutil detach "$dev" -force >/dev/null 2>&1 || true
    done
    ATTACHED=()
}
trap detach_all EXIT

# Attaches an image and prints "<device> <mountpoint>".
attach() {
    local image="$1"; shift
    local plist dev mnt
    plist="$(hdiutil attach "$image" -nobrowse -noautoopen -mountrandom "$WORK" -plist "$@")"
    dev="$(printf '%s' "$plist" | python3 -I -c 'import plistlib,sys
e=[x for x in plistlib.loads(sys.stdin.buffer.read())["system-entities"] if "mount-point" in x]
print(e[0]["dev-entry"], e[0]["mount-point"])')"
    echo "$dev"
}

detach() {
    hdiutil detach "$1" >/dev/null
    local remaining=()
    for d in "${ATTACHED[@]:-}"; do [ "$d" != "$1" ] && [ -n "$d" ] && remaining+=("$d"); done
    ATTACHED=("${remaining[@]:-}")
    if hdiutil info | grep -q "^$1[[:space:]]"; then
        echo "error: $1 still attached" >&2
        exit 1
    fi
}

# Writes a JSON-lines manifest of a tree: path, kind, mode, size, sha256, symlink target,
# xattr names with sizes and hashes, BSD flags, link count, inode and creation time.
manifest() {
    python3 -I - "$1" "$2" <<'PY'
import ctypes, hashlib, json, os, stat, sys
root, out = sys.argv[1], sys.argv[2]
libc = ctypes.CDLL(None, use_errno=True)
libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
libc.listxattr.restype = libc.getxattr.restype = ctypes.c_ssize_t
NOFOLLOW, SHOWCOMPRESSION = 0x1, 0x20
def xattrs(p):
    b = os.fsencode(p); opts = NOFOLLOW | SHOWCOMPRESSION
    n = libc.listxattr(b, None, 0, opts)
    if n <= 0: return {}
    buf = ctypes.create_string_buffer(n); n = libc.listxattr(b, buf, n, opts)
    res = {}
    for name in buf.raw[:n].split(b'\0'):
        if not name: continue
        size = libc.getxattr(b, name, None, 0, 0, opts)
        val = ctypes.create_string_buffer(max(size, 1))
        got = libc.getxattr(b, name, val, size, 0, opts)
        data = val.raw[:max(got, 0)]
        res[name.decode()] = {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    return res
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
rows = []
for dirpath, dirs, files in os.walk(root):
    dirs.sort(); files.sort()
    for name in dirs + files:
        p = os.path.join(dirpath, name); st = os.lstat(p)
        rel = os.path.relpath(p, root)
        if stat.S_ISLNK(st.st_mode): kind = 'symlink'
        elif stat.S_ISDIR(st.st_mode): kind = 'directory'
        elif stat.S_ISREG(st.st_mode): kind = 'file'
        else: kind = 'other'
        row = {'path': rel, 'kind': kind, 'mode': st.st_mode & 0o7777, 'size': st.st_size if kind == 'file' else 0,
               'flags': st.st_flags, 'nlink': st.st_nlink, 'ino': st.st_ino, 'blocks': st.st_blocks,
               'xattrs': xattrs(p), 'birthtime': birthtime(p)}
        if kind == 'file':
            h = hashlib.sha256()
            with open(p, 'rb') as f:
                for chunk in iter(lambda: f.read(1 << 20), b''): h.update(chunk)
            row['sha256'] = h.hexdigest()
        if kind == 'symlink': row['target'] = os.readlink(p)
        rows.append(row)
with open(out, 'w') as f:
    for r in rows: f.write(json.dumps(r, ensure_ascii=False) + '\n')
print('%s: %d entries' % (out, len(rows)))
PY
}

make_source() {
    rm -rf "$SRC"; mkdir -p "$SRC"
    cd "$SRC"
    # ~2,000 small files across nested directories, so the fs tree needs several levels.
    for d in $(seq -w 0 19); do
        mkdir -p "many/d$d"
        for f in $(seq -w 0 99); do printf 'file %s/%s\n' "$d" "$f" > "many/d$d/f$f.txt"; done
    done
    mkdir -p deep/a/b/c/d/e/f/g && echo "deep" > deep/a/b/c/d/e/f/g/leaf.txt
    head -c 24000000 /dev/urandom > large.bin
    # Sparse in the source; whether the copy keeps the hole is recorded in preserved.txt.
    python3 -I -c 'import sys; f = open(sys.argv[1], "wb"); f.truncate(8 << 20); f.seek((8 << 20) - 4); f.write(b"tail")' sparse-src.bin
    mkdir -p unicode/nfc unicode/nfd
    echo nfc > "unicode/nfc/$(printf 'caf\xc3\xa9').txt"
    echo nfd > "unicode/nfd/$(printf 'cafe\xcc\x81').txt"
    echo rocket > "unicode/$(printf '\xf0\x9f\x9a\x80') launch.txt"
    echo "日本語" > "unicode/$(printf '\xe6\x97\xa5\xe6\x9c\xac').txt"
    ln -s many/d00/f00.txt link-relative
    ln -s /nonexistent/absolute/target link-absolute
    echo "shared" > hard-a.txt && ln hard-a.txt hard-b.txt
    printf '#!/bin/sh\necho hi\n' > tool.sh && chmod 0755 tool.sh
    echo secret > private.txt && chmod 0600 private.txt
    echo readonly > readonly.txt && chmod 0444 readonly.txt
    mkdir -p locked-dir && echo x > locked-dir/inside.txt && chmod 0700 locked-dir
    touch empty.txt
    echo xattrs > xattr-file.txt
    xattr -w com.example.small "small value" xattr-file.txt
    xattr -w com.example.large "$(head -c 6000 /dev/zero | tr '\0' 'L')" xattr-file.txt
    echo data > rsrc-file.txt
    head -c 5000 /dev/urandom > rsrc-file.txt/..namedfork/rsrc
    # On one volume ditto clones instead of compressing, so these stay plain in src/.
    mkdir -p compressed
    python3 -I -c 'import sys; sys.stdout.write("compressible line of text\n" * 40000)' > "$WORK/big.txt"
    python3 -I -c 'import sys; sys.stdout.write("tiny compressible " * 200)' > "$WORK/tiny.txt"
    ditto --hfsCompression "$WORK/big.txt" compressed/big.txt
    ditto --hfsCompression "$WORK/tiny.txt" compressed/tiny.txt
    cd "$ROOT"
}

# Adds in-place content that `-srcfolder` copying can't be relied on to produce.
edit_image() {
    local mnt="$1" variant="$2"
    python3 -I - "$mnt" <<'PY'
import os, sys
mnt = sys.argv[1]
chunk = 64 * 1024
with open(os.path.join(mnt, 'fragmented.bin'), 'wb') as a, open(os.path.join(mnt, 'filler.bin'), 'wb') as b:
    for i in range(48):
        a.write(bytes([i]) * chunk); a.flush(); os.fsync(a.fileno())
        b.write(bytes([255 - i]) * chunk); b.flush(); os.fsync(b.fileno())
with open(os.path.join(mnt, 'sparse.bin'), 'wb') as f:
    f.write(b'head')
    f.truncate(16 * 1024 * 1024)
    f.seek(16 * 1024 * 1024 - 4); f.write(b'tail')
PY
    # ditto only compresses when it really copies (across volumes), and -srcfolder drops
    # compression anyway, so compressed files are written straight into the image.
    mkdir -p "$mnt/compressed-in-image"
    ditto --hfsCompression "$WORK/big.txt" "$mnt/compressed-in-image/big.txt"
    ditto --hfsCompression "$WORK/tiny.txt" "$mnt/compressed-in-image/tiny.txt"
    if [ "$variant" = cs ]; then
        mkdir -p "$mnt/case" && echo upper > "$mnt/case/Name.txt" && echo lower > "$mnt/case/name.txt"
    fi
    sync
}

build_image() {
    local variant="$1" fs="$2"
    local rw="$WORK/$variant-rw.dmg" img="$OUT/$variant.img"
    rm -f "$rw" "$img" "$OUT/$variant.img.cdr"
    hdiutil create -quiet -fs "$fs" -layout NONE -format UDRW -srcfolder "$SRC" -volname "$VOLNAME" "$rw" 2>/dev/null
    local info dev mnt
    info="$(attach "$rw")"; dev="${info%% *}"; mnt="${info#* }"; ATTACHED+=("$dev")
    edit_image "$mnt" "$variant"
    detach "$dev"
    hdiutil convert -quiet "$rw" -format UDTO -o "$img"
    [ -f "$img.cdr" ] && mv "$img.cdr" "$img"
    info="$(attach "$img" -readonly)"; dev="${info%% *}"; mnt="${info#* }"; ATTACHED+=("$dev")
    manifest "$mnt" "$OUT/$variant-manifest.jsonl"
    detach "$dev"
    rm -f "$rw"
}

report_preserved() {
    python3 -I - "$OUT/source-manifest.jsonl" "$OUT/ci-manifest.jsonl" > "$OUT/preserved.txt" <<'PY'
import json, sys
load = lambda p: {r['path']: r for r in map(json.loads, open(p))}
src, img = load(sys.argv[1]), load(sys.argv[2])
UF_COMPRESSED = 0x20
def line(what, ok, detail=''): print('%-28s %s %s' % (what, 'kept' if ok else 'LOST', detail))
for p in ('sparse-src.bin', 'sparse.bin'):
    i = img.get(p, {})
    line('sparse ' + p, i.get('blocks', 1 << 30) * 512 < i.get('size', 0), 'blocks %s for size %s (source blocks %s)' % (i.get('blocks'), i.get('size'), src.get(p, {}).get('blocks')))
line('hard links', img.get('hard-a.txt', {}).get('nlink', 1) > 1, 'nlink %s' % img.get('hard-a.txt', {}).get('nlink'))
for p in ('compressed/big.txt', 'compressed/tiny.txt', 'compressed-in-image/big.txt', 'compressed-in-image/tiny.txt'):
    r = img.get(p, {})
    line('compression ' + p, bool(r.get('flags', 0) & UF_COMPRESSED), 'xattrs %s' % sorted(r.get('xattrs', {})))
x = img.get('xattr-file.txt', {}).get('xattrs', {})
line('xattrs small+large', 'com.example.small' in x and 'com.example.large' in x, str({k: v['size'] for k, v in x.items()}))
r = img.get('rsrc-file.txt', {}).get('xattrs', {})
line('resource fork', 'com.apple.ResourceFork' in r, str({k: v['size'] for k, v in r.items()}))
for p, row in sorted(src.items()):
    o = img.get(p)
    if o is None: print('missing in image:', p); continue
    if o['mode'] != row['mode']: print('mode changed: %s %o -> %o' % (p, row['mode'], o['mode']))
    if o.get('sha256') != row.get('sha256'): print('content changed:', p)
for p in sorted(set(img) - set(src)): print('only in image:', p)
PY
    cat "$OUT/preserved.txt"
}

mkdir -p "$OUT" "$WORK"
make_source
manifest "$SRC" "$OUT/source-manifest.jsonl"
build_image ci "APFS"
build_image cs "Case-sensitive APFS"
report_preserved
rm -rf "$WORK"
echo "fixtures ready in $OUT"

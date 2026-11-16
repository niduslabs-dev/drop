# Drop

A Mac app that installs an app straight out of a `.dmg` without mounting it, and offers to when a new DMG lands in Downloads. GPL-3.0. Plan, decisions and the design canvas link live in the Nidus Labs workspace (`plans/drop.md`), not in this repo. Research, benchmarks and the sample DMGs: `.claude/` (gitignored).

## Layout

A Swift package (`Package.swift`), no Xcode project yet:

- `ReaderCore`: shared types (`BlockDevice`, `FileSystem`, `Entry`, `Extent`, `ByteReader`, `ReaderError`).
- `DiskImage`: UDIF container, decoders, partition maps.
- `HFSPlus`, `APFS`: read-only filesystems over a `BlockDevice`.
- `DMGReader`: opens a `.dmg` and returns its filesystem. `dmg-inspect`: a CLI over it.
- `Extractor`: stages an app out of a `FileSystem` (4 workers, POSIX writes, xattrs, quarantine with the do-not-translocate flag) and installs it by rename or atomic swap.
- `Verifier`: signing info, strict validation, Gatekeeper assessment, the `Verdict` the panel shows, same-developer check, and stapling a DMG's ticket into an app. Use the `async` overloads from tasks; the sync ones stall under Swift concurrency.

## Commands

Homebrew's LLVM env breaks Xcode builds, so build through `scripts/swift.sh`, which clears it:

```sh
scripts/swift.sh build
scripts/swift.sh test                 # unit tests; fixtures first: scripts/fixtures-*.sh
DROP_CORPUS=1 scripts/swift.sh test   # also the 34 real DMGs in .claude/samples/
scripts/swift.sh run dmg-inspect <file.dmg> [--tree]
```

## Conventions

- **Format and lint with Apple's `swift format`** (ships with Xcode, nothing to install or pin), configured by `.swift-format`: `swift format --in-place --recursive Sources Tests Package.swift`, then `swift format lint --strict --recursive Sources Tests Package.swift`. Decided 2026-11-16 over SwiftFormat and SwiftLint.
- **Every on-disk read is bounds-checked** through `ByteReader`; a corrupt image throws `ReaderError.corrupt`, never crashes or hangs.
- **Images are untrusted input.** Tests never mount. Scripts that mount use `hdiutil attach -nobrowse -noautoopen -mountrandom` and detach by device node: `-readonly` for anything downloaded; read-write only for a fixture image the script just created itself (to add compressed, fragmented or case-only files hdiutil won't copy).
- **No package dependencies** beyond the system libraries (libz, libbz2, Compression).

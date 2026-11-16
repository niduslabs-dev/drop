# Drop

A Mac app that installs an app straight out of a `.dmg` without mounting it, and offers to when a new DMG lands in Downloads. GPL-3.0. Plan, decisions and the design canvas link live in the Nidus Labs workspace (`plans/drop.md`), not in this repo. Research, benchmarks and the sample DMGs: `.claude/` (gitignored).

## Layout

A Swift package (`Package.swift`), no Xcode project yet:

- `ReaderCore`: shared types (`BlockDevice`, `FileSystem`, `Entry`, `Extent`, `ByteReader`, `ReaderError`).
- `DiskImage`: UDIF container, decoders, partition maps.
- `HFSPlus`, `APFS`: read-only filesystems over a `BlockDevice`.
- `DMGReader`: opens a `.dmg` and returns its filesystem. `dmg-inspect`: a CLI over it.
- `Extractor`: stages an app out of a `FileSystem` (4 workers, POSIX writes, xattrs, quarantine with the do-not-translocate flag) and installs it by rename or atomic swap.
- `Mounter`: the hidden-mount fallback for images the readers can't handle (encrypted, sparse, unknown compression, decmpfs). `HiddenMount` attaches with `diskutil image attach --readOnly --nobrowse` at a 0700 folder under `$TMPDIR/dev.niduslabs.drop.mounts`, detaches by device node (`diskutil eject`, then `force`), and `sweepLeftoverMounts()` clears that folder after a crash. `MountedFileSystem` reads the volume as a `FileSystem` (POSIX, never following symlinks) so the Extractor stages from it unchanged. Measurements and licence behaviour: `.claude/research/hidden-mount.md`.
- `Verifier`: signing info, strict validation, Gatekeeper assessment, the `Verdict` the panel shows, same-developer check, and stapling a DMG's ticket into an app. Use the `async` overloads from tasks; the sync ones stall under Swift concurrency.
- `Installer`: `InstallSession`, the actor the app drives per DMG: reading → licence → (password, hidden mount) → background staging and check → ready/warning/refused → install. The hidden mount is detached as soon as the app is staged, and on cancel or failure. States in `InstallState.swift`. In Low Power Mode or at a serious thermal state it waits in `waitingToPrepare` (`StagingConditions`, injectable). Install boosts staging, its calling thread and the signature check (cancelled and reissued at user-initiated).
- `DropApp` (product `Drop`): the menu bar app, AppKit + SwiftUI. `AppDelegate` (lifecycle, launch sweeps, login item via `SMAppService.mainApp`, Open With), `DownloadsWatcher` (FSEvents on one folder; a finished `.dmg` is a regular file, no browser partial beside it, same size for `Theme.Timing.stableSize`), `InstallController` (one `InstallSession` per DMG, a queue, one panel at a time, handled files in `~/Library/Application Support/Drop/handled.json`), `PanelWindow` (non-activating `NSPanel` under the menu bar icon, or top right), `Boards.swift` (one view per design board), `StatusItemController`, `SettingsView`, `DiskImageHandler` (Open With and the "Open disk images with Drop" default; "Open disk image" always uses DiskImageMounter by name). Sizes and colours: `Theme.swift` (board numbers, system colours). `Demo.swift` is debug-only.
- `drop-impact`: the background-impact benchmark's load and staging processes, run by `.claude/research/scripts/impact_bench.py` (results in `.claude/research/impact-bench.md`).

## Commands

Homebrew's LLVM env breaks Xcode builds, so build through `scripts/swift.sh`, which clears it:

```sh
scripts/swift.sh build
scripts/swift.sh test                 # unit tests; fixtures first: scripts/fixtures-*.sh (installer and mount after verifier)
DROP_TIMING=1 scripts/swift.sh test --filter MountFallbackTimingTests   # hidden mount vs direct path
scripts/corpus.sh                     # also the 34 real DMGs in .claude/samples/ (makes and deletes 4.4 GB of reference copies)
scripts/swift.sh run dmg-inspect <file.dmg> [--tree]
scripts/build-app.sh [--debug]        # .build/Drop.app: release (or debug) build, Info.plist, ad hoc signature
```

**Running the app for tests.** Never against the real Downloads, Applications or Trash:

```sh
S=$PWD/.build/app-check/run; mkdir -p $S/watch $S/dest $S/trash
open .build/Drop.app --args --watch $S/watch --destination $S/dest --trash $S/trash   # any of these skips the login item
cp .build/fixtures/installer/one-app.dmg $S/watch/                                     # panel appears
.build/Drop.app/Contents/MacOS/Drop --demo <state> --appearance dark                   # debug build only; prints DEMO_WINDOW <id>
.claude/checks/app-demo.sh <state> <light|dark> out.png                                # screenshot one state
```

Demo states are listed in `Demo.swift`. Quit a test copy by its PID. A second launch of Drop (Finder, Spotlight) asks the running one to show Settings and exits.

## Conventions

- **Format and lint with Apple's `swift format`** (ships with Xcode, nothing to install or pin), configured by `.swift-format`: `swift format --in-place --recursive Sources Tests Package.swift`, then `swift format lint --strict --recursive Sources Tests Package.swift`. Decided 2026-11-16 over SwiftFormat and SwiftLint.
- **Every on-disk read is bounds-checked** through `ByteReader`; a corrupt image throws `ReaderError.corrupt`, never crashes or hangs.
- **Images are untrusted input.** Tests never mount, except through `HiddenMount` in `MounterTests` and the installer's mount-fallback tests: only the fixtures from `scripts/fixtures-mount.sh` (and samples in opt-in runs), read-only, under a test-only root, each checked to leave nothing attached. Scripts that mount use `hdiutil attach -nobrowse -noautoopen -mountrandom` and detach by device node: `-readonly` for anything downloaded; read-write only for a fixture image the script just created itself (to add compressed, fragmented or case-only files hdiutil won't copy).
- **No package dependencies** beyond the system libraries (libz, libbz2, Compression).

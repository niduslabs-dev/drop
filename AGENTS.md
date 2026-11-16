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
- `Onboarding`: first-launch onboarding's state machine (`OnboardingCoordinator`), with the folder access, default handler and login item behind protocols so `OnboardingTests` drive it with fakes. Rules below.
- `DropApp` (product `Drop`): the background app, AppKit + SwiftUI, with no Dock or menu bar icon. `AppDelegate` (lifecycle, launch sweeps, login item via `SMAppService.mainApp`, Open With, onboarding), `OnboardingView` (the five pages and the window, 600 × 540, one bottom-anchored rhythm in `Theme.Onboarding.Rhythm`: the art panel takes whatever height the text and buttons leave; floating while open), `WindowPresence` (the activation policy: regular while Settings, the install window or onboarding is open, accessory when the last closes, never for the popup; and how windows come forward, including `--background-test`) and `OnboardingServices` (the live requests and the test-launch stand-ins), `DownloadsWatcher` (FSEvents on one folder, 0.1 s latency, NoDefer; a rename into a `.dmg` name is finished at once, a file that appears without one waits `Theme.Timing.stableSize` at the same size; attribute-only events are ignored), `InstallController` (one `InstallSession` per DMG, a queue, one panel at a time, shown at once with "Reading…", handled files in `~/Library/Application Support/Drop/handled.json`), `PanelWindow` (the popup: a non-activating `NSPanel` at the top right of `NSScreen.main`, sliding in on our own spring; and the centred window an opened image gets, which activates Drop), `Boards.swift` (one view per design board, shared by both), `SettingsView` (pausing is the Ask switch; Quit Drop at the bottom), `DiskImageHandler` (Open With and the "Open disk images with Drop" default; "Open disk image" always uses DiskImageMounter by name). The Nidus component kit (`Components.dc.html`) is `Controls.swift` (button, switch, select, field and card styles on real controls, Tab-focusable even with macOS Keyboard navigation off); motion after Purge is `Motion.swift`; Manrope for onboarding headings and the byline is `Typeface.swift` (bundled from `Resources/Fonts`, OFL). Sizes, colours (dynamic, with Increase Contrast variants) and motion values: `Theme.swift`. `Demo.swift` is debug-only.
- `drop-impact`: the background-impact benchmark's load and staging processes, run by `.claude/research/scripts/impact_bench.py` (results in `.claude/research/impact-bench.md`).

## Commands

Homebrew's LLVM env breaks Xcode builds, so build through `scripts/swift.sh`, which clears it:

```sh
scripts/swift.sh build
scripts/swift.sh test                 # unit tests; fixtures first: scripts/fixtures-*.sh (installer and mount after verifier)
DROP_TIMING=1 scripts/swift.sh test --filter MountFallbackTimingTests   # hidden mount vs direct path
scripts/corpus.sh                     # also the 34 real DMGs in .claude/samples/ (makes and deletes 4.4 GB of reference copies)
scripts/swift.sh run dmg-inspect <file.dmg> [--tree]
scripts/build-app.sh [--debug]        # .build/Drop.app: release (or debug: `dev.niduslabs.drop.debug`, "Drop (Debug)") build, Info.plist, ad hoc signature
```

**Running the app for tests.** Never against the real Downloads, Applications or Trash, and never in the foreground: add `--background-test` (every `--demo` is one already). It never activates Drop, makes a window key or changes the activation policy; windows order in behind the user's at the normal level, Open Documents events skip AppKit's handler (which activates), and the copy ignores "show Settings" from other launches. Capture with `screencapture -l <id>` (works occluded) and drive by PID through the accessibility API (`.claude/checks/drive.swift`). Debug builds have their own bundle ID, so they never meet an installed release copy in the single-instance check, Launch Services or the "show Settings" notification (named after the bundle ID). `.claude/checks/e2e-v3.sh` runs the whole background check on a debug copy. Pure app logic (activation policy, onboarding rhythm) is tested in `DropAppTests` through `@testable import DropApp`.

```sh
S=$PWD/.build/app-check/run; mkdir -p $S/watch $S/dest $S/trash
.build/Drop.app/Contents/MacOS/Drop --background-test --watch $S/watch --destination $S/dest --trash $S/trash &   # any of these skips the login item; not `open`, which can reach another running Drop
cp .build/fixtures/installer/one-app.dmg $S/watch/                                     # panel appears
.build/Drop.app/Contents/MacOS/Drop --demo <state> --appearance dark                   # debug build only; prints DEMO_WINDOW <id>
.claude/checks/app-demo.sh <state> <light|dark> out.png                                # screenshot one state
```

Demo states are listed in `Demo.swift` (onboarding pages: `onboarding-1` … `onboarding-5`, `onboarding-2-denied`; `window` is board 1 in the centred window; `.claude/checks/onboarding-shots.sh` shoots them all). `.claude/checks/insets.sh <state>` and `.claude/checks/contrast.sh <state> <look>` measure insets and text contrast from the accessibility tree. `.claude/checks/e2e-popup.sh` runs a release test copy through the popup, install and centred window by PID; `focus-walk.swift` prints the Tab order from the accessibility tree, `onboarding-flow.swift` checks the Command-Tab policy, `popup-latency.swift` times download-to-popup. Quit a test copy by its PID. A second launch of Drop (Finder, Spotlight) asks the running one to show Settings and exits; demo and `--watch`/`--destination`/`--trash` launches are exempt, so they run beside a copy that watches the real Downloads and never poke it. `agent-desktop --app Drop` can match that other copy: target a test copy by PID or `--window-id`.

## Onboarding

Shown on first launch, before Drop touches the watched folder, the default handler or the login item; each is requested only by its page's button (Allow Downloads, Use Drop, Start at Login). State is one JSON value under `onboarding` in the preferences domain (the test domain `dev.niduslabs.drop.test` in test launches):

- **Shows at launch** until Done, or until it's closed early (Esc, close button) after Drop got access to the watched folder. Closed early without access records `reshowReason: folderAccessNotGranted` and returns next launch at the Downloads page: Drop can't work without it and never asks by itself. Closing on the last page counts as Done.
- **The watcher starts** once access is granted (the first listing succeeds) or another folder is chosen, or once onboarding is done (after Continue anyway macOS doesn't ask again).
- **"Open Drop at login" is off by default**; only Start at Login or the Settings switch turns it on. A registration failure is logged and onboarding moves on.
- Opening Drop while onboarding is open brings onboarding forward instead of Settings.
- **Test launches:** `--watch`/`--destination`/`--trash` skip onboarding so scripted panel checks see the panel at once. `--reset-onboarding` (debug) clears the test domain's state and shows it; relaunch with `--no-login-item` to see the relaunch rules. In test launches the login item and default handler are stand-ins that only log, and Allow Downloads lists the folder only when it's a `--watch` folder; without one it reports denied and never touches `~/Downloads`.

## Conventions

- **Insets are theme tokens:** `Theme.panelInset` (18, all four sides of the popup; left, right and bottom of the centred window, whose top is the title bar) and `Theme.onboardingInset` (24, left, right and bottom of onboarding). No view adds its own outer padding on top.
- **Controls come from the kit** (`Controls.swift`): `.nidusPrimary`, `.nidusSecondary`, `.nidusSmall`, `.nidusLink()`, `.nidusSwitch` (no checkboxes anywhere), `NidusSelect`, `.nidusField`, `InfoCard`/`Callout` kinds. Text colours clear 4.5:1 on rendered pixels in light and dark; measurements in `.claude/screens/app-v2/measurements.md`. Every animation reads Reduce Motion.
- **Format and lint with Apple's `swift format`** (ships with Xcode, nothing to install or pin), configured by `.swift-format`: `swift format --in-place --recursive Sources Tests Package.swift`, then `swift format lint --strict --recursive Sources Tests Package.swift`. Decided 2026-11-16 over SwiftFormat and SwiftLint.
- **Every on-disk read is bounds-checked** through `ByteReader`; a corrupt image throws `ReaderError.corrupt`, never crashes or hangs.
- **Images are untrusted input.** Tests never mount, except through `HiddenMount` in `MounterTests` and the installer's mount-fallback tests: only the fixtures from `scripts/fixtures-mount.sh` (and samples in opt-in runs), read-only, under a test-only root, each checked to leave nothing attached. Scripts that mount use `hdiutil attach -nobrowse -noautoopen -mountrandom` and detach by device node: `-readonly` for anything downloaded; read-write only for a fixture image the script just created itself (to add compressed, fragmented or case-only files hdiutil won't copy).
- **No package dependencies** beyond the system libraries (libz, libbz2, Compression).
- **The app icon comes from the assets repo** (`../assets/apps/drop/`, generated there). Refresh the committed copy with `scripts/sync-icon.sh`; never edit `Resources/AppIcon.icns` by hand.

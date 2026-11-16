# Drop: DMG Installer

Install Mac apps straight from a `.dmg`, without mounting it.

When a disk image finishes downloading, Drop shows a small panel with the app, its version and who signed it. Click Install and the app is in Applications: no mounting, no dragging, no ejecting. Drop keeps macOS's own safety checks: installed apps carry the same "downloaded from the internet" record as after a Finder drag, so Gatekeeper still checks them when they first open.

A [Nidus Labs](https://niduslabs.dev) app. *A home for little ideas.*

## Install

Download the latest `Drop-<version>.dmg` from [Releases](https://github.com/niduslabs-dev/drop/releases/latest), open it and drag Drop to Applications. Needs macOS 15 or later. Drop is signed with a Developer ID and notarized by Apple, and it updates itself.

Drop sends nothing anywhere. Its only network use is checking GitHub for its own updates, and macOS's own notarization check of the apps you install.

## How it works

- **A new download:** Drop watches your Downloads folder. When a `.dmg` finishes, a small panel slides in at the top right with the app's icon, version and signer. Click Install.
- **A double-click:** with "Open disk images with Drop" on, a `.dmg` opens in Drop's install window instead of mounting.
- **No mounting:** Drop reads the disk image itself: the UDIF container with every compression Apple's tools produce (zlib, bzip2, lzfse, lzma, ADC), GUID, Apple and MBR partition maps, and HFS+ and APFS. Images it can't read (encrypted, sparse, unusual formats) are mounted hidden and installed the same way.
- **Safety:** Drop shows who signed the app and whether Apple notarized it before you install, refuses damaged apps, compares the developer with the copy you already have, and keeps the quarantine record so Gatekeeper still checks the app on first open.
- **Out of the way:** no Dock or menu bar icon, about 17 MB of memory and no CPU while idle.

## Building

Needs Xcode 27 or later on macOS 15 or later.

```sh
scripts/swift.sh build
scripts/fixtures-diskimage.sh && scripts/fixtures-hfsplus.sh && scripts/fixtures-apfs.sh   # test images, once
scripts/swift.sh test
scripts/swift.sh run dmg-inspect path/to/App.dmg
```

`scripts/swift.sh` runs `swift` with Homebrew's LLVM build settings removed, which otherwise break Xcode's toolchain. The fixture scripts build small disk images with `hdiutil` into `.build/fixtures/`. `scripts/build-app.sh` assembles `.build/Drop.app`, signed ad hoc.

## Releases and updates

Releases are signed with Developer ID, notarized by Apple and published on [GitHub Releases](https://github.com/niduslabs-dev/drop/releases) by a workflow, never from a laptop. Drop updates itself with [Sparkle](https://sparkle-project.org): once a day it checks the latest release's `appcast.xml`, downloads in the background, verifies the EdDSA signature and installs when Drop quits, or straight away if you choose. Drop isn't sandboxed: it writes apps to Applications and reads your Downloads folder.

## Contributing

Not taking code contributions yet. Bug reports, especially disk images Drop can't read, are welcome as issues.

## Licence

[GPL-3.0](LICENSE). Copyright Nidus Labs.

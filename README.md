# Drop

Install Mac apps straight from a `.dmg`, without mounting it.

When a disk image finishes downloading, Drop shows a small panel with the app, its version and who signed it. Click Install and the app is in Applications: no mounting, no dragging, no ejecting. Drop keeps macOS's own safety checks: installed apps carry the same "downloaded from the internet" record as after a Finder drag, so Gatekeeper still checks them when they first open.

A [Nidus Labs](https://niduslabs.dev) app. *A home for little ideas.*

## Status

Early. The disk image reader is done; the app isn't built yet.

- **Done:** a Swift package that reads disk images directly: the UDIF container with every compression Apple's tools produce (zlib, bzip2, lzfse, lzma, ADC), GUID, Apple and MBR partition maps, and read-only HFS+ and APFS. It opens and reads all 34 popular app DMGs in its test set without mounting.
- **Next:** the extractor (staging the app with quarantine and its notarization ticket intact), then the app itself: the Downloads watcher and the install panel.

## Building

Needs Xcode 26 or later on macOS 15 or later.

```sh
scripts/swift.sh build
scripts/fixtures-diskimage.sh && scripts/fixtures-hfsplus.sh && scripts/fixtures-apfs.sh   # test images, once
scripts/swift.sh test
scripts/swift.sh run dmg-inspect path/to/App.dmg
```

`scripts/swift.sh` runs `swift` with Homebrew's LLVM build settings removed, which otherwise break Xcode's toolchain. The fixture scripts build small disk images with `hdiutil` into `.build/fixtures/`.

## Contributing

Not taking code contributions yet. Bug reports, especially disk images Drop can't read, are welcome as issues.

## Licence

[GPL-3.0](LICENSE). Copyright Nidus Labs.

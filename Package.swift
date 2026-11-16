// swift-tools-version:6.2
import PackageDescription

/// Drop's DMG reader: opens a disk image file without mounting it and lists and reads
/// the files inside, and the Drop app built on it (`DropApp`, assembled into `Drop.app` by
/// `scripts/build-app.sh`).
///
/// Layers, bottom up:
/// - `ReaderCore`: the shared types every layer speaks (`BlockDevice`, `FileSystem`, `Entry`, `Extent`).
/// - `DiskImage`: the UDIF container (trailer, chunk table, decoders) and partition maps.
///   Turns a `.dmg` file into a `BlockDevice` per partition.
/// - `HFSPlus`, `APFS`: read-only filesystems over any `BlockDevice`.
/// - `DMGReader`: opens a `.dmg`, finds the partition, detects the filesystem and returns it.
/// - `Extractor`: writes an app out of a `FileSystem` into a staging folder (fast parallel
///   writes, xattrs, quarantine), then moves it into place.
/// - `Verifier`: signature, Team ID and notarization of a staged app, and stapling the
///   DMG's notarization ticket into an app that has none.
/// - `Mounter`: the hidden-mount fallback for images the readers can't handle: attaches
///   read-only and invisibly at a private mount point and reads the volume as a `FileSystem`.
/// - `Installer`: the pipeline the app drives: one `InstallSession` per DMG, from reading
///   through the licence, background staging and the check to the final rename.
/// - `Onboarding`: first-launch onboarding's state machine, apart from the app so its
///   rules are tested with fake folder access, default handler and login item.
/// - `DropApp`: the background app: Downloads watcher, the install panel, Settings, and
///   updates through Sparkle (the package's one dependency) with Drop's own surfaces.
let package = Package(
    name: "Drop",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DMGReader", targets: ["DMGReader"]),
        .library(name: "Installer", targets: ["Installer"]),
        .executable(name: "dmg-inspect", targets: ["DMGInspect"]),
        .executable(name: "drop-impact", targets: ["DropImpact"]),
        .executable(name: "Drop", targets: ["DropApp"]),
    ],
    dependencies: [
        // Updates (Developer ID builds from GitHub Releases). Pinned exactly: a new Sparkle is a
        // deliberate change, checked against its changelog and the custom user driver.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "ReaderCore"),
        .target(
            name: "DiskImage",
            dependencies: ["ReaderCore"],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("compression")]
        ),
        .target(name: "HFSPlus", dependencies: ["ReaderCore"]),
        .target(name: "APFS", dependencies: ["ReaderCore"]),
        .target(name: "DMGReader", dependencies: ["ReaderCore", "DiskImage", "HFSPlus", "APFS"]),
        .target(name: "Extractor", dependencies: ["ReaderCore"]),
        .target(name: "Mounter", dependencies: ["ReaderCore"]),
        .target(
            name: "Verifier",
            dependencies: ["ReaderCore", "DiskImage"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(name: "Installer", dependencies: ["DMGReader", "DiskImage", "Extractor", "Mounter", "Verifier"]),
        .target(name: "Onboarding"),
        .executableTarget(name: "DMGInspect", dependencies: ["DMGReader", "Extractor", "Verifier"]),
        .executableTarget(name: "DropImpact", dependencies: ["Installer", "DiskImage", "Extractor"]),
        .executableTarget(
            name: "DropApp",
            dependencies: [
                "Installer", "DiskImage", "Extractor", "Mounter", "Verifier", "Onboarding",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
        .testTarget(name: "DiskImageTests", dependencies: ["DiskImage"]),
        .testTarget(name: "HFSPlusTests", dependencies: ["HFSPlus", "DiskImage"]),
        .testTarget(name: "APFSTests", dependencies: ["APFS", "DiskImage"]),
        .testTarget(name: "DMGReaderTests", dependencies: ["DMGReader"]),
        .testTarget(name: "ExtractorTests", dependencies: ["Extractor", "DMGReader"]),
        .testTarget(name: "MounterTests", dependencies: ["Mounter", "Extractor"]),
        .testTarget(name: "VerifierTests", dependencies: ["Verifier", "DMGReader", "Extractor"]),
        .testTarget(
            name: "InstallerTests",
            dependencies: ["Installer", "DMGReader", "DiskImage", "Extractor", "Mounter", "Verifier"]),
        .testTarget(name: "OnboardingTests", dependencies: ["Onboarding"]),
        // The app's pure logic (activation policy, layout rhythm), tested through
        // `@testable import` of the executable target.
        .testTarget(name: "DropAppTests", dependencies: ["DropApp"]),
    ]
)

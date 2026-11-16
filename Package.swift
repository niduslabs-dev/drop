// swift-tools-version:6.2
import PackageDescription

/// Drop's DMG reader: opens a disk image file without mounting it and lists and reads
/// the files inside. The app target comes later; this package has no UI.
///
/// Layers, bottom up:
/// - `ReaderCore`: the shared types every layer speaks (`BlockDevice`, `FileSystem`, `Entry`, `Extent`).
/// - `DiskImage`: the UDIF container (trailer, chunk table, decoders) and partition maps.
///   Turns a `.dmg` file into a `BlockDevice` per partition.
/// - `HFSPlus`, `APFS`: read-only filesystems over any `BlockDevice`.
/// - `DMGReader`: opens a `.dmg`, finds the partition, detects the filesystem and returns it.
let package = Package(
    name: "Drop",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DMGReader", targets: ["DMGReader"]),
        .executable(name: "dmg-inspect", targets: ["DMGInspect"]),
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
        .executableTarget(name: "DMGInspect", dependencies: ["DMGReader"]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
        .testTarget(name: "DiskImageTests", dependencies: ["DiskImage"]),
        .testTarget(name: "HFSPlusTests", dependencies: ["HFSPlus"]),
        .testTarget(name: "APFSTests", dependencies: ["APFS"]),
        .testTarget(name: "DMGReaderTests", dependencies: ["DMGReader"]),
    ]
)

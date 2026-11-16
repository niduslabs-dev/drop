import APFS
import DiskImage
import Foundation
import HFSPlus
@_exported import ReaderCore

/// A disk image opened without mounting: its container, where the filesystem sits, and
/// the filesystem itself.
public struct OpenedImage: Sendable {
    public let image: DiskImage
    public let location: FileSystemLocation
    public let fileSystem: any FileSystem

    /// Top-level `.app` bundles, the things Drop can install. Symlinks (such as the usual
    /// `Applications` shortcut) and hidden items are skipped.
    public func apps() throws -> [Entry] { try DMGReader.apps(in: fileSystem) }

    /// Top-level installer packages, which Drop hands to Installer instead.
    public func packages() throws -> [Entry] { try DMGReader.packages(in: fileSystem) }
}

public enum DMGReader {
    /// Opens a `.dmg` (or raw image) at `path` and its filesystem.
    ///
    /// Errors where `ReaderError.wantsMountFallback` is true mean the image is valid but
    /// Drop can't read it itself; the caller uses the hidden-mount fallback.
    public static func open(path: String) throws -> OpenedImage {
        let image = try DiskImage.open(path: path)
        let location = try image.fileSystem()
        let fileSystem: any FileSystem =
            switch location.kind {
            case .hfsPlus, .hfsx: try HFSPlusVolume(device: location.device)
            case .apfs: try APFSContainer(device: location.device).openDefaultVolume()
            }
        return OpenedImage(image: image, location: location, fileSystem: fileSystem)
    }

    /// Visits every item under `start` depth first, parents before children, with its
    /// path from the filesystem root. Stops at the first error.
    ///
    /// `compressedFile` errors from the filesystem carry only the item's name; callers
    /// that need the full path have it here.
    public static func walk(
        _ fileSystem: any FileSystem, from start: Entry? = nil, maxDepth: Int = defaultMaxDepth,
        visit: (_ path: [String], _ entry: Entry) throws -> Void
    ) throws {
        let first = try start ?? fileSystem.root
        var stack: [([String], Entry, Int)] = [([], first, 0)]
        while let (path, entry, depth) = stack.popLast() {
            if !path.isEmpty { try visit(path, entry) }
            guard entry.kind == .directory else { continue }
            guard depth < maxDepth else { throw ReaderError.corrupt("directory nesting deeper than \(maxDepth)") }
            for child in try fileSystem.children(of: entry).reversed() {
                stack.append((path + [child.name], child, depth + 1))
            }
        }
    }

    /// Top-level `.app` bundles of any filesystem (an image's, or a hidden mount's).
    /// Symlinks (such as the usual `Applications` shortcut) and hidden items are skipped.
    public static func apps(in fileSystem: any FileSystem) throws -> [Entry] {
        try fileSystem.children(of: fileSystem.root).filter {
            $0.kind == .directory && $0.name.hasSuffix(".app") && !$0.name.hasPrefix(".")
        }
    }

    /// Top-level installer packages, which Drop hands to Installer instead.
    public static func packages(in fileSystem: any FileSystem) throws -> [Entry] {
        try fileSystem.children(of: fileSystem.root).filter {
            ($0.name.hasSuffix(".pkg") || $0.name.hasSuffix(".mpkg")) && !$0.name.hasPrefix(".")
        }
    }

    /// Deeper than any real app bundle; guards against a directory loop in a damaged image.
    public static let defaultMaxDepth = 256
}

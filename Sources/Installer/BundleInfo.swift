import Foundation
import ReaderCore

/// The few `Info.plist` keys the panel shows, read either from the image (before staging,
/// so the version appears at once) or from an installed copy on disk.
struct BundleInfo: Sendable, Equatable {
    var displayName: String?
    var shortVersion: String?
    var identifier: String?
    var iconFile: String?

    /// Real `Info.plist` files are a few KB; Xcode-built ones with many URL types reach
    /// tens of KB. The cap keeps a hostile image from making Drop parse megabytes.
    static let maxPlistSize: UInt64 = 1 << 20
    static let iconExtension = "icns"

    /// Parses XML or binary plist bytes. Nil when they aren't a dictionary plist.
    init?(plist bytes: [UInt8]) {
        guard UInt64(bytes.count) <= Self.maxPlistSize,
            let object = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil),
            let dictionary = object as? [String: Any]
        else { return nil }
        func string(_ key: String) -> String? {
            (dictionary[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        displayName = string("CFBundleDisplayName") ?? string("CFBundleName")
        shortVersion = string("CFBundleShortVersionString")
        identifier = string("CFBundleIdentifier")
        iconFile = string("CFBundleIconFile")
    }

    /// Reads `<app>/Contents/Info.plist` through the image's filesystem. Nil when it is
    /// missing, too big or not a plist; the panel then falls back to the folder name.
    static func read(app: Entry, in fileSystem: any FileSystem) -> BundleInfo? {
        guard let entry = try? fileSystem.lookup([app.name, "Contents", "Info.plist"]),
            entry.kind == .file, entry.size <= maxPlistSize,
            let bytes = try? fileSystem.contents(of: entry)
        else { return nil }
        return BundleInfo(plist: bytes)
    }

    /// Reads an installed app's `Info.plist` from disk, without following a symlinked plist.
    static func read(installedApp app: URL) -> BundleInfo? {
        let path = app.appending(path: "Contents/Info.plist").path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, UInt64(info.st_size) <= maxPlistSize,
            let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return BundleInfo(plist: Array(data))
    }

    /// The largest icon read out of an image for the licence screen. Real `.icns` files are
    /// up to a few MB; the cap keeps a hostile image from making Drop hold more.
    static let maxIconSize: UInt64 = 8 << 20

    /// The candidate file names for `CFBundleIconFile`, with and without `.icns`. Nil when
    /// the name could reach outside `Contents/Resources`.
    private var iconNames: [String]? {
        guard let iconFile, !iconFile.contains("/"), iconFile != "..", iconFile != "." else { return nil }
        return iconFile.hasSuffix("." + Self.iconExtension)
            ? [iconFile] : [iconFile + "." + Self.iconExtension, iconFile]
    }

    /// Reads the app's icon bytes through the image's filesystem, for the licence screen
    /// (nothing is staged yet). Nil when there is no regular icon file within the cap.
    func iconData(app: Entry, in fileSystem: any FileSystem) -> Data? {
        for name in iconNames ?? [] {
            guard let entry = try? fileSystem.lookup([app.name, "Contents", "Resources", name]),
                entry.kind == .file, entry.size <= Self.maxIconSize,
                let bytes = try? fileSystem.contents(of: entry)
            else { continue }
            return Data(bytes)
        }
        return nil
    }

    /// The icon file inside a staged app, when `CFBundleIconFile` names a regular file in
    /// `Contents/Resources` (with or without its `.icns` extension). A name with a path
    /// separator is ignored, so the panel never loads a file outside the bundle.
    func iconURL(inStagedApp app: URL) -> URL? {
        guard let names = iconNames else { return nil }
        let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        for name in names {
            let url = resources.appending(path: name, directoryHint: .notDirectory)
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { return url }
        }
        return nil
    }
}

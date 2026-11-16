import Foundation
import Observation

/// Where installed apps go: the two choices on board 1 and in Settings.
enum InstallLocation: String, CaseIterable, Identifiable, Sendable {
    case applications
    case homeApplications

    var id: String { rawValue }

    /// The picker's label, as on the boards.
    var title: String {
        switch self {
        case .applications: "Applications"
        case .homeApplications: "Applications in your home folder"
        }
    }

    /// The short name the panel uses in "To Applications" and "in Applications".
    var shortName: String { "Applications" }

    var url: URL {
        switch self {
        case .applications:
            URL(filePath: "/Applications", directoryHint: .isDirectory)
        case .homeApplications:
            FileManager.default.homeDirectoryForCurrentUser.appending(
                path: "Applications", directoryHint: .isDirectory)
        }
    }
}

/// The Settings board, persisted in `UserDefaults`. Main actor only: the views bind to it
/// and the watcher and controller read it there.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let askOnNewImage = "askOnNewImage"
        static let watchedFolder = "watchedFolder"
        static let installLocation = "installLocation"
        static let trashImage = "trashImage"
        static let openAfterInstall = "openAfterInstall"
        static let skipFirstOpenPrompt = "skipFirstOpenPrompt"
        static let openAtLogin = "openAtLogin"
        static let keepInMenuBar = "keepInMenuBar"
        static let launchedBefore = "launchedBefore"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var askOnNewImage: Bool { didSet { defaults.set(askOnNewImage, forKey: Key.askOnNewImage) } }
    var watchedFolder: URL { didSet { defaults.set(watchedFolder.path, forKey: Key.watchedFolder) } }
    var installLocation: InstallLocation {
        didSet { defaults.set(installLocation.rawValue, forKey: Key.installLocation) }
    }
    var trashImage: Bool { didSet { defaults.set(trashImage, forKey: Key.trashImage) } }
    var openAfterInstall: Bool { didSet { defaults.set(openAfterInstall, forKey: Key.openAfterInstall) } }
    var skipFirstOpenPrompt: Bool {
        didSet { defaults.set(skipFirstOpenPrompt, forKey: Key.skipFirstOpenPrompt) }
    }
    var openAtLogin: Bool { didSet { defaults.set(openAtLogin, forKey: Key.openAtLogin) } }
    var keepInMenuBar: Bool { didSet { defaults.set(keepInMenuBar, forKey: Key.keepInMenuBar) } }

    /// "Open disk images with Drop". Not stored: it mirrors Launch Services, which the user
    /// can change in Finder, so Settings re-reads it (`DiskImageHandler.isDropDefault`).
    var opensDiskImages = false

    /// False only on the very first launch, when Drop turns the login item on by default.
    let launchedBefore: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.askOnNewImage: true, Key.trashImage: true, Key.openAfterInstall: false,
            Key.skipFirstOpenPrompt: false, Key.openAtLogin: true, Key.keepInMenuBar: false,
        ])
        askOnNewImage = defaults.bool(forKey: Key.askOnNewImage)
        let downloads =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        watchedFolder = defaults.string(forKey: Key.watchedFolder).map { URL(filePath: $0) } ?? downloads
        installLocation =
            defaults.string(forKey: Key.installLocation).flatMap(InstallLocation.init(rawValue:)) ?? .applications
        trashImage = defaults.bool(forKey: Key.trashImage)
        openAfterInstall = defaults.bool(forKey: Key.openAfterInstall)
        skipFirstOpenPrompt = defaults.bool(forKey: Key.skipFirstOpenPrompt)
        openAtLogin = defaults.bool(forKey: Key.openAtLogin)
        keepInMenuBar = defaults.bool(forKey: Key.keepInMenuBar)
        launchedBefore = defaults.bool(forKey: Key.launchedBefore)
        defaults.set(true, forKey: Key.launchedBefore)
    }
}

/// A file Drop has already dealt with (installed, Not now, or a final state). Path alone
/// isn't enough: a browser saves a newer download under the same name, which must prompt.
struct HandledFile: Codable, Hashable, Sendable {
    let path: String
    let inode: UInt64
    let size: UInt64

    /// The file's identity right now, or nil when it's gone or unreadable.
    init?(url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        path = url.path
        inode = UInt64(info.st_ino)
        size = UInt64(max(info.st_size, 0))
    }
}

/// Small JSON files in Application Support: the handled list and Recently installed.
/// Capped, so they never grow without bound.
@MainActor
final class Store {
    static let handledCap = 500
    static let recentCap = 20

    private let directory: URL
    private(set) var handled: [HandledFile]
    private(set) var recent: [RecentInstall]

    init(directory: URL = Store.defaultDirectory) {
        self.directory = directory
        handled = Self.load([HandledFile].self, from: directory.appending(path: "handled.json")) ?? []
        recent = Self.load([RecentInstall].self, from: directory.appending(path: "recent.json")) ?? []
    }

    static var defaultDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "Drop", directoryHint: .isDirectory)
    }

    func isHandled(_ file: HandledFile) -> Bool { handled.contains(file) }

    func markHandled(_ url: URL) {
        guard let file = HandledFile(url: url), !handled.contains(file) else { return }
        handled.append(file)
        if handled.count > Self.handledCap { handled.removeFirst(handled.count - Self.handledCap) }
        save(handled, to: "handled.json")
    }

    func addRecent(_ install: RecentInstall) {
        recent.removeAll { $0.path == install.path }
        recent.insert(install, at: 0)
        if recent.count > Self.recentCap { recent.removeLast(recent.count - Self.recentCap) }
        save(recent, to: "recent.json")
    }

    private func save(_ value: some Encodable, to name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appending(path: name), options: .atomic)
        } catch {
            Log.app.error("Couldn't save \(name, privacy: .public): \(error, privacy: .public)")
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// One row of Recently installed (menu) and Recent (Settings).
struct RecentInstall: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let version: String?
    let path: String
    let date: Date

    var id: String { path }
    var title: String { [name, version].compactMap(\.self).joined(separator: " ") }
}

import Foundation
import Synchronization

extension Extractor {
    /// Removes staging areas an earlier run of this app left behind on
    /// `destinationDirectory`'s volume (a crash, a quit mid-stage, a discard that never
    /// finished), on its own utility-QoS thread, then calls `completion` with how many it
    /// removed. Call it at launch; areas this process is still using are never touched.
    ///
    /// It looks in two places only, and removes only real folders owned by this user
    /// whose names match what `makeStagingArea` and `discard` create, never following a
    /// symlink:
    /// - this volume's item-replacement folder (`TemporaryItems`), inside the
    ///   `NSIRD_<process name>_*` folders FileManager made for this app, which are
    ///   removed too once empty;
    /// - `destinationDirectory` itself, for the hidden `.Drop Staging <uuid>.noindex`
    ///   fallback.
    public static func sweepLeftovers(
        near destinationDirectory: URL, completion: (@Sendable (_ removed: Int) -> Void)? = nil
    ) {
        sweepLeftovers(
            near: destinationDirectory, processName: ProcessInfo.processInfo.processName, completion: completion)
    }

    /// `processName` picks whose `NSIRD_` folders are swept; tests pass their own.
    static func sweepLeftovers(
        near destinationDirectory: URL, processName: String, completion: (@Sendable (Int) -> Void)?
    ) {
        let thread = Thread {
            let removed = sweepNow(near: destinationDirectory, processName: processName)
            completion?(removed)
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// The sweep itself, on the calling thread.
    static func sweepNow(near destinationDirectory: URL, processName: String) -> Int {
        var removed = 0
        if let temporaryItems = itemReplacementParent(for: destinationDirectory) {
            let prefix = itemReplacementPrefix + processName + "_"
            for name in listing(temporaryItems) where name.hasPrefix(prefix) {
                let folder = temporaryItems + "/" + name
                guard isOwnRealFolder(folder) else { continue }
                removed += removeLeftovers(in: folder) { isAreaName($0) }
                rmdir(folder)
            }
        }
        removed += removeLeftovers(in: destinationDirectory.path) {
            guard $0.hasPrefix(fallbackPrefix) || $0.hasPrefix(discardedPrefix + fallbackPrefix) else {
                return false
            }
            let stripped = $0.hasPrefix(discardedPrefix) ? String($0.dropFirst(discardedPrefix.count)) : $0
            return isAreaName(String(stripped.dropFirst(fallbackPrefix.count)))
        }
        return removed
    }

    /// The hidden fallback staging folder's name, before its `<uuid>.noindex`.
    static let fallbackPrefix = ".Drop Staging "
    /// How FileManager names each item-replacement folder: `NSIRD_<process>_<random>`.
    static let itemReplacementPrefix = "NSIRD_"
    static let areaSuffix = ".noindex"

    /// `<uuid>.noindex` or `.discarded-<uuid>.noindex`, exactly.
    static func isAreaName(_ name: String) -> Bool {
        let bare = name.hasPrefix(discardedPrefix) ? String(name.dropFirst(discardedPrefix.count)) : name
        guard bare.hasSuffix(areaSuffix) else { return false }
        let uuid = String(bare.dropLast(areaSuffix.count))
        return UUID(uuidString: uuid)?.uuidString == uuid
    }

    /// Removes every entry of `folder` matching `matches` that is a real folder owned by
    /// this user and not a live area. Returns how many it removed.
    private static func removeLeftovers(in folder: String, matching matches: (String) -> Bool) -> Int {
        var removed = 0
        for name in listing(folder) where matches(name) {
            let path = folder + "/" + name
            guard isOwnRealFolder(path), !LiveAreas.contains(path) else { continue }
            removeTree(path)
            if !exists(path) { removed += 1 }
        }
        return removed
    }

    /// The parent of a fresh item-replacement folder for `directory`, if it is on the
    /// same volume. Each call makes a new `NSIRD_` folder, so this one is removed at once.
    private static func itemReplacementParent(for directory: URL) -> String? {
        guard
            let fresh = try? FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
        else { return nil }
        rmdir(fresh.path)
        let parent = fresh.deletingLastPathComponent().path
        var a = stat()
        var b = stat()
        guard stat(parent, &a) == 0, stat(directory.path, &b) == 0, a.st_dev == b.st_dev else { return nil }
        return parent
    }

    private static func listing(_ folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }

    private static func isOwnRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

/// Staging areas this process made and hasn't installed or discarded yet, so a sweep
/// never deletes one in use.
enum LiveAreas {
    private static let paths = Mutex<Set<String>>([])

    static func add(_ path: String) { _ = paths.withLock { $0.insert(path) } }
    static func remove(_ path: String) { _ = paths.withLock { $0.remove(path) } }
    static func contains(_ path: String) -> Bool { paths.withLock { $0.contains(path) } }
}

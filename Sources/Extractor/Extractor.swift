import Dispatch
import Foundation
import ReaderCore

/// How `Extractor.stage` runs.
public struct StageOptions: Sendable {
    public enum Priority: Sendable {
        /// The user clicked Install and is waiting.
        case userInitiated
        /// Staging while the popup shows: file-writing threads at background QoS, which
        /// also throttles their disk I/O, so it never slows what the user is doing.
        /// `stage` leaves the calling thread's QoS alone (it does only folders, symlinks and
        /// the final pass); call it from a background-QoS thread too.
        case background
    }

    /// The DMG file's raw `com.apple.quarantine` value (`Quarantine.read(at:)`), or nil
    /// to write no quarantine at all. Staged items get it with `0x0100` added.
    public var quarantine: String?
    /// File-writing threads. 4 was fastest in `write-bench.md`; 8 and 11 were slower.
    public var workerCount: Int
    public var priority: Priority
    /// Bytes read and written per call, one buffer per worker.
    public var bufferSize: Int
    /// Checked between buffers and between items; true stops staging with
    /// `ExtractorError.cancelled` and discards what was written. Must be cheap.
    public var isCancelled: @Sendable () -> Bool
    /// The handle the app calls `boost()` on when the user clicks Install, so a
    /// `.background` stage finishes at user-initiated priority. Keep a reference to it.
    public var job: StagingJob
    /// Runs once when `job` is boosted while this stage runs (or at its start, if the job
    /// was boosted before), on the thread that called `boost()`. Wire it to whatever else
    /// should speed up with the workers, such as the image device's decode policy
    /// (more decode threads, no throttling). Must return quickly; never called after
    /// `stage` returns.
    public var onBoost: (@Sendable () -> Void)?

    public init(
        quarantine: String? = nil, workerCount: Int = Extractor.defaultWorkerCount,
        priority: Priority = .userInitiated, bufferSize: Int = defaultStreamBufferSize,
        isCancelled: @escaping @Sendable () -> Bool = { false }, job: StagingJob = StagingJob(),
        onBoost: (@Sendable () -> Void)? = nil
    ) {
        self.quarantine = quarantine
        self.workerCount = workerCount
        self.priority = priority
        self.bufferSize = bufferSize
        self.job = job
        self.onBoost = onBoost
        self.isCancelled = isCancelled
    }
}

/// Bytes of file data written so far, against the app's total. Reported from worker
/// threads, often (after every buffer); the callee should coalesce before touching UI.
public struct StageProgress: Sendable, Equatable {
    public let bytesDone: UInt64
    public let bytesTotal: UInt64
}

/// A private folder on the destination's volume that `stage` writes into, so installing
/// is a rename, never a copy.
///
/// Layout: `<parent>/<uuid>.noindex/Name.app`. `<parent>` is FileManager's
/// `.itemReplacementDirectory` for the destination (on the boot volume, under the user's
/// temporary items; on another volume, that volume's `.TemporaryItems`). FileManager makes
/// a new `NSIRD_<process>_<random>` folder there on every call, so each area has its own,
/// removed again on install and discard. `.noindex` keeps Spotlight away from the
/// half-written tree. `Extractor.sweepLeftovers` cleans up after a crash.
public struct StagingArea: Sendable, Hashable {
    public let url: URL
}

/// An app written into a staging area, ready for `install` or `discard`.
public struct StagedApp: Sendable, Hashable {
    public let url: URL
    public let area: StagingArea
    public var name: String { url.lastPathComponent }
}

/// Writes an app out of a `FileSystem` into a staging folder, then moves it into place.
///
/// The write path is the measured one from `write-bench.md`: directories first, then
/// symlinks, then files on `defaultWorkerCount` threads, each created with its final mode
/// relative to the staging folder's descriptor, written in large blocks, xattrs set on
/// the descriptor, no `fsync`.
public enum Extractor {
    public static let defaultWorkerCount = 4

    /// Makes a fresh staging area on `destinationDirectory`'s volume.
    ///
    /// Throws `ExtractorError.destinationNotWritable` when the destination is missing,
    /// not a folder or not writable, before any work is done.
    public static func makeStagingArea(for destinationDirectory: URL) throws -> StagingArea {
        try checkWritable(destinationDirectory)
        let destinationDevice = try deviceID(of: destinationDirectory.path)
        let name = UUID().uuidString + ".noindex"
        var url: URL
        if let parent = try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destinationDirectory, create: true),
            (try? deviceID(of: parent.path)) == destinationDevice
        {
            url = parent.appendingPathComponent(name, isDirectory: true)
        } else {
            // On the destination's volume by definition. Hidden, and gone after install.
            url = destinationDirectory.appendingPathComponent(fallbackPrefix + name, isDirectory: true)
        }
        guard mkdir(url.path, Writer.directoryCreateMode) == 0 else {
            let error = errno
            removeItemReplacementFolder(around: url)
            throw ExtractorError.io(errno: error, operation: "mkdir", path: url.path)
        }
        LiveAreas.add(url.path)
        return StagingArea(url: url)
    }

    /// Writes `app` (a top-level `.app` folder of `fileSystem`) into `area`.
    ///
    /// Everything is checked before anything is written: an unsafe name or kind throws
    /// `ReaderError.corrupt`, a decmpfs file throws `ReaderError.compressedFile` with
    /// its path (from the app's name down), so the hidden-mount fallback starts from an
    /// empty area, and names the staging volume can't keep apart (such as `README` and
    /// `readme` from a case-sensitive image on a case-insensitive volume) throw
    /// `ExtractorError.nameCollision`. On any error, including cancellation, the area is discarded.
    ///
    /// Files are owned by the current user, with setuid, setgid and sticky bits dropped.
    /// Xattrs are copied except quarantine (Drop writes its own), provenance, MACL,
    /// rootless, decmpfs and `com.apple.system.*`.
    public static func stage(
        app: Entry, from fileSystem: any FileSystem, into area: StagingArea, options: StageOptions = StageOptions(),
        progress: (@Sendable (StageProgress) -> Void)? = nil
    ) throws -> StagedApp {
        do {
            let quarantine = try options.quarantine.map(Quarantine.staged(from:))
            let rules = NameRules.ofVolume(at: area.url.path)
            let plan = try StagePlan.make(app: app, from: fileSystem, rules: rules)
            let rootFD = open(area.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw ExtractorError.io(errno: errno, operation: "open", path: area.url.path) }
            defer { close(rootFD) }
            let writer = Writer(
                fileSystem: fileSystem, rootFD: rootFD, quarantine: quarantine, options: options,
                totalBytes: plan.totalBytes, progress: progress)
            try writer.write(plan)
            return StagedApp(url: area.url.appendingPathComponent(app.name, isDirectory: true), area: area)
        } catch {
            discard(area)
            throw error
        }
    }

    /// Adds the "user approved" flag (`0x0040`) to every quarantined item of a staged app,
    /// so it opens without the first-launch prompt. Call only after the Verifier confirms
    /// a notarized Developer ID app, and only when the user's setting is on.
    public static func markApproved(_ staged: StagedApp) throws {
        try forEachItem(under: staged.url.path) { path in
            guard let current = try Quarantine.read(at: URL(fileURLWithPath: path)) else { return }
            let approved = try Quarantine.adding(Quarantine.userApprovedFlag, to: current)
            try withOwnerWrite(path) {
                let bytes = Array(approved.utf8)
                let result = bytes.withUnsafeBytes {
                    setxattr(path, Quarantine.attributeName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                }
                guard result == 0 else { throw ExtractorError.io(errno: errno, operation: "setxattr", path: path) }
            }
        }
    }

    /// Moves a staged app into `destinationDirectory` and returns its final URL.
    ///
    /// When an item of the same name is there, the two are swapped in one step
    /// (`RENAME_SWAP`), so the app is never missing, and the old copy goes to `trash`
    /// (the app passes `FileManager.trashItem`). Otherwise it is an exclusive rename.
    /// Never copies: a staging area on another volume fails with `EXDEV`.
    public static func install(
        _ staged: StagedApp, into destinationDirectory: URL, trash: (URL) throws -> Void
    ) throws -> URL {
        try checkWritable(destinationDirectory)
        let target = destinationDirectory.appendingPathComponent(staged.name, isDirectory: true)
        if renamex_np(staged.url.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else {
                throw ExtractorError.io(errno: errno, operation: "rename", path: target.path)
            }
            guard renamex_np(staged.url.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                throw ExtractorError.io(errno: errno, operation: "rename swap", path: target.path)
            }
            do {
                try trash(staged.url)
            } catch {
                throw ExtractorError.trashFailed(oldCopy: staged.url.path, reason: "\(error)")
            }
        }
        rmdir(staged.area.url.path)
        LiveAreas.remove(staged.area.url.path)
        removeItemReplacementFolder(around: staged.area.url)
        return target
    }

    /// Discards a staging area: renames it aside at once, so its name is free and nothing
    /// half-written stays visible, then deletes it on its own utility-QoS thread (deleting GIMP's
    /// 12k files takes about a second; a GCD global queue block didn't run for tens of
    /// seconds while the test runner's threads were busy). `completion` runs after the delete.
    public static func discard(_ area: StagingArea, completion: (@Sendable () -> Void)? = nil) {
        let aside = area.url.deletingLastPathComponent()
            .appendingPathComponent(discardedPrefix + area.url.lastPathComponent, isDirectory: true)
        let target = rename(area.url.path, aside.path) == 0 ? aside : area.url
        LiveAreas.remove(area.url.path)
        let thread = Thread {
            removeTree(target.path)
            removeItemReplacementFolder(around: target)
            completion?()
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// What a discarded area is renamed to, next to where it was, while it's
    /// being deleted.
    public static let discardedPrefix = ".discarded-"

    public static func discard(_ staged: StagedApp, completion: (@Sendable () -> Void)? = nil) {
        discard(staged.area, completion: completion)
    }

    // MARK: - Helpers

    /// Removes the `NSIRD_` folder FileManager made for an area, once it is empty.
    private static func removeItemReplacementFolder(around area: URL) {
        let parent = area.deletingLastPathComponent()
        guard parent.lastPathComponent.hasPrefix(itemReplacementPrefix) else { return }
        rmdir(parent.path)
    }

    private static func checkWritable(_ directory: URL) throws {
        var info = stat()
        guard stat(directory.path, &info) == 0 else {
            throw ExtractorError.destinationNotWritable(path: directory.path, errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ExtractorError.destinationNotWritable(path: directory.path, errno: ENOTDIR)
        }
        guard access(directory.path, W_OK | X_OK) == 0 else {
            throw ExtractorError.destinationNotWritable(path: directory.path, errno: errno)
        }
    }

    private static func deviceID(of path: String) throws -> dev_t {
        var info = stat()
        guard stat(path, &info) == 0 else { throw ExtractorError.io(errno: errno, operation: "stat", path: path) }
        return info.st_dev
    }

    /// Calls `body` with every path under and including `root`, parents first, never
    /// following symlinks.
    private static func forEachItem(under root: String, _ body: (String) throws -> Void) throws {
        try body(root)
        var info = stat()
        guard lstat(root, &info) == 0 else { throw ExtractorError.io(errno: errno, operation: "lstat", path: root) }
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            throw ExtractorError.io(errno: EACCES, operation: "list", path: root)
        }
        for name in names { try forEachItem(under: root + "/" + name, body) }
    }

    /// Runs `body` with the owner write bit set on `path`, then restores its mode. Setting
    /// an xattr needs write permission, and staged apps keep their read-only items.
    private static func withOwnerWrite(_ path: String, _ body: () throws -> Void) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ExtractorError.io(errno: errno, operation: "lstat", path: path) }
        let mode = info.st_mode & mode_t(Writer.permissionMask)
        let writable = mode & mode_t(Writer.ownerWrite) != 0
        if !writable { fchmodat(AT_FDCWD, path, mode | mode_t(Writer.ownerWrite), AT_SYMLINK_NOFOLLOW) }
        defer { if !writable { fchmodat(AT_FDCWD, path, mode, AT_SYMLINK_NOFOLLOW) } }
        try body()
    }

    /// Deletes a tree even when it holds folders without owner write or search
    /// permission (apps ship read-only folders): fixes those, then retries.
    static func removeTree(_ path: String) {
        if (try? FileManager.default.removeItem(atPath: path)) != nil { return }
        makeOwnerWritable(path)
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func makeOwnerWritable(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        chmod(path, (info.st_mode & mode_t(Writer.permissionMask)) | S_IRWXU)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            makeOwnerWritable(path + "/" + name)
        }
    }
}

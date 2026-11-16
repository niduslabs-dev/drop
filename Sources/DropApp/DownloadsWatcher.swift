import CoreServices
import Foundation

/// Watches one folder with FSEvents and reports each finished `.dmg` that lands directly
/// in it. No polling: Drop does nothing until the folder changes.
///
/// "Finished" means a regular file (Safari's `.download` bundle is a folder) whose name ends
/// in `.dmg`, not empty, with no browser partial beside it (Firefox creates an empty `X.dmg`
/// next to `X.dmg.part` when a download starts). How long Drop waits depends on how the file
/// got its name:
///
/// - **Renamed into a `.dmg` name** (Chrome, Firefox and Edge rename `.crdownload`, `.part`
///   or `.opdownload` at the end; Safari moves the file out of its `.download` bundle): the
///   writer has finished, so one quick check and it's reported at once. If the partial is
///   still there (Safari deletes its bundle just after the move), the partial disappearing
///   triggers the check.
/// - **Appeared without a rename** (a Finder copy, `curl -o`): it must keep the same size for
///   `Theme.Timing.stableSize`. Events that only change attributes (the quarantine and
///   where-from a browser writes after its rename) never restart that wait.
///
/// Repeated events for one file collapse into one report; the caller dedupes files it has
/// already handled.
@MainActor
final class DownloadsWatcher {
    /// Suffixes browsers give a download while it's in progress.
    static let partialSuffixes = [".crdownload", ".part", ".download", ".opdownload"]

    let folder: URL
    private let onFinished: @MainActor (URL) -> Void
    private var stream: FSEventStreamRef?
    /// Stable-size waits, by path, with the size they started from.
    private var checks: [String: (size: UInt64?, task: Task<Void, Never>)] = [:]
    /// The file each path was last reported as, so one download isn't reported twice.
    private var reported: [String: HandledFile] = [:]

    init(folder: URL, onFinished: @escaping @MainActor (URL) -> Void) {
        self.folder = folder.standardizedFileURL
        self.onFinished = onFinished
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        // File-level events, delivered as soon as the first one arrives (NoDefer) and then
        // coalesced over `Theme.Timing.eventLatency`.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DownloadsWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let events = (0..<count).compactMap { index in
                (array[index] as? String).map { Event(path: $0, flags: eventFlags[index]) }
            }
            MainActor.assumeIsolated { watcher.received(events) }
        }
        guard
            let created = FSEventStreamCreate(
                nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Theme.Timing.eventLatency, flags)
        else {
            Log.watcher.error("Couldn't watch \(self.folder.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
        Log.watcher.info("Watching \(self.folder.path, privacy: .public)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        for check in checks.values { check.task.cancel() }
        checks.removeAll()
    }

    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags

        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }

        /// Attribute-only changes: a quarantine or where-from xattr, or metadata.
        var isAttributesOnly: Bool {
            let content = [
                kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemModified,
                kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemRemoved,
            ]
            return !content.contains(where: has)
        }
    }

    private func received(_ events: [Event]) {
        for event in events {
            let url = URL(filePath: event.path).standardizedFileURL
            guard url.deletingLastPathComponent().path == folder.path else { continue }
            let name = url.lastPathComponent
            if let base = Self.finishedName(forPartial: name) {
                // A partial went away (renamed into place, or Safari's bundle deleted):
                // its `.dmg` may be done now.
                let dmg = folder.appending(path: base)
                if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: dmg.path) {
                    Log.watcher.info("event seen \(base, privacy: .public) (partial gone)")
                    checkNow(dmg)
                }
                continue
            }
            guard Self.isCandidateName(name) else { continue }
            Log.watcher.info(
                "event seen \(name, privacy: .public) flags 0x\(String(event.flags, radix: 16), privacy: .public)")
            if event.has(kFSEventStreamEventFlagItemRenamed), Self.regularFileSize(url) != nil {
                checkNow(url)
            } else if event.isAttributesOnly {
                continue
            } else {
                scheduleCheck(url)
            }
        }
    }

    /// The `.dmg` name a browser partial will become ("X.dmg.crdownload" → "X.dmg").
    static func finishedName(forPartial name: String) -> String? {
        for suffix in partialSuffixes where name.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            return isCandidateName(base) ? base : nil
        }
        return nil
    }

    /// A `.dmg` name, not hidden. Partials (`X.dmg.part`) don't end in `.dmg`.
    static func isCandidateName(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.lowercased().hasSuffix(".dmg")
    }

    /// A finished rename: report it now if it passes the quick check.
    private func checkNow(_ url: URL) {
        checks.removeValue(forKey: url.path)?.task.cancel()
        report(url)
    }

    /// A file that appeared without a rename: report it once its size holds still. A new
    /// event with the size unchanged keeps the wait already running instead of restarting it.
    private func scheduleCheck(_ url: URL) {
        let size = Self.regularFileSize(url)
        if let pending = checks[url.path], pending.size == size { return }
        checks[url.path]?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: Theme.Timing.stableSize)
            guard !Task.isCancelled, let self else { return }
            self.checks[url.path] = nil
            if Self.regularFileSize(url) == size {
                self.report(url)
            } else {
                self.scheduleCheck(url)
            }
        }
        checks[url.path] = (size, task)
    }

    /// The quick check: a regular, non-empty file with no partial beside it, not reported
    /// already as this same file.
    private func report(_ url: URL) {
        guard let size = Self.regularFileSize(url), size > 0, let file = HandledFile(url: url) else { return }
        let hasPartial = Self.partialSuffixes.contains {
            FileManager.default.fileExists(atPath: url.path + $0)
        }
        guard !hasPartial, reported[url.path] != file else { return }
        reported[url.path] = file
        Log.watcher.info("accepted \(url.lastPathComponent, privacy: .public)")
        onFinished(url)
    }

    /// The size of a regular file, never following a symlink; nil for anything else.
    static func regularFileSize(_ url: URL) -> UInt64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return UInt64(max(info.st_size, 0))
    }
}

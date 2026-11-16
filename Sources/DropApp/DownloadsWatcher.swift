import CoreServices
import Foundation

/// Watches one folder with FSEvents and reports each finished `.dmg` that lands directly
/// in it. No polling: Drop does nothing until the folder changes.
///
/// "Finished" means: a regular file (Safari's `.download` bundle is a folder) whose name
/// ends in `.dmg`, with no browser partial beside it (Firefox creates an empty `X.dmg`
/// next to `X.dmg.part` when a download starts), not empty, and the same size
/// `Theme.Timing.stableSize` after its last change. Browsers that download under another
/// name (`.crdownload`, `.part`, `.download`, `.opdownload`) rename it at the end, which
/// is an event for the `.dmg` like any other. Repeated events for one file collapse into
/// one check; the caller dedupes files it has already handled.
@MainActor
final class DownloadsWatcher {
    /// Suffixes browsers give a download while it's in progress.
    static let partialSuffixes = [".crdownload", ".part", ".download", ".opdownload"]

    let folder: URL
    private let onFinished: @MainActor (URL) -> Void
    private var stream: FSEventStreamRef?
    private var checks: [String: Task<Void, Never>] = [:]

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
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DownloadsWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let list = (0..<count).compactMap { array[$0] as? String }
            MainActor.assumeIsolated { watcher.received(list) }
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
        for check in checks.values { check.cancel() }
        checks.removeAll()
    }

    private func received(_ paths: [String]) {
        for path in paths {
            let url = URL(filePath: path).standardizedFileURL
            guard Self.isCandidateName(url.lastPathComponent),
                url.deletingLastPathComponent().path == folder.path
            else { continue }
            scheduleCheck(url)
        }
    }

    /// A `.dmg` name, not hidden. Partials (`X.dmg.part`) don't end in `.dmg`.
    static func isCandidateName(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.lowercased().hasSuffix(".dmg")
    }

    private func scheduleCheck(_ url: URL) {
        checks[url.path]?.cancel()
        let size = Self.regularFileSize(url)
        checks[url.path] = Task { [weak self] in
            try? await Task.sleep(for: Theme.Timing.stableSize)
            guard !Task.isCancelled, let self else { return }
            self.checks[url.path] = nil
            self.check(url, sizeBefore: size)
        }
    }

    private func check(_ url: URL, sizeBefore: UInt64?) {
        guard let size = Self.regularFileSize(url), size > 0 else { return }
        guard size == sizeBefore else {
            scheduleCheck(url)
            return
        }
        let hasPartial = Self.partialSuffixes.contains {
            FileManager.default.fileExists(atPath: url.path + $0)
        }
        guard !hasPartial else { return }
        onFinished(url)
    }

    /// The size of a regular file, never following a symlink; nil for anything else.
    static func regularFileSize(_ url: URL) -> UInt64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return UInt64(max(info.st_size, 0))
    }
}

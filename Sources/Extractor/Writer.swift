import Dispatch
import Foundation
import ReaderCore
import Synchronization

/// Writes a `StagePlan` under an open staging folder, relative to its descriptor.
///
/// Safety rests on two things: every path is opened with `O_NOFOLLOW_ANY` (or through a
/// parent opened that way), so no symlink in the tree, ours or planted, is ever
/// followed; and every item is created exclusively (`mkdirat`, `symlinkat`,
/// `O_CREAT | O_EXCL`), so a duplicate name in a hostile image fails instead of
/// overwriting.
final class Writer: Sendable {
    let fileSystem: any FileSystem
    let rootFD: Int32
    let quarantine: String?
    let options: StageOptions
    let progress: (@Sendable (StageProgress) -> Void)?
    let totalBytes: UInt64

    private let nextFile = Atomic<Int>(0)
    private let bytesDone = Atomic<UInt64>(0)
    private let failure = Mutex<(any Error)?>(nil)
    /// Paces background writes; nil when unpaced or not a background stage.
    private let pacer: WritePacer?

    /// Only the permission bits a staged item may keep: setuid, setgid and sticky are dropped.
    static let permissionMask: UInt16 = 0o777
    /// Files and folders are created with this owner bit so xattrs and contents can be
    /// written; the final mode is applied last.
    static let ownerWrite: UInt16 = 0o200
    static let directoryCreateMode: mode_t = 0o700

    /// Attributes the reader reports that Drop never copies: quarantine is rewritten,
    /// the rest are machine-local bookkeeping that the kernel owns or that would carry
    /// another Mac's state (provenance, MACL, SIP).
    static let skippedXattrs: Set<String> = [
        Quarantine.attributeName, "com.apple.provenance", "com.apple.macl", "com.apple.rootless",
        "com.apple.decmpfs",
    ]
    static let skippedXattrPrefix = "com.apple.system."
    /// Longest single sleep while pacing, so a boost or cancel mid-sleep takes effect soon.
    static let pacingSliceSeconds = 0.02
    static let nanosecondsPerSecond = 1e9
    /// Worker buffers are page-aligned: uncached (`F_NOCACHE`) writes from an aligned
    /// buffer go straight to the device instead of through a bounce copy.
    static let bufferAlignment = Int(sysconf(Int32(_SC_PAGESIZE)))

    init(
        fileSystem: any FileSystem, rootFD: Int32, quarantine: String?, options: StageOptions,
        totalBytes: UInt64, progress: (@Sendable (StageProgress) -> Void)?
    ) {
        self.fileSystem = fileSystem
        self.rootFD = rootFD
        self.quarantine = quarantine
        self.options = options
        self.totalBytes = totalBytes
        self.progress = progress
        if options.priority == .background, let rate = options.backgroundWriteRate {
            // One buffer per worker of burst: enough to absorb a late wake-up without
            // letting a burst after an idle spell exceed what the workers hold anyway.
            pacer = WritePacer(bytesPerSecond: rate, burstBytes: options.bufferSize * max(1, options.workerCount))
        } else {
            pacer = nil
        }
    }

    func write(_ plan: StagePlan) throws {
        options.job.attach(options.onBoost)
        defer { options.job.detach() }
        // The calling thread does the folders, symlinks and final pass, which for apps with
        // thousands of folders (GIMP) is most of the time after a boost. It switches QoS
        // like a worker does, then gets its own QoS back.
        let callerQoS = qos_class_self()
        var priority = WorkerPriority(job: options.job, background: isBackground)
        defer { pthread_set_qos_class_self_np(callerQoS, 0) }

        for item in plan.directories {
            try between(&priority)
            try call("mkdirat", item.path) { mkdirat(rootFD, $0, Self.directoryCreateMode) }
            let fd = try openItem(item.path, flags: O_RDONLY | O_DIRECTORY)
            defer { close(fd) }
            try applyXattrs(of: item, to: fd)
        }
        for (item, target) in plan.symlinks {
            try between(&priority)
            try writeSymlink(item, target: target)
        }
        try writeFilesInParallel(plan.files)
        for link in plan.links {
            try between(&priority)
            let result = link.existing.withCString { existing in
                link.new.withCString { linkat(rootFD, existing, rootFD, $0, 0) }
            }
            guard result == 0 else { throw ExtractorError.io(errno: errno, operation: "linkat", path: link.new) }
        }
        // Deepest first: a folder's own times and read-only mode go on after everything
        // inside it is written, or the writes would fail or bump its mtime.
        for item in plan.directories.sorted(by: { $0.depth > $1.depth }) {
            priority.update()
            let fd = try openItem(item.path, flags: O_RDONLY | O_DIRECTORY)
            defer { close(fd) }
            try finish(item, fd: fd)
        }
        report()
    }

    // MARK: - Items

    private func writeSymlink(_ item: PlannedItem, target: String) throws {
        let (parent, name) = Self.split(item.path)
        let parentFD = try openItem(parent, flags: O_RDONLY | O_DIRECTORY)
        defer { close(parentFD) }
        let created = target.withCString { target in name.withCString { symlinkat(target, parentFD, $0) } }
        guard created == 0 else { throw ExtractorError.io(errno: errno, operation: "symlinkat", path: item.path) }
        let fd = name.withCString { openat(parentFD, $0, O_RDONLY | O_SYMLINK | O_NOFOLLOW_ANY | O_CLOEXEC) }
        guard fd >= 0 else { throw ExtractorError.io(errno: errno, operation: "open symlink", path: item.path) }
        defer { close(fd) }
        try applyXattrs(of: item, to: fd)
        try finish(item, fd: fd)
    }

    private func writeFilesInParallel(_ files: [PlannedItem]) throws {
        guard !files.isEmpty else { return }
        let workers = max(1, min(options.workerCount, files.count))
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            let thread = Thread { [self] in
                defer { group.leave() }
                runWorker(files)
            }
            thread.start()
        }
        group.wait()
        if let error = failure.withLock({ $0 }) { throw error }
    }

    private func runWorker(_ files: [PlannedItem]) {
        var priority = WorkerPriority(job: options.job, background: isBackground)
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: options.bufferSize, alignment: Self.bufferAlignment)
        defer { buffer.deallocate() }
        while failure.withLock({ $0 == nil }) {
            let index = nextFile.add(1, ordering: .relaxed).oldValue
            guard index < files.count else { return }
            do {
                try writeFile(files[index], buffer: buffer, priority: &priority)
            } catch {
                failure.withLock { if $0 == nil { $0 = error } }
                return
            }
        }
    }

    private func writeFile(
        _ item: PlannedItem, buffer: UnsafeMutableRawBufferPointer, priority: inout WorkerPriority
    ) throws {
        try between(&priority)
        let entry = item.entry
        let mode = entry.mode & Self.permissionMask
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC
        let fd = item.path.withCString { openat(rootFD, $0, flags, mode_t(mode | Self.ownerWrite)) }
        guard fd >= 0 else { throw ExtractorError.io(errno: errno, operation: "create", path: item.path) }
        defer { close(fd) }
        var uncached = false
        if !priority.isFast, options.uncachedBackgroundWrites {
            uncached = fcntl(fd, F_NOCACHE, 1) == 0
            options.noCacheHook?(item.path, uncached)
        }

        var written: UInt64 = 0
        var position: UInt64 = 0
        for extent in try fileSystem.extents(of: entry).sorted(by: { $0.fileOffset < $1.fileOffset }) {
            guard extent.fileOffset < entry.size else { break }
            let (rawEnd, overflow) = extent.fileOffset.addingReportingOverflow(extent.length)
            guard !overflow else { throw ReaderError.corrupt("extent of \(item.path) overflows") }
            let end = min(rawEnd, entry.size)
            defer { position = max(position, end) }
            // Holes are left unwritten; the final `ftruncate` makes them zeros and keeps
            // the copy sparse.
            guard !extent.isHole else { continue }
            var offset = max(extent.fileOffset, position)
            while offset < end {
                // Per buffer, not only per file: one big file (Docker's are hundreds of
                // MB) shouldn't stay throttled after Install.
                priority.update()
                if uncached, priority.isFast {
                    uncached = !(fcntl(fd, F_NOCACHE, 0) == 0)
                    options.noCacheHook?(item.path, uncached)
                }
                try checkCancelled()
                let count = Int(min(UInt64(buffer.count), end - offset))
                if !priority.isFast, let pacer { try pace(count, with: pacer, priority: &priority) }
                let window = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count])
                try fileSystem.device.read(at: extent.deviceOffset + (offset - extent.fileOffset), into: window)
                try writeAll(fd, UnsafeRawBufferPointer(window), at: offset, path: item.path)
                offset += UInt64(count)
                written += UInt64(count)
                addProgress(UInt64(count))
            }
        }
        guard ftruncate(fd, off_t(entry.size)) == 0 else {
            throw ExtractorError.io(errno: errno, operation: "ftruncate", path: item.path)
        }
        addProgress(entry.size - min(written, entry.size))
        try applyXattrs(of: item, to: fd)
        try finish(item, fd: fd)
    }

    private func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, at offset: UInt64, path: String) throws {
        guard let base = bytes.baseAddress else { return }
        var done = 0
        while done < bytes.count {
            let n = pwrite(fd, base + done, bytes.count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw ExtractorError.io(errno: errno, operation: "write", path: path)
            }
            done += n
        }
    }

    /// The source's xattrs (minus `skippedXattrs`) and then Drop's quarantine.
    private func applyXattrs(of item: PlannedItem, to fd: Int32) throws {
        for (name, value) in try fileSystem.xattrs(of: item.entry) where Self.copies(name) {
            guard !name.utf8.contains(0) else { throw ReaderError.corrupt("xattr name with NUL on \(item.path)") }
            let bytes = try materialize(value, name: name, path: item.path)
            try setXattr(fd, name, bytes, path: item.path)
        }
        if let quarantine {
            try setXattr(fd, Quarantine.attributeName, Array(quarantine.utf8), path: item.path)
        }
    }

    static func copies(_ name: String) -> Bool {
        !skippedXattrs.contains(name) && !name.hasPrefix(skippedXattrPrefix) && !name.isEmpty
    }

    private func setXattr(_ fd: Int32, _ name: String, _ bytes: [UInt8], path: String) throws {
        let result = bytes.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }
        guard result == 0 else { throw ExtractorError.io(errno: errno, operation: "setxattr \(name)", path: path) }
    }

    private func materialize(_ value: XattrValue, name: String, path: String) throws -> [UInt8] {
        switch value {
        case .inline(let bytes):
            return bytes
        case .extents(let extents, let size):
            guard size <= maxInMemoryContents else {
                throw ReaderError.corrupt("xattr \(name) on \(path) is \(size) bytes")
            }
            var out = [UInt8](repeating: 0, count: Int(size))
            for extent in extents where !extent.isHole && extent.fileOffset < size {
                let length = Int(min(extent.length, size - extent.fileOffset))
                let start = Int(extent.fileOffset)
                try out.withUnsafeMutableBytes { all in
                    let window = UnsafeMutableRawBufferPointer(rebasing: all[start..<start + length])
                    try fileSystem.device.read(at: extent.deviceOffset, into: window)
                }
            }
            return out
        }
    }

    /// Final mode, then times: setting a mode or xattr doesn't touch mtime, but writing
    /// does, so this is always the last thing done to an item.
    ///
    /// The creation and modification times go on in one `fsetattrlist`: set apart, an
    /// mtime older than the creation time can pull the creation time back with it (HFS+
    /// does that for `utimes`), and source trees often have exactly that.
    private func finish(_ item: PlannedItem, fd: Int32) throws {
        let mode = item.entry.mode & Self.permissionMask
        guard fchmod(fd, mode_t(mode)) == 0 else {
            throw ExtractorError.io(errno: errno, operation: "chmod", path: item.path)
        }
        let modified = item.entry.modificationTime
        guard let created = item.entry.creationTime else {
            guard let modified else { return }
            let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), Self.posixTime(modified)]
            guard futimens(fd, times) == 0 else {
                throw ExtractorError.io(errno: errno, operation: "futimens", path: item.path)
            }
            return
        }
        try Self.setTimes(fd, created: created, modified: modified, path: item.path)
    }

    /// Sets `ATTR_CMN_CRTIME`, and `ATTR_CMN_MODTIME` when given, in one call. The
    /// attribute buffer holds the values in bitmap order: creation, then modification.
    static func setTimes(_ fd: Int32, created: Entry.Timestamp, modified: Entry.Timestamp?, path: String) throws {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | (modified == nil ? 0 : attrgroup_t(ATTR_CMN_MODTIME))
        var values = [posixTime(created)]
        if let modified { values.append(posixTime(modified)) }
        let result = values.withUnsafeMutableBytes {
            fsetattrlist(fd, &list, $0.baseAddress, $0.count, 0)
        }
        guard result == 0 else { throw ExtractorError.io(errno: errno, operation: "setattrlist", path: path) }
    }

    private static func posixTime(_ time: Entry.Timestamp) -> timespec {
        timespec(tv_sec: Int(time.seconds), tv_nsec: Int(time.nanoseconds))
    }

    // MARK: - Helpers

    /// Opens an item under the staging folder, refusing a symlink anywhere in `path`.
    private func openItem(_ path: String, flags: Int32) throws -> Int32 {
        let fd = path.withCString { openat(rootFD, $0, flags | O_NOFOLLOW_ANY | O_CLOEXEC) }
        guard fd >= 0 else { throw ExtractorError.io(errno: errno, operation: "open", path: path) }
        return fd
    }

    private func call(_ operation: String, _ path: String, _ body: (UnsafePointer<CChar>) -> Int32) throws {
        guard path.withCString(body) == 0 else {
            throw ExtractorError.io(errno: errno, operation: operation, path: path)
        }
    }

    static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return (".", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    /// Between two items: switch QoS if boosted, hold while paused, stop if cancelled.
    private func between(_ priority: inout WorkerPriority) throws {
        priority.update()
        if options.job.isPaused { options.job.waitWhilePaused(isCancelled: options.isCancelled) }
        priority.update()
        try checkCancelled()
    }

    /// Sleeps off `bytes` worth of the pacer's rate, in short slices so a boost or cancel
    /// cuts the wait short.
    ///
    /// Sleeps to a deadline on the clock rather than adding up slices: background-QoS
    /// timers get coalesced and wake late, and counting nominal slices let that lateness
    /// pile up (a 200 MB/s pace measured about 120 MB/s).
    private func pace(_ bytes: Int, with pacer: WritePacer, priority: inout WorkerPriority) throws {
        let wait = pacer.reserve(bytes)
        guard wait > 0 else { return }
        let deadline = WritePacer.now() &+ UInt64(wait * Self.nanosecondsPerSecond)
        while true {
            let now = WritePacer.now()
            guard now < deadline else { return }
            Thread.sleep(
                forTimeInterval: min(Double(deadline - now) / Self.nanosecondsPerSecond, Self.pacingSliceSeconds))
            priority.update()
            if priority.isFast { return }
            try checkCancelled()
        }
    }

    private func checkCancelled() throws {
        if options.isCancelled() { throw ExtractorError.cancelled }
    }

    private func addProgress(_ bytes: UInt64) {
        guard bytes > 0 else { return }
        let done = bytesDone.add(bytes, ordering: .relaxed).newValue
        progress?(StageProgress(bytesDone: done, bytesTotal: totalBytes))
    }

    private func report() {
        progress?(StageProgress(bytesDone: bytesDone.load(ordering: .relaxed), bytesTotal: totalBytes))
    }

    private var isBackground: Bool { options.priority == .background }
}

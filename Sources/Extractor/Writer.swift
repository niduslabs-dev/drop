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
    }

    func write(_ plan: StagePlan) throws {
        let previousPolicy = applyIOPolicy()
        defer { restoreIOPolicy(previousPolicy) }

        for item in plan.directories {
            try checkCancelled()
            try call("mkdirat", item.path) { mkdirat(rootFD, $0, Self.directoryCreateMode) }
            let fd = try openItem(item.path, flags: O_RDONLY | O_DIRECTORY)
            defer { close(fd) }
            try applyXattrs(of: item, to: fd)
        }
        for (item, target) in plan.symlinks {
            try checkCancelled()
            try writeSymlink(item, target: target)
        }
        try writeFilesInParallel(plan.files)
        for link in plan.links {
            try checkCancelled()
            let result = link.existing.withCString { existing in
                link.new.withCString { linkat(rootFD, existing, rootFD, $0, 0) }
            }
            guard result == 0 else { throw ExtractorError.io(errno: errno, operation: "linkat", path: link.new) }
        }
        // Deepest first: a folder's own times and read-only mode go on after everything
        // inside it is written, or the writes would fail or bump its mtime.
        for item in plan.directories.sorted(by: { $0.depth > $1.depth }) {
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
            thread.qualityOfService = options.priority == .background ? .background : .userInitiated
            thread.start()
        }
        group.wait()
        if let error = failure.withLock({ $0 }) { throw error }
    }

    private func runWorker(_ files: [PlannedItem]) {
        _ = applyIOPolicy()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: options.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while failure.withLock({ $0 == nil }) {
            let index = nextFile.add(1, ordering: .relaxed).oldValue
            guard index < files.count else { return }
            do {
                try writeFile(files[index], buffer: buffer)
            } catch {
                failure.withLock { if $0 == nil { $0 = error } }
                return
            }
        }
    }

    private func writeFile(_ item: PlannedItem, buffer: UnsafeMutableRawBufferPointer) throws {
        try checkCancelled()
        let entry = item.entry
        let mode = entry.mode & Self.permissionMask
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC
        let fd = item.path.withCString { openat(rootFD, $0, flags, mode_t(mode | Self.ownerWrite)) }
        guard fd >= 0 else { throw ExtractorError.io(errno: errno, operation: "create", path: item.path) }
        defer { close(fd) }

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
                try checkCancelled()
                let count = Int(min(UInt64(buffer.count), end - offset))
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
    private func finish(_ item: PlannedItem, fd: Int32) throws {
        let mode = item.entry.mode & Self.permissionMask
        guard fchmod(fd, mode_t(mode)) == 0 else {
            throw ExtractorError.io(errno: errno, operation: "chmod", path: item.path)
        }
        guard let time = item.entry.modificationTime else { return }
        let times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(time.seconds), tv_nsec: Int(time.nanoseconds)),
        ]
        guard futimens(fd, times) == 0 else {
            throw ExtractorError.io(errno: errno, operation: "futimens", path: item.path)
        }
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

    /// Throttles this thread's disk I/O in background mode, so staging while the popup
    /// shows never slows what the user is doing. Returns the policy to restore.
    private func applyIOPolicy() -> Int32? {
        guard options.priority == .background else { return nil }
        let previous = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        return previous
    }

    private func restoreIOPolicy(_ previous: Int32?) {
        guard let previous, previous >= 0 else { return }
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, previous)
    }
}

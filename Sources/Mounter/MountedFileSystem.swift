import Foundation
import ReaderCore
import Synchronization

/// A mounted volume seen through the same `FileSystem` interface as the image readers, so
/// the hidden-mount fallback stages through the unchanged Extractor (quarantine, xattrs,
/// times, name checks).
///
/// Everything goes through POSIX calls relative to a descriptor for the mount point, with
/// `O_NOFOLLOW_ANY` on every open and `AT_SYMLINK_NOFOLLOW` on every stat, so a symlink in
/// the image is reported as one and never followed out of the volume.
///
/// Bytes come from the kernel, not from a device: `extents(of:)` reports one run covering
/// the file (its `deviceOffset` means nothing) and `readData` reads the file itself.
/// Transparently compressed (decmpfs) files read back decompressed, so they are reported
/// as ordinary files and staged uncompressed; `com.apple.decmpfs` is never listed.
///
/// `Entry.id` is the item's inode number. Paths are learned as `children(of:)` lists them,
/// so an entry is only usable after its parent was listed from this instance.
public final class MountedFileSystem: FileSystem {
    public let kind = "Mounted"
    public let volumeName: String
    /// No device: nothing reads this filesystem by offset. Reading it throws.
    public let device: any BlockDevice = NoDevice()
    public let mountPoint: URL

    private let rootFD: Int32
    private let rootEntry: Entry
    /// Inode number to the path relative to the mount point ("" for the root).
    private let paths = Mutex<[UInt64: String]>([:])

    /// Attributes never reported: the kernel's compression header (it already hides it on
    /// most volumes; a decompressed copy must not carry it).
    static let hiddenXattrs: Set<String> = ["com.apple.decmpfs"]

    public init(mountPoint: URL, volumeName: String) throws {
        let fd = open(mountPoint.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ReaderError.io(errno: errno, context: "open \(mountPoint.path)") }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw ReaderError.io(errno: code, context: "fstat \(mountPoint.path)")
        }
        self.rootFD = fd
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.rootEntry = Self.entry(info, name: volumeName)
        paths.withLock { $0[rootEntry.id] = "" }
    }

    deinit { close(rootFD) }

    public var root: Entry { rootEntry }

    public func children(of directory: Entry) throws -> [Entry] {
        guard directory.kind == .directory else { throw ReaderError.notADirectory }
        let path = try self.path(of: directory)
        let fd = try openRelative(path, flags: O_RDONLY | O_DIRECTORY)
        guard let dir = fdopendir(fd) else {
            let code = errno
            close(fd)
            throw ReaderError.io(errno: code, context: "fdopendir \(path)")
        }
        defer { closedir(dir) }
        let dirFD = dirfd(dir)
        var found: [(String, Entry)] = []
        while let item = readdir(dir) {
            let name = try Self.name(of: item)
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(dirFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ReaderError.io(errno: errno, context: "fstatat \(path)/\(name)")
            }
            let childPath = path.isEmpty ? name : path + "/" + name
            found.append((childPath, Self.entry(info, name: name)))
        }
        paths.withLock { map in
            for (childPath, entry) in found where map[entry.id] == nil { map[entry.id] = childPath }
        }
        return found.map(\.1).sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    public func extents(of file: Entry) throws -> [Extent] {
        guard file.kind == .file else { throw ReaderError.corrupt("\(file.name) is not a file") }
        return file.size == 0 ? [] : [Extent(fileOffset: 0, deviceOffset: 0, length: file.size)]
    }

    public func readData(
        of file: Entry, in extent: Extent, at fileOffset: UInt64, into buffer: UnsafeMutableRawBufferPointer
    ) throws {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        let path = try self.path(of: file)
        let fd = try openRelative(path, flags: O_RDONLY)
        defer { close(fd) }
        try Self.checkSameItem(fd, file, path: path)
        var done = 0
        while done < buffer.count {
            let n = pread(fd, base + done, buffer.count - done, off_t(fileOffset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw ReaderError.io(errno: errno, context: "pread \(path)")
            }
            guard n > 0 else { throw ReaderError.corrupt("\(path) is shorter than its reported size") }
            done += n
        }
    }

    public func symlinkTarget(of link: Entry) throws -> String {
        guard link.kind == .symlink else { throw ReaderError.notASymlink }
        let path = try self.path(of: link)
        let (parent, name) = Self.split(path)
        let parentFD = try openRelative(parent, flags: O_RDONLY | O_DIRECTORY)
        defer { close(parentFD) }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(parentFD, name, &buffer, buffer.count - 1)
        guard count >= 0 else { throw ReaderError.io(errno: errno, context: "readlinkat \(path)") }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func xattrs(of entry: Entry) throws -> [String: XattrValue] {
        let path = try self.path(of: entry)
        let flags =
            switch entry.kind {
            case .symlink: O_RDONLY | O_SYMLINK
            case .directory: O_RDONLY | O_DIRECTORY
            case .file, .other: O_RDONLY
            }
        let fd = try openRelative(path, flags: flags)
        defer { close(fd) }
        let listSize = flistxattr(fd, nil, 0, 0)
        guard listSize >= 0 else { throw ReaderError.io(errno: errno, context: "flistxattr \(path)") }
        guard listSize > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: listSize)
        let got = flistxattr(fd, &names, names.count, 0)
        guard got >= 0 else { throw ReaderError.io(errno: errno, context: "flistxattr \(path)") }
        var result: [String: XattrValue] = [:]
        for raw in names[0..<got].split(separator: 0) {
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !Self.hiddenXattrs.contains(name) else { continue }
            let size = fgetxattr(fd, name, nil, 0, 0, 0)
            guard size >= 0 else { throw ReaderError.io(errno: errno, context: "fgetxattr \(name) on \(path)") }
            guard UInt64(size) <= maxInMemoryContents else {
                throw ReaderError.corrupt("xattr \(name) on \(path) is \(size) bytes")
            }
            var value = [UInt8](repeating: 0, count: size)
            let read = value.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, size, 0, 0) }
            guard read >= 0 else { throw ReaderError.io(errno: errno, context: "fgetxattr \(name) on \(path)") }
            result[name] = .inline(Array(value[0..<read]))
        }
        return result
    }

    // MARK: - Helpers

    private func path(of entry: Entry) throws -> String {
        guard let path = paths.withLock({ $0[entry.id] }) else {
            throw ReaderError.corrupt("\(entry.name) was not listed from this volume")
        }
        return path
    }

    /// Opens `path` under the mount point, refusing a symlink anywhere along it.
    private func openRelative(_ path: String, flags: Int32) throws -> Int32 {
        let fd = (path.isEmpty ? "." : path).withCString { openat(rootFD, $0, flags | O_NOFOLLOW_ANY | O_CLOEXEC) }
        guard fd >= 0 else { throw ReaderError.io(errno: errno, context: "open \(path)") }
        return fd
    }

    /// The file opened is still the one listed: a read-only mount shouldn't change, but
    /// reading another file's bytes under this name must never go unnoticed.
    private static func checkSameItem(_ fd: Int32, _ entry: Entry, path: String) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReaderError.io(errno: errno, context: "fstat \(path)") }
        guard UInt64(info.st_ino) == entry.id, UInt64(info.st_size) == entry.size else {
            throw ReaderError.corrupt("\(path) changed while it was read")
        }
    }

    static func entry(_ info: stat, name: String) -> Entry {
        let kind: Entry.Kind =
            switch info.st_mode & S_IFMT {
            case S_IFDIR: .directory
            case S_IFREG: .file
            case S_IFLNK: .symlink
            default: .other
            }
        return Entry(
            id: UInt64(info.st_ino), name: name, kind: kind, mode: UInt16(info.st_mode & 0o7777),
            size: kind == .file ? UInt64(info.st_size) : 0, isCompressed: false,
            isHardLink: kind == .file && info.st_nlink > 1,
            modificationTime: timestamp(info.st_mtimespec), creationTime: timestamp(info.st_birthtimespec))
    }

    private static func timestamp(_ time: timespec) -> Entry.Timestamp {
        Entry.Timestamp(seconds: Int64(time.tv_sec), nanoseconds: UInt32(clamping: time.tv_nsec))
    }

    private static func name(of item: UnsafeMutablePointer<dirent>) throws -> String {
        let length = Int(item.pointee.d_namlen)
        let bytes = withUnsafeBytes(of: item.pointee.d_name) { Array($0.prefix(length)) }
        guard let name = String(validating: bytes, as: UTF8.self) else {
            throw ReaderError.corrupt("a name on the mounted volume is not UTF-8")
        }
        return name
    }

    static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }
}

/// The `device` of a filesystem that has none. Every read is out of bounds.
struct NoDevice: BlockDevice {
    var size: UInt64 { 0 }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        throw ReaderError.outOfBounds
    }
}

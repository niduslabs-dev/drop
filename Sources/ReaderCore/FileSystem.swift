/// One item in a filesystem tree, as a read-only filesystem reports it.
public struct Entry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file
        case symlink
        /// Devices, sockets, FIFOs: never part of an app bundle; the extractor refuses them.
        case other
    }

    /// The filesystem's own ID for the item (HFS+ catalog node ID, APFS object ID).
    public let id: UInt64
    /// The name within its parent directory, as UTF-8 (HFS+ names are decoded from UTF-16).
    public let name: String
    public let kind: Kind
    /// POSIX permission bits only (`0o7777`); the file type lives in `kind`.
    public let mode: UInt16
    /// Logical size in bytes of the data fork (0 for directories).
    public let size: UInt64
    /// The item uses transparent compression (decmpfs, `UF_COMPRESSED`). The extractor
    /// sends such images to the hidden-mount fallback instead of writing empty files.
    public let isCompressed: Bool
    /// More than one directory entry points at this file (HFS+ hard link, APFS link count > 1).
    public let isHardLink: Bool
    /// When the item's contents last changed, as the filesystem stores it (HFS+ has whole
    /// seconds only). Nil when the filesystem doesn't record one; the extractor then leaves
    /// the time it was written.
    public let modificationTime: Timestamp?
    /// When the item was created (HFS+ `createDate`, APFS `create_time`). Nil when the
    /// filesystem doesn't record one; the extractor then leaves the time it was written.
    public let creationTime: Timestamp?

    /// A point in time as seconds and nanoseconds since 1970-01-01 UTC, the shape
    /// `futimens` takes, so no precision is lost through a `Double`.
    public struct Timestamp: Sendable, Hashable {
        public let seconds: Int64
        /// `0..<1_000_000_000`.
        public let nanoseconds: UInt32

        public init(seconds: Int64, nanoseconds: UInt32 = 0) {
            self.seconds = seconds
            self.nanoseconds = nanoseconds
        }
    }

    public init(
        id: UInt64, name: String, kind: Kind, mode: UInt16, size: UInt64,
        isCompressed: Bool = false, isHardLink: Bool = false, modificationTime: Timestamp? = nil,
        creationTime: Timestamp? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.mode = mode
        self.size = size
        self.isCompressed = isCompressed
        self.isHardLink = isHardLink
        self.modificationTime = modificationTime
        self.creationTime = creationTime
    }
}

/// A contiguous run of a file's bytes on the device.
public struct Extent: Sendable, Hashable {
    /// Byte offset within the file.
    public let fileOffset: UInt64
    /// Byte offset on the `BlockDevice` the filesystem was opened on.
    public let deviceOffset: UInt64
    /// Length in bytes. The last extent may extend past the file's `size`; readers trim it.
    public let length: UInt64
    /// A hole: the bytes are zeros and nothing is stored (APFS sparse files).
    public let isHole: Bool

    public init(fileOffset: UInt64, deviceOffset: UInt64, length: UInt64, isHole: Bool = false) {
        self.fileOffset = fileOffset
        self.deviceOffset = deviceOffset
        self.length = length
        self.isHole = isHole
    }
}

/// An extended attribute's value: small ones come inline, large ones live in extents.
public enum XattrValue: Sendable, Hashable {
    case inline([UInt8])
    case extents([Extent], size: UInt64)
}

/// A read-only filesystem over a `BlockDevice`. Implementations must be safe to use from
/// several threads at once after `open` returns.
public protocol FileSystem: Sendable {
    /// A short label for logs and the inspector, such as "HFS+" or "APFS".
    var kind: String { get }
    /// The volume's name.
    var volumeName: String { get }
    /// The device the filesystem was opened on; extents point into it.
    var device: any BlockDevice { get }

    var root: Entry { get throws }
    /// Directory contents in on-disk order. Throws `notADirectory` for anything else.
    func children(of directory: Entry) throws -> [Entry]
    /// Where the data fork's bytes are. Empty for empty files. Throws for compressed files.
    func extents(of file: Entry) throws -> [Extent]
    /// The target path of a symlink, exactly as stored.
    func symlinkTarget(of link: Entry) throws -> String
    /// Every extended attribute of an item, by name. Excludes the filesystem's internal
    /// bookkeeping attributes; includes `com.apple.decmpfs` and resource forks
    /// (`com.apple.ResourceFork`) so callers can see them.
    func xattrs(of entry: Entry) throws -> [String: XattrValue]
    /// Fills `buffer` with `file`'s data-fork bytes starting at `fileOffset`, a range that
    /// lies inside `extent` (one of `extents(of: file)`, not a hole).
    ///
    /// Every byte the extractor and `contents(of:)` copy goes through here. The default reads
    /// `device` at the extent's device offset, which is right for any filesystem parsed from a
    /// `BlockDevice`. A filesystem with no device of its own (a mounted volume, read through
    /// the kernel) implements it directly and reports extents that only describe file ranges.
    func readData(
        of file: Entry, in extent: Extent, at fileOffset: UInt64, into buffer: UnsafeMutableRawBufferPointer
    ) throws
}

extension FileSystem {
    public func readData(
        of file: Entry, in extent: Extent, at fileOffset: UInt64, into buffer: UnsafeMutableRawBufferPointer
    ) throws {
        try device.read(at: extent.deviceOffset + (fileOffset - extent.fileOffset), into: buffer)
    }
}

/// The largest file `FileSystem.contents(of:)` reads into memory. App metadata such as
/// `Info.plist` is kilobytes; anything near this is damage or the wrong API.
public let maxInMemoryContents: UInt64 = 64 << 20

/// Default chunk for `FileSystem.read(_:bufferSize:_:)`: large enough that per-call
/// overhead vanishes, small enough to keep many files in flight at once.
public let defaultStreamBufferSize = 4 << 20

extension FileSystem {
    /// Reads a whole file into memory. For metadata files such as `Info.plist`; the
    /// extractor streams instead.
    ///
    /// Throws `corrupt` for files over `maxInMemoryContents`, so a damaged size field can't
    /// make it allocate gigabytes.
    public func contents(of file: Entry) throws -> [UInt8] {
        guard file.size <= maxInMemoryContents else {
            throw ReaderError.corrupt("\(file.name) is \(file.size) bytes, over the in-memory limit")
        }
        var out = [UInt8](repeating: 0, count: Int(file.size))
        for extent in try extents(of: file) where !extent.isHole && extent.fileOffset < file.size {
            let length = Int(min(extent.length, file.size - extent.fileOffset))
            try out.withUnsafeMutableBytes { all in
                let slice = UnsafeMutableRawBufferPointer(
                    rebasing: all[Int(extent.fileOffset)..<Int(extent.fileOffset) + length])
                try readData(of: file, in: extent, at: extent.fileOffset, into: slice)
            }
        }
        return out
    }

    /// Streams a file's bytes in order through one reused buffer, `bufferSize` at a time,
    /// with holes delivered as zeros. Any file size; this is the path bulk copies use.
    ///
    /// `body` gets the file offset and the bytes; the buffer is only valid during the call.
    public func read(
        _ file: Entry, bufferSize: Int = defaultStreamBufferSize,
        _ body: (_ fileOffset: UInt64, _ bytes: UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var position: UInt64 = 0
        for extent in try extents(of: file).sorted(by: { $0.fileOffset < $1.fileOffset }) {
            guard extent.fileOffset < file.size else { break }
            let end = min(extent.fileOffset + extent.length, file.size)
            try emitZeros(from: position, to: extent.fileOffset, buffer, body)
            var offset = max(extent.fileOffset, position)
            while offset < end {
                let count = Int(min(UInt64(bufferSize), end - offset))
                let window = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count])
                if extent.isHole {
                    window.initializeMemory(as: UInt8.self, repeating: 0)
                } else {
                    try readData(of: file, in: extent, at: offset, into: window)
                }
                try body(offset, UnsafeRawBufferPointer(window))
                offset += UInt64(count)
            }
            position = max(position, end)
        }
        try emitZeros(from: position, to: file.size, buffer, body)
    }

    private func emitZeros(
        from start: UInt64, to end: UInt64, _ buffer: UnsafeMutableRawBufferPointer,
        _ body: (UInt64, UnsafeRawBufferPointer) throws -> Void
    ) throws {
        var offset = start
        while offset < end {
            let count = Int(min(UInt64(buffer.count), end - offset))
            let window = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count])
            window.initializeMemory(as: UInt8.self, repeating: 0)
            try body(offset, UnsafeRawBufferPointer(window))
            offset += UInt64(count)
        }
    }

    /// Finds an entry by path components from the root, such as `["Linea.app", "Contents", "Info.plist"]`.
    ///
    /// Names match byte for byte (UTF-8), not by Swift `String` equality, which treats NFC
    /// and NFD spellings as equal: a case-sensitive volume can hold both as different files.
    public func lookup(_ components: [String]) throws -> Entry? {
        var current = try root
        for name in components {
            guard current.kind == .directory,
                let next = try children(of: current).first(where: { $0.name.utf8.elementsEqual(name.utf8) })
            else { return nil }
            current = next
        }
        return current
    }
}

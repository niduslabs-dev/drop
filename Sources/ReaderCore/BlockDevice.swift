import Foundation

/// Random-access, read-only bytes: a partition inside a disk image, or a raw image file.
///
/// Filesystem readers only ever see this, so they work the same over a decoded DMG
/// partition and over a plain file (handy in tests: `hdiutil convert -format UDTO`).
///
/// Implementations must be safe to call from several threads at once; the extractor
/// reads many files in parallel.
public protocol BlockDevice: Sendable {
    /// Size of the device in bytes.
    var size: UInt64 { get }

    /// Fills `buffer` with the bytes starting at `offset`.
    ///
    /// Throws `ReaderError.outOfBounds` when the range runs past `size`. A container or
    /// filesystem that hits it while following its own pointers maps it to `corrupt`:
    /// the image points outside itself, which is damage, not a caller bug.
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws
}

extension BlockDevice {
    /// Reads `count` bytes at `offset` into a new array. Fine for metadata; bulk file
    /// data should go through `read(at:into:)` with a reused buffer.
    public func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { try read(at: offset, into: $0) }
        return bytes
    }
}

/// A window onto part of another device, such as one partition of a whole disk.
public struct SliceDevice: BlockDevice {
    public let base: any BlockDevice
    public let start: UInt64
    public let size: UInt64

    /// The whole of `base`, for disks with no partition map.
    public init(whole base: any BlockDevice) {
        self.base = base
        self.start = 0
        self.size = base.size
    }

    public init(base: any BlockDevice, start: UInt64, size: UInt64) throws {
        let (end, overflow) = start.addingReportingOverflow(size)
        guard !overflow, end <= base.size else { throw ReaderError.outOfBounds }
        self.base = base
        self.start = start
        self.size = size
    }

    public func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(buffer.count))
        guard !overflow, end <= size else { throw ReaderError.outOfBounds }
        try base.read(at: start + offset, into: buffer)
    }
}

/// A plain file read with `pread`, for raw images and tests.
public final class FileDevice: BlockDevice, @unchecked Sendable {
    // `pread` is thread-safe on one descriptor, so sharing `fd` across threads is fine.
    private let fd: Int32
    public let size: UInt64

    public init(path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ReaderError.io(errno: errno, context: "open \(path)") }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw ReaderError.io(errno: code, context: "fstat \(path)")
        }
        self.fd = fd
        self.size = UInt64(info.st_size)
    }

    deinit { close(fd) }

    public func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(buffer.count))
        guard !overflow, end <= size else { throw ReaderError.outOfBounds }
        var done = 0
        while done < buffer.count {
            let n = pread(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw ReaderError.io(errno: errno, context: "pread")
            }
            guard n > 0 else { throw ReaderError.outOfBounds }
            done += n
        }
    }
}

/// Bytes held in memory. For tests and for small structures already read in full.
public struct MemoryDevice: BlockDevice {
    public var bytes: [UInt8]
    public var size: UInt64 { UInt64(bytes.count) }

    public init(bytes: [UInt8]) { self.bytes = bytes }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(buffer.count))
        guard !overflow, end <= size else { throw ReaderError.outOfBounds }
        bytes.withUnsafeBytes { all in
            buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: all[Int(offset)..<Int(end)]))
        }
    }
}

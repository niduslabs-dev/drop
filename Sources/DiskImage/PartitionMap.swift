import Foundation
import ReaderCore
import zlib

/// One partition from a partition map. Offsets are bytes on the disk the map was read from.
public struct Partition: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// GPT partition type GUID, such as `48465300-0000-11AA-AA11-00306543ECAC` (HFS+).
        case gpt(type: UUID)
        /// APM partition type string, such as `Apple_HFS`. Not trusted for detection.
        case apm(type: String)
        /// MBR partition type byte.
        case mbr(type: UInt8)
    }

    public let index: Int
    public let name: String
    public let kind: Kind
    public let start: UInt64
    public let size: UInt64
}

/// The partition scheme of a disk and its partitions.
public struct PartitionMap: Sendable, Hashable {
    public enum Scheme: Sendable, Hashable {
        case gpt
        case apm
        case mbr
        /// No map: the filesystem starts at offset 0 (`hdiutil -layout NONE`).
        case none
    }

    public let scheme: Scheme
    public let partitions: [Partition]

    /// Reads the map of `device`. Damaged GPT or APM structures throw `corrupt`; a disk
    /// with no recognised map returns `.none` with no partitions.
    public static func read(from device: any BlockDevice) throws -> PartitionMap {
        if let gpt = try GPT.read(device) { return gpt }
        if let apm = try APM.read(device) { return apm }
        if let mbr = try MBR.read(device) { return mbr }
        return PartitionMap(scheme: .none, partitions: [])
    }
}

/// A filesystem found on a disk.
public struct FileSystemLocation: Sendable {
    public enum Kind: String, Sendable, Hashable {
        case hfsPlus = "HFS+"
        case hfsx = "HFSX"
        case apfs = "APFS"
    }

    public let kind: Kind
    /// The partition that holds it; nil when the filesystem starts at offset 0 with no map.
    public let partition: Partition?
    /// The filesystem's bytes, ready for a filesystem reader.
    public let device: SliceDevice
}

extension PartitionMap {
    private static let hfsSignatureOffset: UInt64 = 1024
    private static let hfsPlusSignature: [UInt8] = Array("H+".utf8)
    private static let hfsxSignature: [UInt8] = Array("HX".utf8)
    private static let apfsSignatureOffset: UInt64 = 32
    private static let apfsSignature: [UInt8] = Array("NXSB".utf8)

    /// Which filesystem starts at `offset` on `device`, judged by its own magic only.
    /// Partition labels lie (Firefox labels HFS+ as `Apple_HFSX`), so they're never used.
    public static func probeFileSystem(on device: any BlockDevice, at offset: UInt64 = 0) throws -> FileSystemLocation
        .Kind?
    {
        let size = device.size
        if offset <= size, size - offset >= apfsSignatureOffset + UInt64(apfsSignature.count),
            try device.read(at: offset + apfsSignatureOffset, count: apfsSignature.count) == apfsSignature
        {
            return .apfs
        }
        if offset <= size, size - offset >= hfsSignatureOffset + UInt64(hfsPlusSignature.count) {
            let magic = try device.read(at: offset + hfsSignatureOffset, count: hfsPlusSignature.count)
            if magic == hfsPlusSignature { return .hfsPlus }
            if magic == hfsxSignature { return .hfsx }
        }
        return nil
    }

    /// Finds the partition holding an HFS+, HFSX or APFS filesystem: the first one in map
    /// order whose start carries the magic, or offset 0 when there is no map. Throws
    /// `unsupportedFileSystem` when nothing matches, so the app can fall back to mounting.
    public func fileSystem(on device: any BlockDevice) throws -> FileSystemLocation {
        for partition in partitions where partition.size > 0 {
            guard partition.start <= device.size, partition.size <= device.size - partition.start else { continue }
            let slice = try SliceDevice(base: device, start: partition.start, size: partition.size)
            if let kind = try Self.probeFileSystem(on: slice) {
                return FileSystemLocation(kind: kind, partition: partition, device: slice)
            }
        }
        if let kind = try Self.probeFileSystem(on: device) {
            return FileSystemLocation(
                kind: kind, partition: nil, device: try SliceDevice(base: device, start: 0, size: device.size))
        }
        throw ReaderError.unsupportedFileSystem(
            "no HFS+ or APFS filesystem found (\(scheme) map, \(partitions.count) partitions)")
    }
}

// MARK: GPT

private enum GPT {
    static let sectorSize: UInt64 = 512
    static let signature: [UInt8] = Array("EFI PART".utf8)
    static let minimumHeaderSize = 92
    static let maximumEntries = 1024
    static let maximumEntrySize = 4096
    static let entryNameLength = 72

    enum Header {
        static let headerSize = 12
        static let headerCRC = 16
        static let entriesLBA = 72
        static let entryCount = 80
        static let entrySize = 84
        static let entriesCRC = 88
    }

    enum Entry {
        static let typeGUID = 0
        static let firstLBA = 32
        static let lastLBA = 40
        static let name = 56
    }

    static func read(_ device: any BlockDevice) throws -> PartitionMap? {
        guard device.size >= sectorSize * 2 else { return nil }
        let header = try device.read(at: sectorSize, count: Int(sectorSize))
        guard Array(header[0..<signature.count]) == signature else { return nil }
        let reader = ByteReader(header)

        let headerSize = Int(try reader.le32(Header.headerSize))
        guard headerSize >= minimumHeaderSize, headerSize <= header.count else {
            throw ReaderError.corrupt("GPT header size \(headerSize)")
        }
        var zeroedCRC = Array(header[0..<headerSize])
        for i in Header.headerCRC..<Header.headerCRC + 4 { zeroedCRC[i] = 0 }
        guard crc(zeroedCRC) == (try reader.le32(Header.headerCRC)) else {
            throw ReaderError.corrupt("GPT header checksum mismatch")
        }

        let entriesLBA = try reader.le64(Header.entriesLBA)
        let count = Int(try reader.le32(Header.entryCount))
        let entrySize = Int(try reader.le32(Header.entrySize))
        guard count <= maximumEntries, entrySize >= Entry.name + entryNameLength, entrySize <= maximumEntrySize,
            entriesLBA <= device.size / sectorSize, UInt64(count * entrySize) <= device.size - entriesLBA * sectorSize
        else { throw ReaderError.corrupt("GPT entry array out of range") }

        let table = try device.read(at: entriesLBA * sectorSize, count: count * entrySize)
        guard crc(table) == (try reader.le32(Header.entriesCRC)) else {
            throw ReaderError.corrupt("GPT entries checksum mismatch")
        }
        let entries = ByteReader(table)

        var partitions: [Partition] = []
        for i in 0..<count {
            let base = i * entrySize
            let guidBytes = try entries.slice(base + Entry.typeGUID, 16)
            guard guidBytes.contains(where: { $0 != 0 }) else { continue }
            let first = try entries.le64(base + Entry.firstLBA)
            let last = try entries.le64(base + Entry.lastLBA)
            guard last >= first, last < device.size / sectorSize else {
                throw ReaderError.corrupt("GPT entry \(i) out of range")
            }
            let nameUnits = try (0..<entryNameLength / 2).map { try entries.le16(base + Entry.name + 2 * $0) }
            let name = String(decoding: nameUnits.prefix { $0 != 0 }, as: UTF16.self)
            partitions.append(
                Partition(
                    index: i, name: name, kind: .gpt(type: mixedEndianGUID(guidBytes)), start: first * sectorSize,
                    size: (last - first + 1) * sectorSize))
        }
        return PartitionMap(scheme: .gpt, partitions: partitions)
    }

    /// GPT GUIDs store their first three fields little-endian.
    static func mixedEndianGUID(_ b: [UInt8]) -> UUID {
        UUID(
            uuid: (b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        )
    }

    static func crc(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }
    }
}

// MARK: APM

private enum APM {
    static let driverDescriptorSignature: UInt16 = 0x4552  // "ER"
    static let entrySignature: UInt16 = 0x504D  // "PM"
    static let defaultBlockSize: UInt64 = 512
    static let maximumEntries: UInt32 = 256
    static let maximumBlockSize: UInt64 = 4096
    static let stringLength = 32

    enum Offset {
        static let ddmBlockSize = 2
        static let signature = 0
        static let mapEntries = 4
        static let startBlock = 8
        static let blockCount = 12
        static let name = 16
        static let type = 48
    }

    /// Entries sit one block apart and count in those blocks. hdiutil writes 512-byte maps;
    /// DiscRecording images (Chrome, Brave) declare 2048 in the driver descriptor yet carry
    /// both a 512-byte map and a 2048-byte one. The 512-byte map is tried first, since it is
    /// what macOS itself reads from a disk image, then the declared size.
    static func read(_ device: any BlockDevice) throws -> PartitionMap? {
        guard device.size >= defaultBlockSize * 2 else { return nil }
        var candidates = [defaultBlockSize]
        let ddm = ByteReader(try device.read(at: 0, count: Int(defaultBlockSize)))
        if try ddm.be16(0) == driverDescriptorSignature {
            let declared = UInt64(try ddm.be16(Offset.ddmBlockSize))
            if declared > defaultBlockSize, declared <= maximumBlockSize, declared.nonzeroBitCount == 1 {
                candidates.append(declared)
            }
        }
        for blockSize in candidates where device.size >= blockSize * 2 {
            let first = ByteReader(try device.read(at: blockSize, count: Int(defaultBlockSize)))
            if try first.be16(Offset.signature) == entrySignature {
                return try read(device, blockSize: blockSize, count: try first.be32(Offset.mapEntries))
            }
        }
        return nil
    }

    private static func read(_ device: any BlockDevice, blockSize: UInt64, count: UInt32) throws -> PartitionMap {
        guard count >= 1, count <= maximumEntries, UInt64(count + 1) * blockSize <= device.size else {
            throw ReaderError.corrupt("APM entry count \(count)")
        }
        var partitions: [Partition] = []
        for i in 0..<Int(count) {
            let entry = ByteReader(try device.read(at: UInt64(i + 1) * blockSize, count: Int(defaultBlockSize)))
            guard try entry.be16(Offset.signature) == entrySignature else {
                throw ReaderError.corrupt("APM entry \(i) signature")
            }
            let start = UInt64(try entry.be32(Offset.startBlock)) * blockSize
            let size = UInt64(try entry.be32(Offset.blockCount)) * blockSize
            // `hdiutil convert -format UDTO` drops trailing free space from APM disks, leaving an
            // `Apple_Free` entry past the end; skip such entries instead of rejecting the map.
            guard start <= device.size, size <= device.size - start else { continue }
            partitions.append(
                Partition(
                    index: i, name: try cString(entry, Offset.name), kind: .apm(type: try cString(entry, Offset.type)),
                    start: start, size: size))
        }
        return PartitionMap(scheme: .apm, partitions: partitions)
    }

    static func cString(_ reader: ByteReader, _ offset: Int) throws -> String {
        let bytes = try reader.slice(offset, stringLength)
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

// MARK: MBR

private enum MBR {
    static let sectorSize: UInt64 = 512
    static let bootSignatureOffset = 510
    static let bootSignature: UInt16 = 0x55AA
    static let tableOffset = 446
    static let entrySize = 16
    static let entryCount = 4
    static let protectiveType: UInt8 = 0xEE

    enum Entry {
        static let type = 4
        static let firstLBA = 8
        static let sectorCount = 12
    }

    /// Plain MBR only; a protective MBR (type 0xEE) without a valid GPT header is not a map.
    static func read(_ device: any BlockDevice) throws -> PartitionMap? {
        guard device.size >= sectorSize else { return nil }
        let reader = ByteReader(try device.read(at: 0, count: Int(sectorSize)))
        guard try reader.be16(bootSignatureOffset) == bootSignature else { return nil }
        var partitions: [Partition] = []
        for i in 0..<entryCount {
            let base = tableOffset + i * entrySize
            let type = try reader.u8(base + Entry.type)
            guard type != 0 else { continue }
            if type == protectiveType { return nil }
            let start = UInt64(try reader.le32(base + Entry.firstLBA)) * sectorSize
            let size = UInt64(try reader.le32(base + Entry.sectorCount)) * sectorSize
            guard start > 0, start <= device.size, size <= device.size - start else { return nil }
            partitions.append(Partition(index: i, name: "", kind: .mbr(type: type), start: start, size: size))
        }
        return partitions.isEmpty ? nil : PartitionMap(scheme: .mbr, partitions: partitions)
    }
}

import ReaderCore

/// How a chunk's bytes are stored in the `.dmg` file.
public enum ChunkType: Sendable, Hashable {
    /// Zero fill: no stored bytes.
    case zero
    /// Stored as-is.
    case raw
    /// Free space: no stored bytes, reads as zeros.
    case ignore
    /// Apple Data Compression (UDCO).
    case adc
    /// zlib stream with its 2-byte header (UDZO).
    case zlib
    /// bzip2 stream (UDBZ).
    case bzip2
    /// LZFSE `bvx` frames (ULFO).
    case lzfse
    /// xz stream (ULMO).
    case lzma

    static let zeroCode: UInt32 = 0
    static let rawCode: UInt32 = 1
    static let ignoreCode: UInt32 = 2
    static let adcCode: UInt32 = 0x8000_0004
    static let zlibCode: UInt32 = 0x8000_0005
    static let bzip2Code: UInt32 = 0x8000_0006
    static let lzfseCode: UInt32 = 0x8000_0007
    static let lzmaCode: UInt32 = 0x8000_0008
    static let commentCode: UInt32 = 0x7FFF_FFFE
    static let terminatorCode: UInt32 = 0xFFFF_FFFF

    /// Nil for entries that carry no data (comment, terminator). Throws for unknown types,
    /// which the app hands to the hidden-mount fallback.
    static func from(code: UInt32) throws -> ChunkType? {
        switch code {
        case zeroCode: .zero
        case rawCode: .raw
        case ignoreCode: .ignore
        case adcCode: .adc
        case zlibCode: .zlib
        case bzip2Code: .bzip2
        case lzfseCode: .lzfse
        case lzmaCode: .lzma
        case commentCode, terminatorCode: nil
        default: throw ReaderError.unsupportedCompression(code)
        }
    }

    /// True when the chunk reads as zeros and has nothing stored.
    public var isZeroFill: Bool { self == .zero || self == .ignore }
}

/// One run of the decoded disk and where its bytes are stored. Chunks never overlap.
public struct Chunk: Sendable, Hashable {
    /// Position in `UDIFDevice.chunks`, which is sorted by `deviceOffset`.
    public let index: Int
    public let type: ChunkType
    /// Byte offset on the decoded disk.
    public let deviceOffset: UInt64
    /// Decoded length in bytes.
    public let length: UInt64
    /// Byte offset of the stored (compressed) bytes in the `.dmg` file.
    public let fileOffset: UInt64
    /// Stored length in bytes. Zero for zero fill.
    public let fileLength: UInt64
}

/// One `blkx` entry: a `mish` table mapping a sector range to chunks. hdiutil writes one per
/// partition-map structure and partition; the names (such as `disk image (Apple_HFS : 4)`)
/// are informational and never used to decide anything.
public struct BlockTable: Sendable, Hashable {
    public let name: String
    /// First sector on the decoded disk.
    public let firstSector: UInt64
    public let sectorCount: UInt64

    static let magic: UInt32 = 0x6D69_7368  // "mish"
    private static let headerSize = 204
    private static let entrySize = 40

    private enum Offset {
        static let magic = 0
        static let firstSector = 8
        static let sectorCount = 16
        static let dataOffset = 24
        static let entryCount = 200
    }

    private enum EntryOffset {
        static let type = 0
        static let sectorNumber = 8
        static let sectorCount = 16
        static let compressedOffset = 24
        static let compressedLength = 32
    }

    /// Parses a table and returns it with its data-carrying chunks (indices unset, as 0).
    /// `dataForkOffset` and `dataForkLength` come from the trailer: stored bytes must lie
    /// inside the data fork.
    static func parse(
        _ data: [UInt8], name: String, dataForkOffset: UInt64, dataForkLength: UInt64
    ) throws -> (BlockTable, [Chunk]) {
        let reader = ByteReader(data)
        guard try reader.be32(Offset.magic) == magic else {
            throw ReaderError.corrupt("blkx \(name) is not a mish table")
        }
        let first = try reader.be64(Offset.firstSector)
        let count = try reader.be64(Offset.sectorCount)
        let dataOffset = try reader.be64(Offset.dataOffset)
        let entryCount = Int(try reader.be32(Offset.entryCount))
        guard entryCount <= (data.count - headerSize) / entrySize else {
            throw ReaderError.corrupt("blkx \(name) lists more chunks than it holds")
        }
        let (tableEnd, tableOverflow) = first.addingReportingOverflow(count)
        guard !tableOverflow, tableEnd <= UInt64.max / udifSectorSize else {
            throw ReaderError.corrupt("blkx \(name) sector range overflows")
        }

        var chunks: [Chunk] = []
        for i in 0..<entryCount {
            let base = headerSize + i * entrySize
            guard let type = try ChunkType.from(code: try reader.be32(base + EntryOffset.type)) else { continue }
            let sector = try reader.be64(base + EntryOffset.sectorNumber)
            let sectors = try reader.be64(base + EntryOffset.sectorCount)
            let stored = try reader.be64(base + EntryOffset.compressedOffset)
            let storedLength = try reader.be64(base + EntryOffset.compressedLength)
            guard sectors > 0 else { continue }

            let (end, overflow) = sector.addingReportingOverflow(sectors)
            guard !overflow, end <= count else {
                throw ReaderError.corrupt("blkx \(name) chunk \(i) runs past its table")
            }

            var fileOffset: UInt64 = 0
            var fileLength: UInt64 = 0
            if !type.isZeroFill {
                let (relative, o1) = dataOffset.addingReportingOverflow(stored)
                let (storedEnd, o2) = relative.addingReportingOverflow(storedLength)
                guard !o1, !o2, storedEnd <= dataForkLength else {
                    throw ReaderError.corrupt("blkx \(name) chunk \(i) data runs past the data fork")
                }
                fileOffset = dataForkOffset + relative
                fileLength = storedLength
                if type == .raw, storedLength != sectors * udifSectorSize {
                    throw ReaderError.corrupt("blkx \(name) raw chunk \(i) has the wrong stored length")
                }
            }
            chunks.append(
                Chunk(
                    index: 0, type: type, deviceOffset: (first + sector) * udifSectorSize,
                    length: sectors * udifSectorSize, fileOffset: fileOffset, fileLength: fileLength
                ))
        }
        return (BlockTable(name: name, firstSector: first, sectorCount: count), chunks)
    }
}

import ReaderCore

/// The size of a UDIF sector. Every offset in the trailer and block tables counts in these.
public let udifSectorSize: UInt64 = 512

/// Where the image's code signature lives in the file. Info only: Drop never checks it here
/// (the signature check runs on the extracted app and on the DMG through Security).
public struct CodeSignatureArea: Sendable, Hashable {
    /// Byte offset of the signature blob in the `.dmg` file.
    public let offset: UInt64
    /// Length in bytes.
    public let length: UInt64
}

/// The 512-byte `koly` trailer at the end of a UDIF image. Big-endian throughout.
struct UDIFTrailer: Sendable {
    static let size = 512
    static let magic: UInt32 = 0x6B6F_6C79  // "koly"

    private enum Offset {
        static let magic = 0
        static let version = 4
        static let headerSize = 8
        static let flags = 12
        static let dataForkOffset = 24
        static let dataForkLength = 32
        static let resourceForkOffset = 40
        static let resourceForkLength = 48
        static let segmentCount = 60
        static let xmlOffset = 216
        static let xmlLength = 224
        static let codeSignatureOffset = 0x128
        static let codeSignatureLength = 0x130
        static let imageVariant = 0x1E8
        static let sectorCount = 0x1EC
    }

    let version: UInt32
    let flags: UInt32
    let dataForkOffset: UInt64
    let dataForkLength: UInt64
    let resourceForkOffset: UInt64
    let resourceForkLength: UInt64
    let xmlOffset: UInt64
    let xmlLength: UInt64
    let codeSignature: CodeSignatureArea?
    let imageVariant: UInt32
    let sectorCount: UInt64

    /// Returns nil when the bytes don't start with `koly`; throws when they do but the
    /// fields are inconsistent with a file of `fileSize` bytes.
    init?(_ bytes: [UInt8], fileSize: UInt64) throws {
        let reader = ByteReader(bytes)
        guard bytes.count == Self.size, try reader.be32(Offset.magic) == Self.magic else { return nil }
        version = try reader.be32(Offset.version)
        guard try reader.be32(Offset.headerSize) == UInt32(Self.size) else {
            throw ReaderError.corrupt("koly header size is not \(Self.size)")
        }
        flags = try reader.be32(Offset.flags)
        dataForkOffset = try reader.be64(Offset.dataForkOffset)
        dataForkLength = try reader.be64(Offset.dataForkLength)
        resourceForkOffset = try reader.be64(Offset.resourceForkOffset)
        resourceForkLength = try reader.be64(Offset.resourceForkLength)
        xmlOffset = try reader.be64(Offset.xmlOffset)
        xmlLength = try reader.be64(Offset.xmlLength)
        imageVariant = try reader.be32(Offset.imageVariant)
        sectorCount = try reader.be64(Offset.sectorCount)

        if try reader.be32(Offset.segmentCount) > 1 {
            throw ReaderError.unsupportedContainer("segmented UDIF image")
        }
        let body = fileSize - UInt64(Self.size)
        for (name, offset, length) in [
            ("data fork", dataForkOffset, dataForkLength),
            ("resource fork", resourceForkOffset, resourceForkLength),
            ("XML plist", xmlOffset, xmlLength),
        ] {
            let (end, overflow) = offset.addingReportingOverflow(length)
            guard !overflow, end <= body else { throw ReaderError.corrupt("koly \(name) runs past the file") }
        }

        let signatureOffset = try reader.be64(Offset.codeSignatureOffset)
        let signatureLength = try reader.be64(Offset.codeSignatureLength)
        codeSignature = signatureLength == 0 ? nil : CodeSignatureArea(offset: signatureOffset, length: signatureLength)
    }
}

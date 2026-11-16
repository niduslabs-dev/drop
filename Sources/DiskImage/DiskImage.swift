import Foundation
import ReaderCore

/// An opened `.dmg`: the whole decoded disk plus what the container says about itself.
///
/// `open(path:)` never mounts, decodes no chunk data and reads only the trailer and plist.
/// Find the filesystem with `fileSystem()`.
public struct DiskImage: Sendable {
    public enum Container: Sendable, Hashable {
        /// A UDIF image (`koly` trailer); `device` is a `UDIFDevice`.
        case udif
        /// No trailer: the file itself is the disk (UDTO `.cdr`, UDRW, `.iso`).
        case raw
    }

    public let container: Container
    /// The whole disk, decoded. Safe to read from several threads.
    public let device: any BlockDevice
    /// Set for UDIF images, for chunk-level access and parallel decoding.
    public let udif: UDIFDevice?
    /// The licence agreement, when the image carries one. Report-only.
    public let licence: LicenceAgreement?
    /// Where the trailer says the code signature lives; nil when unsigned or raw.
    public let codeSignature: CodeSignatureArea?

    /// Biggest XML plist accepted. Real images carry well under 1 MB; the cap stops a
    /// hostile trailer from making us allocate the whole file.
    public static let maxPlistSize: UInt64 = 256 * 1024 * 1024

    private static let encryptedV2Magic: [UInt8] = Array("encrcdsa".utf8)
    private static let encryptedV1Magic: [UInt8] = Array("cdsaencr".utf8)
    private static let sparseMagic: [UInt8] = Array("sprs".utf8)
    private static let binaryPlistMagic: [UInt8] = Array("bplist".utf8)

    /// Opens a disk image.
    ///
    /// Throws `encrypted` for `encrcdsa`/`cdsaencr` images, `sparseImage` for `.sparseimage`
    /// files and sparse bundles, `unsupportedContainer` for UDIF images whose block map
    /// isn't an XML plist (old binary resource forks) or that are segmented,
    /// `unsupportedCompression` for unknown chunk types, and `corrupt` for damaged
    /// trailers, plists and block tables. A file with no `koly` trailer is opened as a raw
    /// disk; whether it holds anything useful is decided by the partition and filesystem
    /// probes.
    public static func open(path: String) throws -> DiskImage {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            if path.hasSuffix(".sparsebundle") || path.hasSuffix(".sparsebundle/") { throw ReaderError.sparseImage }
            throw ReaderError.unsupportedContainer("a directory, not a disk image")
        }
        let file = try FileDevice(path: path)
        return try open(file: file)
    }

    /// Opens a disk image already open as `file` (the `.dmg` bytes).
    public static func open(file: any BlockDevice) throws -> DiskImage {
        let size = file.size
        let head = try file.read(at: 0, count: Int(min(size, UInt64(encryptedV2Magic.count))))
        if head == encryptedV2Magic { throw ReaderError.encrypted }
        if head.starts(with: sparseMagic) { throw ReaderError.sparseImage }
        if size >= UInt64(encryptedV1Magic.count),
            try file.read(at: size - UInt64(encryptedV1Magic.count), count: encryptedV1Magic.count) == encryptedV1Magic
        {
            throw ReaderError.encrypted
        }

        guard size >= UInt64(UDIFTrailer.size),
            let trailer = try UDIFTrailer(
                try file.read(at: size - UInt64(UDIFTrailer.size), count: UDIFTrailer.size), fileSize: size)
        else {
            return DiskImage(container: .raw, device: file, udif: nil, licence: nil, codeSignature: nil)
        }

        guard trailer.xmlLength > 0 else {
            throw trailer.resourceForkLength > 0
                ? ReaderError.unsupportedContainer("block map in a binary resource fork")
                : ReaderError.corrupt("koly trailer has no block map")
        }
        guard trailer.xmlLength <= maxPlistSize else {
            throw ReaderError.corrupt("XML plist is \(trailer.xmlLength) bytes")
        }
        let plistBytes = try file.read(at: trailer.xmlOffset, count: Int(trailer.xmlLength))
        if plistBytes.starts(with: binaryPlistMagic) {
            throw ReaderError.unsupportedContainer("binary property list block map")
        }

        let resources = try parseResources(plistBytes)
        guard let blkx = resources["blkx"], !blkx.isEmpty else { throw ReaderError.corrupt("plist has no blkx tables") }

        var tables: [BlockTable] = []
        var chunks: [Chunk] = []
        for (i, entry) in blkx.enumerated() {
            guard let data = entry["Data"] as? [UInt8] else { throw ReaderError.corrupt("blkx \(i) has no Data") }
            let name = entry["Name"] as? String ?? entry["CFName"] as? String ?? "blkx \(i)"
            let (table, tableChunks) = try BlockTable.parse(
                data, name: name, dataForkOffset: trailer.dataForkOffset, dataForkLength: trailer.dataForkLength)
            tables.append(table)
            chunks += tableChunks
        }

        let chunkEnd = chunks.map { $0.deviceOffset + $0.length }.max() ?? 0
        let (trailerBytes, overflow) = trailer.sectorCount.multipliedReportingOverflow(by: udifSectorSize)
        guard !overflow else { throw ReaderError.corrupt("koly sector count overflows") }
        let device = try UDIFDevice(file: file, size: max(trailerBytes, chunkEnd), tables: tables, chunks: chunks)
        return DiskImage(
            container: .udif, device: device, udif: device, licence: try LicenceAgreement(resources: resources),
            codeSignature: trailer.codeSignature)
    }

    /// The disk's partition map.
    public func partitionMap() throws -> PartitionMap { try PartitionMap.read(from: device) }

    /// The partition holding the HFS+ or APFS filesystem, found by magic.
    public func fileSystem() throws -> FileSystemLocation { try partitionMap().fileSystem(on: device) }

    /// The plist's `resource-fork` dictionary with every `Data` value as bytes.
    private static func parseResources(_ bytes: [UInt8]) throws -> [String: [[String: Any]]] {
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
        } catch {
            throw ReaderError.corrupt("XML plist does not parse")
        }
        guard let dictionary = root as? [String: Any], let fork = dictionary["resource-fork"] as? [String: Any] else {
            throw ReaderError.corrupt("plist has no resource-fork")
        }
        var resources: [String: [[String: Any]]] = [:]
        for (type, value) in fork {
            guard let entries = value as? [[String: Any]] else { continue }
            resources[type] = entries.map { entry in
                var copy = entry
                if let data = entry["Data"] as? Data { copy["Data"] = [UInt8](data) }
                return copy
            }
        }
        return resources
    }
}

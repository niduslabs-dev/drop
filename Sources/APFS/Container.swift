import ReaderCore

/// One volume in a container, as its superblock describes it. Opening it is a separate
/// step (`APFSContainer.open(_:)`) so callers can list volumes they can't read.
public struct APFSVolumeInfo: Sendable, Hashable {
    /// Position in the container's volume array.
    public let index: Int
    public let name: String
    /// `apfs_role` bits (`0x1` system, `0x2` user, `0x40` data, ...); 0 for no role.
    public let role: UInt16
    /// The volume is encrypted (`APFS_FS_UNENCRYPTED` clear). Opening it throws `encrypted`.
    public let isEncrypted: Bool
    /// A signed system volume. Its tree is read as stored; the seal isn't verified.
    public let isSealed: Bool
    public let isCaseInsensitive: Bool
    /// Hashed directory keys: names compare after Unicode normalisation.
    public let isNormalizationInsensitive: Bool
    public let fileCount: UInt64
    public let directoryCount: UInt64
    public let symlinkCount: UInt64

    let virtualOID: UInt64
    let superblockBlock: UInt64
    let superblockXID: UInt64

    public var isSystem: Bool { role & Format.Volume.roleSystem != 0 }
}

/// A read-only APFS container over a device whose byte 0 is the container's block 0.
///
/// Opening reads the newest valid checkpoint superblock, the container object map and
/// every volume superblock, verifying the checksum of each object it reads. The result
/// is immutable and safe to share between threads.
public final class APFSContainer: Sendable {
    public let device: any BlockDevice
    public let blockSize: Int
    /// Transaction ID of the checkpoint in use.
    public let xid: UInt64
    public let volumes: [APFSVolumeInfo]

    let store: ObjectStore

    /// Cap on the checkpoint descriptor ring scan. hdiutil rings are a few hundred blocks;
    /// a corrupt count could otherwise mean billions of reads.
    static let maxDescriptorBlocks: UInt64 = 1 << 16

    public init(device: any BlockDevice) throws {
        self.device = device
        let probe = try Self.readProbe(device)
        let blockSize = Int(try probe.le32(Format.Container.blockSize))
        guard try probe.le32(Format.Container.magic) == Format.Container.magicValue else {
            throw ReaderError.unsupportedFileSystem("no APFS container superblock")
        }
        guard blockSize >= Format.Container.minBlockSize, blockSize <= Format.Container.maxBlockSize,
            blockSize & (blockSize - 1) == 0
        else {
            throw ReaderError.corrupt("APFS block size \(blockSize)")
        }
        let blockCount = try probe.le64(Format.Container.blockCount)
        let store = ObjectStore(device: device, blockSize: blockSize, blockCount: blockCount)
        let superblock = try Self.latestSuperblock(store: store)
        self.store = store
        self.blockSize = blockSize
        xid = try superblock.le64(Format.Object.xid)

        let containerMap = try ObjectMap(store: store, block: try superblock.le64(Format.Container.omapOID), xid: xid)
        let slots = min(Int(try superblock.le32(Format.Container.maxFileSystems)), Format.Container.fileSystemLimit)
        var volumes: [APFSVolumeInfo] = []
        for slot in 0..<slots {
            let oid = try superblock.le64(Format.Container.fileSystemOIDs + slot * 8)
            guard oid != 0 else { continue }
            let block = try containerMap.physicalAddress(of: oid)
            let volume = try store.readObject(
                at: block, oid: oid, types: [Format.Object.typeVolumeSuperblock], maxXID: xid)
            volumes.append(try Self.volumeInfo(volume, index: slot, oid: oid, block: block))
        }
        self.volumes = volumes
    }

    /// Opens a volume's filesystem. Throws `encrypted` for an encrypted volume.
    public func open(_ volume: APFSVolumeInfo) throws -> APFSVolume {
        try APFSVolume(container: self, info: volume)
    }

    /// The volume an app installer image means: the only non-system volume, else the
    /// first one holding files, else the first one.
    public func openDefaultVolume() throws -> APFSVolume {
        let nonSystem = volumes.filter { !$0.isSystem }
        let chosen =
            nonSystem.count == 1 ? nonSystem[0] : (volumes.first { $0.fileCount > 0 } ?? volumes.first)
        guard let chosen else { throw ReaderError.corrupt("APFS container has no volumes") }
        return try open(chosen)
    }

    private static func readProbe(_ device: any BlockDevice) throws -> ByteReader {
        guard device.size >= UInt64(Format.Container.probeSize) else {
            throw ReaderError.corrupt("device too small for an APFS container")
        }
        return ByteReader(try device.read(at: 0, count: Format.Container.probeSize))
    }

    /// The valid container superblock with the highest transaction ID: block 0 or any
    /// copy in the checkpoint descriptor ring. Copies with a bad checksum are skipped;
    /// if none is valid the container is corrupt.
    private static func latestSuperblock(store: ObjectStore) throws -> ByteReader {
        var best: ByteReader?
        var bestXID: UInt64 = 0
        func consider(_ block: UInt64) throws {
            guard let candidate = try? ByteReader(store.readBlock(block)),
                (try? candidate.le32(Format.Container.magic)) == Format.Container.magicValue,
                (try? candidate.le32(Format.Object.type)).map({ $0 & Format.Object.typeMask })
                    == Format.Object.typeContainerSuperblock,
                (try? ObjectStore.verify(candidate, at: block)) != nil,
                (try? candidate.le32(Format.Container.blockSize)) == UInt32(store.blockSize)
            else { return }
            let xid = try candidate.le64(Format.Object.xid)
            if best == nil || xid > bestXID {
                best = candidate
                bestXID = xid
            }
        }
        try consider(0)
        if let blockZero = best {
            let descriptorBlocks = try blockZero.le32(Format.Container.descriptorBlocks)
            // A B-tree descriptor area is rare (never made by hdiutil); fall back to block 0.
            if descriptorBlocks & Format.Container.descriptorTreeFlag == 0 {
                let base = try blockZero.le64(Format.Container.descriptorBase)
                let count = min(UInt64(descriptorBlocks), Self.maxDescriptorBlocks, store.blockCount)
                for offset in 0..<count {
                    let (block, overflow) = base.addingReportingOverflow(offset)
                    guard !overflow else { break }
                    try consider(block)
                }
            }
        } else {
            // Block 0 is damaged; its copy in the ring may still be fine, but we can't
            // find the ring without it, so the container is unreadable.
            throw ReaderError.corrupt("APFS container superblock checksum is bad")
        }
        guard let best else { throw ReaderError.corrupt("no valid APFS checkpoint") }
        return best
    }

    private static func volumeInfo(_ volume: ByteReader, index: Int, oid: UInt64, block: UInt64) throws
        -> APFSVolumeInfo
    {
        guard volume.bytes.count >= Format.Volume.minimumSize,
            try volume.le32(Format.Volume.magic) == Format.Volume.magicValue
        else {
            throw ReaderError.corrupt("volume \(oid) has no APSB superblock")
        }
        let incompatible = try volume.le64(Format.Volume.incompatibleFeatures)
        let flags = try volume.le64(Format.Volume.flags)
        let rawName = try volume.slice(Format.Volume.name, Format.Volume.nameLength)
        let name = String(decoding: rawName.prefix { $0 != 0 }, as: UTF8.self)
        return APFSVolumeInfo(
            index: index,
            name: name,
            role: try volume.le16(Format.Volume.role),
            isEncrypted: flags & Format.Volume.flagUnencrypted == 0,
            isSealed: incompatible & Format.Volume.incompatSealed != 0,
            isCaseInsensitive: incompatible & Format.Volume.incompatCaseInsensitive != 0,
            isNormalizationInsensitive: incompatible & Format.Volume.incompatNormalizationInsensitive != 0,
            fileCount: try volume.le64(Format.Volume.fileCount),
            directoryCount: try volume.le64(Format.Volume.directoryCount),
            symlinkCount: try volume.le64(Format.Volume.symlinkCount),
            virtualOID: oid,
            superblockBlock: block,
            superblockXID: try volume.le64(Format.Object.xid)
        )
    }
}

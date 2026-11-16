import ReaderCore

/// An inode record (`j_inode_val_t`) with the fields the reader uses.
struct Inode: Sendable {
    let id: UInt64
    let parentID: UInt64
    /// The data stream's ID: file extents are keyed by this, not by the inode ID (clones
    /// share a stream).
    let privateID: UInt64
    /// `nchildren` for directories, `nlink` for everything else.
    let linkCount: Int32
    let bsdFlags: UInt32
    let mode: UInt16
    /// `mod_time`: nanoseconds since 1970-01-01 UTC.
    let modificationTime: UInt64
    /// `create_time`: nanoseconds since 1970-01-01 UTC.
    let creationTime: UInt64
    /// Logical size from the `INO_EXT_TYPE_DSTREAM` field; 0 when there is none.
    let size: UInt64
    /// The name from `INO_EXT_TYPE_NAME` (one of the names, for a hard link).
    let name: String?

    var fileType: UInt16 { mode & Format.Mode.typeMask }
}

/// A hard link's directory entry, from a sibling-link record.
public struct APFSSiblingLink: Sendable, Hashable {
    public let parentID: UInt64
    public let name: String
}

/// A read-only APFS volume (the live filesystem, not a snapshot).
///
/// Names are returned exactly as stored (APFS keeps the bytes it was given, NFC or NFD).
/// Note that Swift `String` equality is canonical equivalence, so an NFC and an NFD
/// spelling of a name compare equal; compare `name.utf8` when the bytes matter.
///
/// Every node read is checksum-verified and cached in the container's bounded node
/// cache; the object is otherwise immutable and safe to use from several threads.
public final class APFSVolume: FileSystem, Sendable {
    public let kind = "APFS"
    public let info: APFSVolumeInfo
    public var volumeName: String { info.name }
    public var device: any BlockDevice { store.device }

    private let store: ObjectStore
    let tree: BTree
    /// Sealed volumes keep file extents in a separate tree keyed by data stream ID.
    private let extentTree: BTree?
    private let hashedNames: Bool

    /// Deeper than any real path; stops a parent cycle when building error paths.
    private static let maxPathDepth = 4096

    init(container: APFSContainer, info: APFSVolumeInfo) throws {
        guard !info.isEncrypted else { throw ReaderError.encrypted }
        store = container.store
        self.info = info
        let superblock = try store.readObject(
            at: info.superblockBlock, oid: info.virtualOID, types: [Format.Object.typeVolumeSuperblock],
            maxXID: container.xid)
        let xid = info.superblockXID
        let objectMap = try ObjectMap(store: store, block: try superblock.le64(Format.Volume.omapOID), xid: xid)
        let rootType = try superblock.le32(Format.Volume.rootTreeType)
        let addressing: NodeAddressing =
            rootType & Format.Object.storageMask == Format.Object.storagePhysical ? .physical : .virtual(objectMap)
        tree = try BTree(
            store: store, rootOID: try superblock.le64(Format.Volume.rootTreeOID), addressing: addressing, maxXID: xid)
        let extentTreeOID = try superblock.le64(Format.Volume.fileExtentTreeOID)
        if info.isSealed, extentTreeOID != 0 {
            let extentType = try superblock.le32(Format.Volume.fileExtentTreeType)
            guard extentType & Format.Object.storageMask == Format.Object.storagePhysical else {
                throw ReaderError.unsupportedFileSystem("sealed APFS volume with a virtual extent tree")
            }
            extentTree = try BTree(store: store, rootOID: extentTreeOID, addressing: .physical, maxXID: xid)
        } else {
            extentTree = nil
        }
        hashedNames = info.isCaseInsensitive || info.isNormalizationInsensitive
    }

    // MARK: FileSystem

    public var root: Entry {
        get throws { try entry(for: try inode(Format.Record.rootDirectoryID), name: "") }
    }

    public func children(of directory: Entry) throws -> [Entry] {
        guard directory.kind == .directory else { throw ReaderError.notADirectory }
        var found: [(id: UInt64, name: String)] = []
        let hashed = hashedNames
        try records(of: directory.id, type: Format.Record.typeDirectoryRecord) { data, key, value in
            guard value.count >= Format.DirectoryRecord.valueSize else {
                throw ReaderError.corrupt("short directory record in \(directory.id)")
            }
            let name = try Self.directoryName(data, key, hashed: hashed)
            let id = try data.le64(value.lowerBound + Format.DirectoryRecord.fileID)
            if id != Format.Record.privateDirectoryID { found.append((id, name)) }
            return true
        }
        return try found.map { try entry(for: try inode($0.id), name: $0.name) }
    }

    public func extents(of file: Entry) throws -> [Extent] {
        let node = try inode(file.id)
        if try isCompressed(node) { throw ReaderError.compressedFile(path: try path(of: node)) }
        return try streamExtents(streamID: node.privateID, size: node.size)
    }

    public func symlinkTarget(of link: Entry) throws -> String {
        guard link.kind == .symlink else { throw ReaderError.notASymlink }
        guard let value = try rawXattrs(of: link.id).first(where: { $0.name == Format.Xattr.symlinkName })?.value
        else {
            throw ReaderError.corrupt("symlink \(link.id) has no target")
        }
        let bytes: [UInt8]
        switch value {
        case .inline(let inline):
            bytes = inline
        case .extents(let extents, let size):
            bytes = try read(extents, size: size)
        }
        guard let target = String(validating: bytes.prefix { $0 != 0 }, as: UTF8.self) else {
            throw ReaderError.corrupt("symlink \(link.id) target is not UTF-8")
        }
        return target
    }

    public func xattrs(of entry: Entry) throws -> [String: XattrValue] {
        var result: [String: XattrValue] = [:]
        for xattr in try rawXattrs(of: entry.id)
        where !xattr.fileSystemOwned && !xattr.name.hasPrefix(Format.Xattr.internalPrefix)
            && !xattr.name.hasPrefix(Format.Xattr.systemPrefix)
        {
            result[xattr.name] = xattr.value
        }
        return result
    }

    // MARK: APFS-specific

    /// The other directory entries of a hard-linked file (empty for an ordinary file).
    public func siblingLinks(of file: Entry) throws -> [APFSSiblingLink] {
        var links: [APFSSiblingLink] = []
        try records(of: file.id, type: Format.Record.typeSiblingLink) { data, _, value in
            let base = value.lowerBound
            let parent = try data.le64(base + Format.Sibling.parentID)
            let length = Int(try data.le16(base + Format.Sibling.nameLength))
            guard base + Format.Sibling.name + length <= value.upperBound else {
                throw ReaderError.corrupt("sibling link of \(file.id) overruns its record")
            }
            links.append(
                APFSSiblingLink(parentID: parent, name: try Self.name(data.slice(base + Format.Sibling.name, length))))
            return true
        }
        return links
    }

    // MARK: Records

    /// Visits every fs-tree record of `oid` with record type `type`, in key order.
    private func records(
        of oid: UInt64, type: UInt8, _ visit: (ByteReader, Range<Int>, Range<Int>) throws -> Bool
    ) throws {
        try tree.scan(
            order: { data, key in
                guard key.count >= Format.Record.headerSize else { throw ReaderError.corrupt("short fs-tree key") }
                let header = try data.le64(key.lowerBound)
                let keyOID = header & Format.Record.oidMask
                let keyType = UInt8(header >> Format.Record.typeShift)
                if keyOID != oid { return keyOID < oid ? .before : .after }
                if keyType != type { return keyType < type ? .before : .after }
                return .inside
            },
            visit: visit)
    }

    func inode(_ id: UInt64) throws -> Inode {
        var found: Inode?
        try records(of: id, type: Format.Record.typeInode) { data, _, value in
            found = try Self.parseInode(id: id, data, value)
            return false
        }
        guard let found else { throw ReaderError.corrupt("inode \(id) not found") }
        return found
    }

    private static func parseInode(id: UInt64, _ data: ByteReader, _ value: Range<Int>) throws -> Inode {
        let base = value.lowerBound
        guard value.count >= Format.Inode.extendedFields else { throw ReaderError.corrupt("short inode \(id)") }
        var size: UInt64 = 0
        var name: String?
        if value.count >= Format.Inode.extendedFields + Format.Inode.xfieldHeaderSize {
            let blob = base + Format.Inode.extendedFields
            let fieldCount = Int(try data.le16(blob))
            var dataOffset = blob + Format.Inode.xfieldHeaderSize + fieldCount * Format.Inode.xfieldHeaderSize
            for field in 0..<fieldCount {
                let header = blob + Format.Inode.xfieldHeaderSize + field * Format.Inode.xfieldHeaderSize
                let type = try data.u8(header)
                let length = Int(try data.le16(header + 2))
                guard dataOffset + length <= value.upperBound else {
                    throw ReaderError.corrupt("inode \(id) extended field overruns its record")
                }
                switch type {
                case Format.Inode.xfieldTypeDataStream:
                    guard length >= Format.DataStream.structSize else {
                        throw ReaderError.corrupt("inode \(id) has a short data stream")
                    }
                    size = try data.le64(dataOffset + Format.DataStream.size)
                case Format.Inode.xfieldTypeName:
                    name = try Self.name(data.slice(dataOffset, length))
                default:
                    break
                }
                let alignment = Format.Inode.xfieldAlignment
                dataOffset += (length + alignment - 1) / alignment * alignment
            }
        }
        return Inode(
            id: id,
            parentID: try data.le64(base + Format.Inode.parentID),
            privateID: try data.le64(base + Format.Inode.privateID),
            linkCount: Int32(bitPattern: try data.le32(base + Format.Inode.linkCount)),
            bsdFlags: try data.le32(base + Format.Inode.bsdFlags),
            mode: try data.le16(base + Format.Inode.mode),
            modificationTime: try data.le64(base + Format.Inode.modificationTime),
            creationTime: try data.le64(base + Format.Inode.creationTime),
            size: size,
            name: name)
    }

    private func entry(for inode: Inode, name: String) throws -> Entry {
        let kind: Entry.Kind
        switch inode.fileType {
        case Format.Mode.directory: kind = .directory
        case Format.Mode.regular: kind = .file
        case Format.Mode.symlink: kind = .symlink
        default: kind = .other
        }
        return Entry(
            id: inode.id,
            name: name,
            kind: kind,
            mode: inode.mode & Format.Mode.permissionMask,
            size: kind == .directory ? 0 : inode.size,
            isCompressed: kind == .file ? try isCompressed(inode) : false,
            isHardLink: kind == .file && inode.linkCount > 1,
            modificationTime: Self.timestamp(inode.modificationTime),
            creationTime: Self.timestamp(inode.creationTime))
    }

    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    private static func timestamp(_ nanoseconds: UInt64) -> Entry.Timestamp {
        Entry.Timestamp(
            seconds: Int64(nanoseconds / nanosecondsPerSecond),
            nanoseconds: UInt32(nanoseconds % nanosecondsPerSecond))
    }

    private func isCompressed(_ inode: Inode) throws -> Bool {
        if inode.bsdFlags & Format.Inode.compressedFlag != 0 { return true }
        return try rawXattrs(of: inode.id).contains { $0.name == Format.Xattr.decmpfsName }
    }

    /// Decodes a NUL-terminated on-disk name. APFS requires UTF-8, so anything else is corrupt.
    private static func name(_ bytes: [UInt8]) throws -> String {
        let trimmed = bytes.last == 0 ? bytes.dropLast() : bytes[...]
        guard let name = String(validating: trimmed, as: UTF8.self) else {
            throw ReaderError.corrupt("name is not UTF-8")
        }
        return name
    }

    private static func directoryName(_ data: ByteReader, _ key: Range<Int>, hashed: Bool) throws -> String {
        let prefix = hashed ? Format.DirectoryRecord.hashedNamePrefix : Format.DirectoryRecord.plainNamePrefix
        guard key.count >= prefix else { throw ReaderError.corrupt("short directory key") }
        let length =
            hashed
            ? Int(
                try data.le32(key.lowerBound + Format.DirectoryRecord.nameLength)
                    & Format.DirectoryRecord.hashedNameLengthMask)
            : Int(try data.le16(key.lowerBound + Format.DirectoryRecord.nameLength))
        guard length == key.count - prefix else { throw ReaderError.corrupt("directory key length mismatch") }
        return try name(data.slice(key.lowerBound + prefix, length))
    }

    // MARK: Extended attributes

    private struct RawXattr {
        let name: String
        let value: XattrValue
        let fileSystemOwned: Bool
    }

    private func rawXattrs(of id: UInt64) throws -> [RawXattr] {
        var pending: [(name: String, value: XattrValue?, stream: (id: UInt64, size: UInt64)?, owned: Bool)] = []
        try records(of: id, type: Format.Record.typeXattr) { data, key, value in
            guard key.count >= Format.Xattr.namePrefix, value.count >= Format.Xattr.data else {
                throw ReaderError.corrupt("short xattr record on \(id)")
            }
            let nameLength = Int(try data.le16(key.lowerBound + Format.Xattr.nameLength))
            guard Format.Xattr.namePrefix + nameLength <= key.count else {
                throw ReaderError.corrupt("xattr name overruns its key on \(id)")
            }
            let name = try Self.name(data.slice(key.lowerBound + Format.Xattr.namePrefix, nameLength))
            let flags = try data.le16(value.lowerBound + Format.Xattr.flags)
            let length = Int(try data.le16(value.lowerBound + Format.Xattr.dataLength))
            let start = value.lowerBound + Format.Xattr.data
            guard start + length <= value.upperBound else {
                throw ReaderError.corrupt("xattr \(name) overruns its record on \(id)")
            }
            let owned = flags & Format.Xattr.flagFileSystemOwned != 0
            if flags & Format.Xattr.flagDataStream != 0 {
                guard length >= Format.Xattr.streamDataStream + Format.DataStream.structSize else {
                    throw ReaderError.corrupt("xattr \(name) has a short stream on \(id)")
                }
                let streamID = try data.le64(start + Format.Xattr.streamObjectID)
                let size = try data.le64(start + Format.Xattr.streamDataStream + Format.DataStream.size)
                pending.append((name, nil, (streamID, size), owned))
            } else {
                pending.append((name, .inline(try data.slice(start, length)), nil, owned))
            }
            return true
        }
        // Stream extents are read after the scan so the scan closure stays non-reentrant.
        return try pending.map { item in
            if let stream = item.stream {
                let extents = try streamExtents(streamID: stream.id, size: stream.size)
                return RawXattr(
                    name: item.name, value: .extents(extents, size: stream.size), fileSystemOwned: item.owned)
            }
            return RawXattr(name: item.name, value: item.value ?? .inline([]), fileSystemOwned: item.owned)
        }
    }

    // MARK: Extents

    /// The extents of a data stream (file or xattr) up to `size`, with gaps and zero
    /// physical addresses reported as holes.
    private func streamExtents(streamID: UInt64, size: UInt64) throws -> [Extent] {
        guard size > 0 else { return [] }
        var raw: [(logical: UInt64, length: UInt64, block: UInt64)] = []
        let collect = { (data: ByteReader, logical: UInt64, value: Range<Int>) throws -> Bool in
            guard value.count >= Format.FileExtent.valueSize else {
                throw ReaderError.corrupt("short file extent in stream \(streamID)")
            }
            let length =
                try data.le64(value.lowerBound + Format.FileExtent.lengthAndFlags) & Format.FileExtent.lengthMask
            raw.append((logical, length, try data.le64(value.lowerBound + Format.FileExtent.physicalBlock)))
            return logical < size
        }
        if let extentTree {
            try extentTree.scan(
                order: { data, key in
                    guard key.count >= Format.FileExtent.keySize else { throw ReaderError.corrupt("short extent key") }
                    let keyID = try data.le64(key.lowerBound + Format.FileExtent.sealedPrivateID)
                    return keyID == streamID ? .inside : (keyID < streamID ? .before : .after)
                },
                visit: { data, key, value in
                    try collect(data, try data.le64(key.lowerBound + Format.FileExtent.sealedLogicalAddress), value)
                })
        } else {
            try records(of: streamID, type: Format.Record.typeFileExtent) { data, key, value in
                guard key.count >= Format.FileExtent.keySize else { throw ReaderError.corrupt("short extent key") }
                return try collect(data, try data.le64(key.lowerBound + Format.FileExtent.logicalAddress), value)
            }
        }

        var extents: [Extent] = []
        var next: UInt64 = 0
        for item in raw where item.logical < size {
            guard item.logical >= next, item.length > 0 else {
                throw ReaderError.corrupt("overlapping extents in stream \(streamID)")
            }
            if item.logical > next {
                extents.append(Extent(fileOffset: next, deviceOffset: 0, length: item.logical - next, isHole: true))
            }
            if item.block == 0 {
                extents.append(Extent(fileOffset: item.logical, deviceOffset: 0, length: item.length, isHole: true))
            } else {
                let offset = try store.byteOffset(ofBlock: item.block, length: item.length)
                extents.append(Extent(fileOffset: item.logical, deviceOffset: offset, length: item.length))
            }
            let (end, overflow) = item.logical.addingReportingOverflow(item.length)
            guard !overflow else { throw ReaderError.corrupt("extent overflow in stream \(streamID)") }
            next = end
        }
        if next < size {
            extents.append(Extent(fileOffset: next, deviceOffset: 0, length: size - next, isHole: true))
        }
        return extents
    }

    private func read(_ extents: [Extent], size: UInt64) throws -> [UInt8] {
        guard size <= UInt64(Int.max) else { throw ReaderError.corrupt("attribute too large") }
        var out = [UInt8](repeating: 0, count: Int(size))
        for extent in extents where !extent.isHole && extent.fileOffset < size {
            let start = Int(extent.fileOffset)
            let length = Int(min(extent.length, size - extent.fileOffset))
            try out.withUnsafeMutableBytes { all in
                try device.read(
                    at: extent.deviceOffset, into: UnsafeMutableRawBufferPointer(rebasing: all[start..<start + length]))
            }
        }
        return out
    }

    /// A best-effort path for error messages, built from each inode's parent and name.
    private func path(of inode: Inode) throws -> String {
        var components: [String] = []
        var current = inode
        for _ in 0..<Self.maxPathDepth {
            guard current.id != Format.Record.rootDirectoryID else { break }
            components.append(current.name ?? "#\(current.id)")
            guard let parent = try? self.inode(current.parentID) else { break }
            current = parent
        }
        return "/" + components.reversed().joined(separator: "/")
    }
}

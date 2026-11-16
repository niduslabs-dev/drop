import ReaderCore

/// A read-only HFS+ (`H+`) or HFSX (`HX`, case-sensitive) volume over a `BlockDevice`,
/// following Apple's TN1150.
///
/// Opening walks the whole catalog leaf chain once to index every file and folder record
/// by CNID (8 bytes each), because `Entry` carries only an ID and a record can only be
/// found by `(parent, name)` under HFS+'s case-folding order. After `init` returns, all
/// state is immutable, so every method is safe to call from many threads at once.
///
/// What callers must know:
/// - Names are decoded from the stored UTF-16 exactly (HFS+ stores them decomposed; no
///   normalisation is applied). The one change is the POSIX mapping the kernel makes:
///   a stored `/` is reported as `:`.
/// - Hard links resolve to their indirect node: the entry's `id` is the inode's CNID,
///   its `name` is the link's, and `isHardLink` is set. Directory hard links work the same.
/// - The private metadata folders and, on journaled volumes, the journal files are hidden
///   from the root, as the kernel hides them.
/// - An HFS wrapper (`BD`) with an embedded HFS+ volume is opened by offsetting into the
///   embedded volume; extents then point into a `SliceDevice` over the original device.
public struct HFSPlusVolume: FileSystem {
    public let kind: String
    public let volumeName: String
    public let device: any BlockDevice
    /// True for HFSX volumes whose catalog compares names by binary order.
    public let isCaseSensitive: Bool
    let blockSize: UInt32

    let catalog: BTree
    let extentsOverflow: BTree
    let attributes: BTree?
    private let locators: [UInt32: Locator]
    private let fileInodes: [UInt32: UInt32]
    private let directoryInodes: [UInt32: UInt32]
    private let hiddenRootIDs: Set<UInt32>
    /// Raw catalog record counts, for comparing against other tools' surveys.
    let statistics: Statistics

    struct Statistics: Sendable, Equatable {
        var folders = 0
        var files = 0
        var symlinks = 0
        var hardLinks = 0
        var compressed = 0
    }

    /// Where a file or folder record sits in the catalog.
    private struct Locator: Sendable {
        let node: UInt32
        let index: UInt16
    }

    // MARK: Opening

    /// Opens the volume whose first byte is at offset 0 of `device`.
    ///
    /// Throws `unsupportedFileSystem` when the signature is neither HFS+ nor HFSX, or for
    /// a plain HFS volume, and `corrupt` for malformed structures.
    public init(device: any BlockDevice) throws {
        let header = ByteReader(try Self.readHeader(device))
        var signature = try header.be16(VolumeHeader.signature)
        var device = device
        var volumeHeader = header
        if signature == Signature.hfsWrapper {
            device = try Self.embeddedVolume(in: device, masterDirectoryBlock: header)
            volumeHeader = ByteReader(try Self.readHeader(device))
            signature = try volumeHeader.be16(VolumeHeader.signature)
        }
        let version = try volumeHeader.be16(VolumeHeader.version)
        switch (signature, version) {
        case (Signature.hfsPlus, Signature.hfsPlusVersion): kind = "HFS+"
        case (Signature.hfsx, Signature.hfsxVersion): kind = "HFSX"
        case (Signature.hfsPlus, _), (Signature.hfsx, _):
            throw ReaderError.unsupportedFileSystem("HFS+ version \(version)")
        default:
            throw ReaderError.unsupportedFileSystem(
                String(format: "unknown signature 0x%04x", signature))
        }
        let blockSize = try volumeHeader.be32(VolumeHeader.blockSize)
        guard blockSize >= VolumeHeader.minimumBlockSize, blockSize & (blockSize - 1) == 0 else {
            throw ReaderError.corrupt("allocation block size \(blockSize)")
        }
        let totalBlocks = UInt64(try volumeHeader.be32(VolumeHeader.totalBlocks))
        guard totalBlocks * UInt64(blockSize) <= device.size else {
            throw ReaderError.corrupt(
                "volume of \(totalBlocks) blocks of \(blockSize) bytes on a \(device.size)-byte device")
        }
        self.device = device
        self.blockSize = blockSize

        let extentsFork = try Self.inlineFork(
            volumeHeader, at: VolumeHeader.extentsFile, blockSize: blockSize, device: device)
        guard extentsFork.isComplete else {
            throw ReaderError.corrupt("extents overflow file needs overflow extents")
        }
        extentsOverflow = try BTree(name: "extents", device: device, fork: extentsFork.map)

        let catalogFork = try Self.inlineFork(
            volumeHeader, at: VolumeHeader.catalogFile, blockSize: blockSize, device: device)
        catalog = try BTree(
            name: "catalog", device: device,
            fork: try Self.complete(
                catalogFork, fileID: CNID.catalogFile, forkType: ForkType.data, overflow: extentsOverflow,
                blockSize: blockSize, device: device))

        let attributesFork = try Self.inlineFork(
            volumeHeader, at: VolumeHeader.attributesFile, blockSize: blockSize, device: device)
        if attributesFork.map.logicalSize == 0 {
            attributes = nil
        } else {
            attributes = try BTree(
                name: "attributes", device: device,
                fork: try Self.complete(
                    attributesFork, fileID: CNID.attributesFile, forkType: ForkType.data,
                    overflow: extentsOverflow, blockSize: blockSize, device: device))
        }
        isCaseSensitive = kind == "HFSX" && catalog.keyCompareType == KeyCompare.binary

        let index = try Self.indexCatalog(catalog)
        locators = index.locators
        statistics = index.statistics
        fileInodes = index.fileInodes
        directoryInodes = index.directoryInodes
        var hidden = Set(index.privateFolders)
        let journaled = try volumeHeader.be32(VolumeHeader.attributes) & VolumeHeader.journaledBit != 0
        if journaled { hidden.formUnion(index.journalFiles) }
        hiddenRootIDs = hidden

        guard let rootThread = try Self.thread(of: CNID.root, in: catalog) else {
            throw ReaderError.corrupt("root folder has no thread record")
        }
        volumeName = rootThread.name
    }

    private static func readHeader(_ device: any BlockDevice) throws -> [UInt8] {
        do {
            return try device.read(at: VolumeHeader.offset, count: VolumeHeader.size)
        } catch ReaderError.outOfBounds {
            throw ReaderError.corrupt("device too small for a volume header")
        }
    }

    /// The embedded HFS+ volume of an HFS wrapper, located from the wrapper's master
    /// directory block (TN1150 "HFS Wrapper").
    private static func embeddedVolume(in device: any BlockDevice, masterDirectoryBlock mdb: ByteReader) throws
        -> any BlockDevice
    {
        guard try mdb.be16(Wrapper.embeddedSignature) == Signature.hfsPlus else {
            throw ReaderError.unsupportedFileSystem("HFS")
        }
        let blockSize = UInt64(try mdb.be32(Wrapper.allocationBlockSize))
        let firstBlock = UInt64(try mdb.be16(Wrapper.allocationBlockStart))
        let start = UInt64(try mdb.be16(Wrapper.embeddedStartBlock))
        let count = UInt64(try mdb.be16(Wrapper.embeddedBlockCount))
        let offset = firstBlock * Wrapper.sectorSize + start * blockSize
        do {
            return try SliceDevice(base: device, start: offset, size: count * blockSize)
        } catch {
            throw ReaderError.corrupt("embedded HFS+ volume lies outside the wrapper")
        }
    }

    // MARK: Forks and extents

    /// A fork from its 8 inline extents; `isComplete` is false when the extents overflow
    /// file holds more.
    private struct InlineFork {
        let map: ForkMap
        let totalBlocks: UInt32
        let mappedBlocks: UInt32
        var isComplete: Bool { mappedBlocks >= totalBlocks }
    }

    private static func inlineFork(
        _ reader: ByteReader, at offset: Int, blockSize: UInt32, device: any BlockDevice
    ) throws -> InlineFork {
        let logicalSize = try reader.be64(offset + ForkData.logicalSize)
        let totalBlocks = try reader.be32(offset + ForkData.totalBlocks)
        var extents: [Extent] = []
        var mapped: UInt64 = 0
        try appendExtents(
            reader, at: offset + ForkData.extents, to: &extents, mapped: &mapped, blockSize: blockSize, device: device)
        guard mapped <= UInt64(totalBlocks) else {
            throw ReaderError.corrupt("fork maps \(mapped) blocks but has \(totalBlocks)")
        }
        guard logicalSize <= UInt64(totalBlocks) * UInt64(blockSize) else {
            throw ReaderError.corrupt("fork of \(logicalSize) bytes in \(totalBlocks) blocks")
        }
        return InlineFork(
            map: ForkMap(extents: extents, logicalSize: logicalSize), totalBlocks: totalBlocks,
            mappedBlocks: UInt32(mapped))
    }

    /// Appends the non-empty descriptors of an 8-entry extent record.
    private static func appendExtents(
        _ reader: ByteReader, at offset: Int, to extents: inout [Extent], mapped: inout UInt64,
        blockSize: UInt32, device: any BlockDevice
    ) throws {
        for slot in 0..<ForkData.extentsPerRecord {
            let base = offset + slot * ForkData.extentDescriptorSize
            let start = UInt64(try reader.be32(base))
            let count = UInt64(try reader.be32(base + 4))
            guard count > 0 else { continue }
            let deviceOffset = start * UInt64(blockSize)
            let length = count * UInt64(blockSize)
            guard deviceOffset + length <= device.size else {
                throw ReaderError.corrupt("extent at block \(start) runs past the end of the volume")
            }
            extents.append(Extent(fileOffset: mapped * UInt64(blockSize), deviceOffset: deviceOffset, length: length))
            mapped += count
        }
    }

    /// Adds the extents overflow records of a fork until all of its blocks are mapped.
    private static func complete(
        _ fork: InlineFork, fileID: UInt32, forkType: UInt8, overflow: BTree, blockSize: UInt32,
        device: any BlockDevice
    ) throws -> ForkMap {
        guard !fork.isComplete else { return fork.map }
        var extents = fork.map.extents
        var mapped = UInt64(fork.mappedBlocks)
        // Each overflow record maps at least one block, so totalBlocks bounds the loop.
        var records: UInt32 = 0
        while mapped < UInt64(fork.totalBlocks) {
            records += 1
            guard records <= fork.totalBlocks else { throw ReaderError.corrupt("extents overflow loops") }
            let startBlock = UInt32(mapped)
            let target = (fileID, forkType, startBlock)
            let position = try overflow.seek { record in
                try ExtentKey(record).ordered < target
            }
            guard let position, position.index < position.node.recordCount else {
                throw ReaderError.corrupt("missing overflow extents for file \(fileID) at block \(startBlock)")
            }
            let record = try overflow.record(position.node, position.index)
            guard try ExtentKey(record).ordered == target else {
                throw ReaderError.corrupt("missing overflow extents for file \(fileID) at block \(startBlock)")
            }
            let before = mapped
            try appendExtents(
                record.reader, at: record.dataStart, to: &extents, mapped: &mapped, blockSize: blockSize, device: device
            )
            guard mapped > before, mapped <= UInt64(fork.totalBlocks) else {
                throw ReaderError.corrupt("bad overflow extents for file \(fileID)")
            }
        }
        return ForkMap(extents: extents, logicalSize: fork.map.logicalSize)
    }

    private func forkMap(of record: CatalogFile, forkType: UInt8) throws -> ForkMap {
        let offset = forkType == ForkType.data ? CatalogFile.dataFork : CatalogFile.resourceFork
        let fork = try Self.inlineFork(
            record.reader, at: record.dataStart + offset, blockSize: blockSize, device: device)
        return try Self.complete(
            fork, fileID: record.fileID, forkType: forkType, overflow: extentsOverflow, blockSize: blockSize,
            device: device)
    }

    // MARK: Catalog index

    private struct CatalogIndex {
        var locators: [UInt32: Locator] = [:]
        var statistics = Statistics()
        var privateFolders: [UInt32] = []
        var journalFiles: [UInt32] = []
        var fileInodes: [UInt32: UInt32] = [:]
        var directoryInodes: [UInt32: UInt32] = [:]
    }

    private static func indexCatalog(_ catalog: BTree) throws -> CatalogIndex {
        var index = CatalogIndex()
        // Records are sorted by parent, so the root's children (and thus the private
        // folders' IDs) are known before any record inside them is seen.
        var fileFolder: UInt32?
        var directoryFolder: UInt32?
        try catalog.scan { record in
            let key = try CatalogKey(record)
            let type = try record.reader.be16(record.dataStart)
            let locator = Locator(node: record.node.number, index: UInt16(record.index))
            switch type {
            case RecordType.folder:
                let folderID = try record.reader.be32(record.dataStart + CatalogFolder.folderID)
                index.locators[folderID] = locator
                index.statistics.folders += 1
                if key.parentID == CNID.root, key.rawName == PrivateFolder.files {
                    fileFolder = folderID
                    index.privateFolders.append(folderID)
                } else if key.parentID == CNID.root, key.rawName == PrivateFolder.directories {
                    directoryFolder = folderID
                    index.privateFolders.append(folderID)
                } else if key.parentID == directoryFolder,
                    let number = inodeNumber(key.rawName, prefix: PrivateFolder.directoryPrefix)
                {
                    index.directoryInodes[number] = folderID
                }
            case RecordType.file:
                let file = try CatalogFile(record)
                index.locators[file.fileID] = locator
                if file.isSymlink { index.statistics.symlinks += 1 } else { index.statistics.files += 1 }
                if file.isFileHardLink { index.statistics.hardLinks += 1 }
                if file.isCompressed { index.statistics.compressed += 1 }
                if key.parentID == CNID.root, PrivateFolder.journalNames.contains(key.rawName) {
                    index.journalFiles.append(file.fileID)
                } else if key.parentID == fileFolder,
                    let number = inodeNumber(key.rawName, prefix: PrivateFolder.filePrefix)
                {
                    index.fileInodes[number] = file.fileID
                }
            case RecordType.folderThread, RecordType.fileThread:
                break
            default:
                throw ReaderError.corrupt("catalog record type \(type)")
            }
            return true
        }
        return index
    }

    /// The `<n>` of an indirect node name such as `iNode123` or `dir_45`.
    private static func inodeNumber(_ name: [UInt16], prefix: [UInt16]) -> UInt32? {
        guard name.count > prefix.count, name.starts(with: prefix) else { return nil }
        var value: UInt64 = 0
        for unit in name.dropFirst(prefix.count) {
            guard unit >= 0x30, unit <= 0x39 else { return nil }
            value = value * 10 + UInt64(unit - 0x30)
            guard value <= UInt64(UInt32.max) else { return nil }
        }
        return UInt32(value)
    }

    private static func thread(of cnid: UInt32, in catalog: BTree) throws -> (parentID: UInt32, name: String)? {
        let position = try catalog.seek { record in try CatalogKey(record).parentID < cnid }
        guard let position, position.index < position.node.recordCount else { return nil }
        let record = try catalog.record(position.node, position.index)
        let key = try CatalogKey(record)
        let type = try record.reader.be16(record.dataStart)
        guard key.parentID == cnid, key.rawName.isEmpty,
            type == RecordType.folderThread || type == RecordType.fileThread
        else { return nil }
        let parent = try record.reader.be32(record.dataStart + Thread.parentID)
        let name = try CatalogKey.decodeName(record.reader, at: record.dataStart + Thread.name)
        return (parent, CatalogKey.posixName(name))
    }

    /// The catalog record of `cnid`, read back from its indexed location.
    private func catalogRecord(_ cnid: UInt32) throws -> BTreeRecord {
        guard let locator = locators[cnid] else { throw ReaderError.corrupt("no catalog record for CNID \(cnid)") }
        let node = try catalog.node(locator.node)
        guard Int(locator.index) < node.recordCount else {
            throw ReaderError.corrupt("catalog changed under the index")
        }
        return try catalog.record(node, Int(locator.index))
    }

    // MARK: Entries

    public var root: Entry {
        get throws {
            let record = try catalogRecord(CNID.root)
            return try entry(for: record, name: volumeName)
        }
    }

    public func children(of directory: Entry) throws -> [Entry] {
        guard directory.kind == .directory, let folderID = UInt32(exactly: directory.id) else {
            throw ReaderError.notADirectory
        }
        let position = try catalog.seek { record in try CatalogKey(record).parentID < folderID }
        guard let position else { return [] }
        var entries: [Entry] = []
        var sawThread = false
        try catalog.scan(from: position) { record in
            let key = try CatalogKey(record)
            guard key.parentID == folderID else { return false }
            let type = try record.reader.be16(record.dataStart)
            if type == RecordType.folderThread || type == RecordType.fileThread {
                sawThread = true
                return true
            }
            if folderID == CNID.root, hiddenRootIDs.contains(try Self.recordCNID(record, type: type)) {
                return true
            }
            entries.append(try entry(for: record, name: CatalogKey.posixName(key.rawName)))
            return true
        }
        guard sawThread || entries.isEmpty else {
            throw ReaderError.corrupt("folder \(folderID) has children but no thread record")
        }
        return entries
    }

    private static func recordCNID(_ record: BTreeRecord, type: UInt16) throws -> UInt32 {
        let offset = type == RecordType.folder ? CatalogFolder.folderID : CatalogFile.fileID
        return try record.reader.be32(record.dataStart + offset)
    }

    /// Builds the entry for a folder or file record, following hard links to their inode.
    private func entry(for record: BTreeRecord, name: String) throws -> Entry {
        let type = try record.reader.be16(record.dataStart)
        switch type {
        case RecordType.folder:
            let folder = try CatalogFolder(record)
            return Entry(id: UInt64(folder.folderID), name: name, kind: .directory, mode: folder.mode, size: 0)
        case RecordType.file:
            let file = try CatalogFile(record)
            if file.isFileHardLink {
                guard let inode = fileInodes[file.linkTarget] else {
                    throw ReaderError.corrupt("hard link \(name) to missing iNode\(file.linkTarget)")
                }
                let target = try CatalogFile(try catalogRecord(inode))
                return Entry(
                    id: UInt64(inode), name: name, kind: target.kind, mode: target.mode, size: try checkedSize(target),
                    isCompressed: target.isCompressed, isHardLink: true)
            }
            if file.isDirectoryHardLink {
                guard let folderID = directoryInodes[file.linkTarget] else {
                    throw ReaderError.corrupt("directory hard link \(name) to missing dir_\(file.linkTarget)")
                }
                let folder = try CatalogFolder(try catalogRecord(folderID))
                return Entry(
                    id: UInt64(folderID), name: name, kind: .directory, mode: folder.mode, size: 0, isHardLink: true)
            }
            return Entry(
                id: UInt64(file.fileID), name: name, kind: file.kind, mode: file.mode, size: try checkedSize(file),
                isCompressed: file.isCompressed)
        default:
            throw ReaderError.corrupt("catalog record type \(type) where a file or folder was expected")
        }
    }

    /// The data fork's logical size, checked against its allocated blocks so callers can
    /// size buffers from `Entry.size` without trusting the record.
    private func checkedSize(_ file: CatalogFile) throws -> UInt64 {
        guard file.dataSize <= UInt64(file.dataTotalBlocks) * UInt64(blockSize), file.dataSize <= device.size else {
            throw ReaderError.corrupt(
                "file \(file.fileID) claims \(file.dataSize) bytes in \(file.dataTotalBlocks) blocks")
        }
        return file.dataSize
    }

    private func fileRecord(_ entry: Entry) throws -> CatalogFile {
        guard let cnid = UInt32(exactly: entry.id) else { throw ReaderError.corrupt("CNID \(entry.id) out of range") }
        let record = try catalogRecord(cnid)
        guard try record.reader.be16(record.dataStart) == RecordType.file else {
            throw ReaderError.corrupt("CNID \(cnid) is not a file")
        }
        return try CatalogFile(record)
    }

    /// Throws `compressedFile(path:)` with the entry's name (the reader doesn't know the
    /// full path) for decmpfs files, whose data lives in an xattr or the resource fork.
    public func extents(of file: Entry) throws -> [Extent] {
        guard file.kind != .directory else { throw ReaderError.notADirectory }
        let record = try fileRecord(file)
        if record.isCompressed { throw ReaderError.compressedFile(path: file.name) }
        let map = try forkMap(of: record, forkType: ForkType.data)
        return map.logicalSize == 0 ? [] : map.extents
    }

    public func symlinkTarget(of link: Entry) throws -> String {
        guard link.kind == .symlink else { throw ReaderError.notASymlink }
        let record = try fileRecord(link)
        let map = try forkMap(of: record, forkType: ForkType.data)
        guard map.logicalSize <= Limits.maximumSymlinkLength else {
            throw ReaderError.corrupt("symlink target of \(map.logicalSize) bytes")
        }
        let bytes = try map.read(device, at: 0, count: Int(map.logicalSize))
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Extended attributes

    /// The Attributes B-tree records of the item, plus `com.apple.ResourceFork` for a
    /// non-empty resource fork and `com.apple.FinderInfo` when the Finder info is set
    /// (after clearing the fields the kernel hides, such as the date added).
    /// `com.apple.system.*` entries (ACLs and other kernel bookkeeping) are left out.
    public func xattrs(of entry: Entry) throws -> [String: XattrValue] {
        guard let cnid = UInt32(exactly: entry.id) else { throw ReaderError.corrupt("CNID \(entry.id) out of range") }
        var result: [String: XattrValue] = [:]
        let record = try catalogRecord(cnid)
        let type = try record.reader.be16(record.dataStart)
        let finderInfoOffset = type == RecordType.folder ? CatalogFolder.finderInfo : CatalogFile.finderInfo
        var finderInfo = try record.reader.slice(record.dataStart + finderInfoOffset, FinderInfo.size)
        if type == RecordType.file {
            let file = try CatalogFile(record)
            if file.isSymlink {
                finderInfo.replaceSubrange(
                    FinderInfo.typeAndCreator, with: repeatElement(0, count: FinderInfo.typeAndCreator.count))
            }
            let resource = try forkMap(of: file, forkType: ForkType.resource)
            if resource.logicalSize > 0 {
                result[XattrName.resourceFork] = .extents(resource.extents, size: resource.logicalSize)
            }
        }
        for range in FinderInfo.hiddenFields {
            finderInfo.replaceSubrange(range, with: repeatElement(0, count: range.count))
        }
        if finderInfo.contains(where: { $0 != 0 }) { result[XattrName.finderInfo] = .inline(finderInfo) }

        guard let attributes else { return result }
        let position = try attributes.seek { record in try AttributeKey(record).fileID < cnid }
        guard let position else { return result }
        var pendingFork: (name: String, extents: [Extent], mapped: UInt64, size: UInt64, total: UInt32)?
        func finishFork() throws {
            guard let fork = pendingFork else { return }
            guard fork.mapped >= UInt64(fork.total) else {
                throw ReaderError.corrupt("xattr \(fork.name) is missing extents")
            }
            result[fork.name] = .extents(fork.extents, size: fork.size)
            pendingFork = nil
        }
        try attributes.scan(from: position) { record in
            let key = try AttributeKey(record)
            guard key.fileID == cnid else { return false }
            let reader = record.reader
            let type = try reader.be32(record.dataStart)
            switch type {
            case AttributeRecord.inlineData:
                try finishFork()
                let size = Int(try reader.be32(record.dataStart + AttributeRecord.inlineSize))
                let data = try reader.slice(record.dataStart + AttributeRecord.inlineDataStart, size)
                result[key.name] = .inline(data)
            case AttributeRecord.forkData:
                try finishFork()
                let fork = try Self.inlineFork(
                    reader, at: record.dataStart + AttributeRecord.forkStart, blockSize: blockSize, device: device)
                pendingFork = (
                    key.name, fork.map.extents, UInt64(fork.mappedBlocks), fork.map.logicalSize, fork.totalBlocks
                )
            case AttributeRecord.extents:
                guard var fork = pendingFork, fork.name == key.name, UInt64(key.startBlock) == fork.mapped else {
                    throw ReaderError.corrupt("stray xattr extents record for \(key.name)")
                }
                try Self.appendExtents(
                    reader, at: record.dataStart + AttributeRecord.forkStart, to: &fork.extents, mapped: &fork.mapped,
                    blockSize: blockSize, device: device)
                pendingFork = fork
            default:
                throw ReaderError.corrupt("xattr record type \(type)")
            }
            return true
        }
        try finishFork()
        for name in result.keys where name.hasPrefix(XattrName.systemPrefix) { result[name] = nil }
        return result
    }
}

// MARK: - Record views

/// A catalog key: parent CNID and the raw UTF-16 name.
struct CatalogKey {
    static let parentID = 2
    static let name = 6
    static let maximumNameLength = 255

    let parentID: UInt32
    let rawName: [UInt16]

    init(_ record: BTreeRecord) throws {
        parentID = try record.reader.be32(record.keyStart + Self.parentID)
        rawName = try Self.decodeName(record.reader, at: record.keyStart + Self.name)
    }

    /// Reads an `HFSUniStr255` (length, then big-endian UTF-16 units).
    static func decodeName(_ reader: ByteReader, at offset: Int) throws -> [UInt16] {
        let length = Int(try reader.be16(offset))
        guard length <= maximumNameLength else { throw ReaderError.corrupt("name of \(length) units") }
        var units: [UInt16] = []
        units.reserveCapacity(length)
        for index in 0..<length { units.append(try reader.be16(offset + 2 + 2 * index)) }
        return units
    }

    /// The name as POSIX sees it: HFS+ stores `:` (the classic Mac separator) as `/`.
    static func posixName(_ units: [UInt16]) -> String {
        let slash: UInt16 = 0x2F
        let colon: UInt16 = 0x3A
        return String(decoding: units.map { $0 == slash ? colon : $0 }, as: UTF16.self)
    }
}

/// An extents overflow key, as its sort tuple.
struct ExtentKey {
    let ordered: (UInt32, UInt8, UInt32)

    init(_ record: BTreeRecord) throws {
        let reader = record.reader
        let forkType = try reader.u8(record.keyStart + 2)
        let fileID = try reader.be32(record.keyStart + 4)
        let startBlock = try reader.be32(record.keyStart + 8)
        ordered = (fileID, forkType, startBlock)
    }
}

/// An attributes key: owning CNID, start block (for extents records) and name.
struct AttributeKey {
    let fileID: UInt32
    let startBlock: UInt32
    let name: String

    init(_ record: BTreeRecord) throws {
        let reader = record.reader
        fileID = try reader.be32(record.keyStart + 4)
        startBlock = try reader.be32(record.keyStart + 8)
        let units = try CatalogKey.decodeName(reader, at: record.keyStart + 12)
        name = String(decoding: units, as: UTF16.self)
    }
}

/// `HFSPlusCatalogFolder` fields.
struct CatalogFolder {
    static let folderID = 8
    static let permissions = 32
    static let finderInfo = 48

    let folderID: UInt32
    let mode: UInt16

    init(_ record: BTreeRecord) throws {
        let reader = record.reader
        guard record.end - record.dataStart >= Self.size else { throw ReaderError.corrupt("short folder record") }
        folderID = try reader.be32(record.dataStart + Self.folderID)
        let raw = try reader.be16(record.dataStart + Self.permissions + BSDInfo.fileMode)
        mode = raw & BSDInfo.fileTypeMask == 0 ? BSDInfo.defaultDirectoryMode : raw & BSDInfo.permissionMask
    }

    static let size = 88
}

/// `HFSPlusCatalogFile` fields.
struct CatalogFile {
    static let fileID = 8
    static let permissions = 32
    static let fileType = 48
    static let creator = 52
    static let finderInfo = 48
    static let dataFork = 88
    static let resourceFork = 168
    static let size = 248

    let reader: ByteReader
    let dataStart: Int
    let fileID: UInt32
    let mode: UInt16
    let kind: Entry.Kind
    let ownerFlags: UInt8
    let type: UInt32
    let creator: UInt32
    /// `special.iNodeNum` for links: the `<n>` of `iNode<n>` or `dir_<n>`.
    let linkTarget: UInt32
    let dataSize: UInt64
    let dataTotalBlocks: UInt32

    init(_ record: BTreeRecord) throws {
        reader = record.reader
        dataStart = record.dataStart
        guard record.end - record.dataStart >= Self.size else { throw ReaderError.corrupt("short file record") }
        fileID = try reader.be32(dataStart + Self.fileID)
        let bsd = dataStart + Self.permissions
        ownerFlags = try reader.u8(bsd + BSDInfo.ownerFlags)
        let rawMode = try reader.be16(bsd + BSDInfo.fileMode)
        linkTarget = try reader.be32(bsd + BSDInfo.special)
        type = try reader.be32(dataStart + Self.fileType)
        creator = try reader.be32(dataStart + Self.creator)
        dataSize = try reader.be64(dataStart + Self.dataFork + ForkData.logicalSize)
        dataTotalBlocks = try reader.be32(dataStart + Self.dataFork + ForkData.totalBlocks)
        let fileType = rawMode & BSDInfo.fileTypeMask
        if fileType == BSDInfo.symlinkType || (type == FileTypes.symlink && creator == FileTypes.symlinkCreator) {
            kind = .symlink
        } else if fileType == 0 || fileType == BSDInfo.regularType {
            kind = .file
        } else {
            kind = .other
        }
        mode = fileType == 0 ? BSDInfo.defaultFileMode : rawMode & BSDInfo.permissionMask
    }

    var isSymlink: Bool { kind == .symlink }
    var isCompressed: Bool { ownerFlags & BSDInfo.compressedFlag != 0 }
    var isFileHardLink: Bool { type == FileTypes.hardLink && creator == FileTypes.hardLinkCreator }
    var isDirectoryHardLink: Bool { type == FileTypes.directoryLink && creator == FileTypes.directoryLinkCreator }
}

// MARK: - On-disk constants (TN1150)

enum Signature {
    static let hfsPlus: UInt16 = 0x482B  // "H+"
    static let hfsx: UInt16 = 0x4858  // "HX"
    static let hfsWrapper: UInt16 = 0x4244  // "BD"
    static let hfsPlusVersion: UInt16 = 4
    static let hfsxVersion: UInt16 = 5
}

enum VolumeHeader {
    static let offset: UInt64 = 1024
    static let size = 512
    static let signature = 0
    static let version = 2
    static let attributes = 4
    static let blockSize = 40
    static let totalBlocks = 44
    static let extentsFile = 192
    static let catalogFile = 272
    static let attributesFile = 352
    static let journaledBit: UInt32 = 1 << 13
    static let minimumBlockSize: UInt32 = 512
}

/// The classic HFS master directory block of a wrapper volume.
enum Wrapper {
    static let allocationBlockSize = 0x14
    static let allocationBlockStart = 0x1C
    static let embeddedSignature = 0x7C
    static let embeddedStartBlock = 0x7E
    static let embeddedBlockCount = 0x80
    static let sectorSize: UInt64 = 512
}

enum ForkData {
    static let logicalSize = 0
    static let totalBlocks = 12
    static let extents = 16
    static let extentsPerRecord = 8
    static let extentDescriptorSize = 8
}

enum ForkType {
    static let data: UInt8 = 0x00
    static let resource: UInt8 = 0xFF
}

enum CNID {
    static let root: UInt32 = 2
    static let catalogFile: UInt32 = 4
    static let attributesFile: UInt32 = 8
}

enum RecordType {
    static let folder: UInt16 = 1
    static let file: UInt16 = 2
    static let folderThread: UInt16 = 3
    static let fileThread: UInt16 = 4
}

enum Thread {
    static let parentID = 4
    static let name = 8
}

enum KeyCompare {
    static let binary: UInt8 = 0xBC
}

enum BSDInfo {
    static let ownerFlags = 9
    static let fileMode = 10
    static let special = 12
    static let compressedFlag: UInt8 = 0x20  // UF_COMPRESSED
    static let fileTypeMask: UInt16 = 0o170000
    static let regularType: UInt16 = 0o100000
    static let symlinkType: UInt16 = 0o120000
    static let permissionMask: UInt16 = 0o7777
    /// What the kernel reports for records created without BSD info.
    static let defaultFileMode: UInt16 = 0o644
    static let defaultDirectoryMode: UInt16 = 0o755
}

enum FileTypes {
    static let symlink: UInt32 = 0x736C_6E6B  // "slnk"
    static let symlinkCreator: UInt32 = 0x7268_6170  // "rhap"
    static let hardLink: UInt32 = 0x686C_6E6B  // "hlnk"
    static let hardLinkCreator: UInt32 = 0x6866_732B  // "hfs+"
    static let directoryLink: UInt32 = 0x6664_7270  // "fdrp"
    static let directoryLinkCreator: UInt32 = 0x4D41_4353  // "MACS"
}

enum PrivateFolder {
    /// "\0\0\0\0HFS+ Private Data", holding `iNode<n>` file inodes.
    static let files: [UInt16] = [0, 0, 0, 0] + Array("HFS+ Private Data".utf16)
    /// ".HFS+ Private Directory Data\r", holding `dir_<n>` directory inodes.
    static let directories: [UInt16] = Array(".HFS+ Private Directory Data\r".utf16)
    static let filePrefix: [UInt16] = Array("iNode".utf16)
    static let directoryPrefix: [UInt16] = Array("dir_".utf16)
    static let journalNames: [[UInt16]] = [Array(".journal".utf16), Array(".journal_info_block".utf16)]
}

enum AttributeRecord {
    static let inlineData: UInt32 = 0x10
    static let forkData: UInt32 = 0x20
    static let extents: UInt32 = 0x30
    static let inlineSize = 12
    static let inlineDataStart = 16
    static let forkStart = 8
}

enum XattrName {
    static let resourceFork = "com.apple.ResourceFork"
    static let finderInfo = "com.apple.FinderInfo"
    static let systemPrefix = "com.apple.system."
}

/// The 32 bytes of Finder info as `getxattr(com.apple.FinderInfo)` returns them.
enum FinderInfo {
    static let size = 32
    static let typeAndCreator = 0..<8
    /// `document_id`, `date_added` and `write_gen_counter` of the extended info, which
    /// the kernel zeroes before returning Finder info.
    static let hiddenFields = [16..<24, 28..<32]
}

enum Limits {
    static let maximumSymlinkLength: UInt64 = 1024  // PATH_MAX
}

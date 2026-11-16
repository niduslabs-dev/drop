/// On-disk constants from the Apple File System Reference. Offsets are byte offsets into
/// the structure named by the enclosing enum; all integers are little-endian.
enum Format {
    /// `obj_phys_t`, the 32-byte header at the start of every object.
    enum Object {
        static let checksum = 0
        static let oid = 8
        static let xid = 16
        static let type = 24
        static let subtype = 28
        static let headerSize = 32

        static let typeMask: UInt32 = 0x0000_FFFF
        static let storageMask: UInt32 = 0xC000_0000
        static let storagePhysical: UInt32 = 0x4000_0000
        static let storageEphemeral: UInt32 = 0x8000_0000

        static let typeContainerSuperblock: UInt32 = 0x01
        static let typeBTreeRoot: UInt32 = 0x02
        static let typeBTreeNode: UInt32 = 0x03
        static let typeObjectMap: UInt32 = 0x0B
        static let typeVolumeSuperblock: UInt32 = 0x0D
        static let typeFileSystemTree: UInt32 = 0x0E
        static let typeFileExtentTree: UInt32 = 0x1F
    }

    /// `nx_superblock_t`.
    enum Container {
        static let magic = 32
        static let magicValue: UInt32 = 0x4253_584E  // "NXSB"
        static let blockSize = 36
        static let blockCount = 40
        static let descriptorBlocks = 104
        static let descriptorBase = 112
        static let omapOID = 160
        static let maxFileSystems = 180
        static let fileSystemOIDs = 184

        /// High bit of `nx_xp_desc_blocks`: the descriptor area is a B-tree, not a ring.
        static let descriptorTreeFlag: UInt32 = 0x8000_0000
        static let fileSystemLimit = 100
        static let minBlockSize = 4096
        static let maxBlockSize = 65536
        /// Where the block-zero superblock lives; also the size read before the real
        /// block size is known.
        static let probeSize = 4096
    }

    /// `omap_phys_t`, `omap_key_t`, `omap_val_t`.
    enum ObjectMap {
        static let treeType = 40
        static let treeOID = 48
        static let keySize = 16
        static let valueSize = 16
        static let valueFlags = 0
        static let valuePhysicalAddress = 8
        static let flagDeleted: UInt32 = 0x1
        static let flagEncrypted: UInt32 = 0x4
    }

    /// `btree_node_phys_t` and the trailing `btree_info_t` of a root node.
    enum BTree {
        static let flags = 32
        static let level = 34
        static let keyCount = 36
        static let tableSpaceOffset = 40
        static let tableSpaceLength = 42
        static let data = 56
        static let infoSize = 40
        /// Within `btree_info_t`, counted from its start.
        static let infoKeySize = 8
        static let infoValueSize = 12

        static let flagRoot: UInt16 = 0x1
        static let flagLeaf: UInt16 = 0x2
        static let flagFixedSize: UInt16 = 0x4

        static let fixedEntrySize = 4
        static let variableEntrySize = 8
        static let childOIDSize = 8
        /// Deeper than any real tree: a 64 KiB-node tree of depth 16 would hold more
        /// records than a device can address. Guards against level fields that lie.
        static let maxDepth = 16
    }

    /// `apfs_superblock_t`.
    enum Volume {
        static let magic = 32
        static let magicValue: UInt32 = 0x4253_5041  // "APSB"
        static let incompatibleFeatures = 56
        static let rootTreeType = 116
        static let omapOID = 128
        static let rootTreeOID = 136
        static let fileCount = 184
        static let directoryCount = 192
        static let symlinkCount = 200
        static let flags = 264
        static let name = 704
        static let nameLength = 256
        static let role = 964
        static let fileExtentTreeOID = 1032
        static let fileExtentTreeType = 1040
        static let minimumSize = 1044

        static let incompatCaseInsensitive: UInt64 = 0x1
        static let incompatNormalizationInsensitive: UInt64 = 0x8
        static let incompatSealed: UInt64 = 0x20
        static let flagUnencrypted: UInt64 = 0x1
        static let roleSystem: UInt16 = 0x1
    }

    /// `j_key_t` and the file-system record types stored in the fs tree.
    enum Record {
        static let headerSize = 8
        static let oidMask: UInt64 = 0x0FFF_FFFF_FFFF_FFFF
        static let typeShift: UInt64 = 60

        static let typeInode: UInt8 = 3
        static let typeXattr: UInt8 = 4
        static let typeSiblingLink: UInt8 = 5
        static let typeFileExtent: UInt8 = 8
        static let typeDirectoryRecord: UInt8 = 9

        static let rootDirectoryID: UInt64 = 2
        static let privateDirectoryID: UInt64 = 3
    }

    /// `j_inode_val_t` and its extended fields.
    enum Inode {
        static let parentID = 0
        static let privateID = 8
        static let creationTime = 16
        static let modificationTime = 24
        static let linkCount = 56
        static let bsdFlags = 68
        static let mode = 80
        static let extendedFields = 92
        static let xfieldHeaderSize = 4
        static let xfieldAlignment = 8
        static let xfieldTypeName: UInt8 = 4
        static let xfieldTypeDataStream: UInt8 = 8

        static let compressedFlag: UInt32 = 0x20  // UF_COMPRESSED
    }

    /// `j_dstream_t`.
    enum DataStream {
        static let size = 0
        static let structSize = 40
    }

    /// `j_drec_key_t` / `j_drec_hashed_key_t` and `j_drec_val_t`.
    enum DirectoryRecord {
        static let nameLength = 8
        static let hashedNameLengthMask: UInt32 = 0x3FF
        static let plainNamePrefix = 10
        static let hashedNamePrefix = 12
        static let fileID = 0
        static let valueSize = 18
    }

    /// `j_xattr_key_t`, `j_xattr_val_t`, `j_xattr_dstream_t`.
    enum Xattr {
        static let nameLength = 8
        static let namePrefix = 10
        static let flags = 0
        static let dataLength = 2
        static let data = 4
        static let flagDataStream: UInt16 = 0x1
        static let flagEmbedded: UInt16 = 0x2
        static let flagFileSystemOwned: UInt16 = 0x4
        static let streamObjectID = 0
        static let streamDataStream = 8

        static let symlinkName = "com.apple.fs.symlink"
        static let internalPrefix = "com.apple.fs."
        /// Kernel-protected attributes such as the ACL (`com.apple.system.Security`):
        /// `listxattr` never shows them, so neither does the reader.
        static let systemPrefix = "com.apple.system."
        static let decmpfsName = "com.apple.decmpfs"
    }

    /// `j_sibling_key_t` and `j_sibling_val_t`.
    enum Sibling {
        static let parentID = 0
        static let nameLength = 8
        static let name = 10
    }

    /// `j_file_extent_key_t`/`_val_t` (fs tree) and `fext_tree_key_t`/`_val_t` (sealed volumes).
    enum FileExtent {
        static let logicalAddress = 8
        static let keySize = 16
        static let lengthAndFlags = 0
        static let physicalBlock = 8
        static let valueSize = 16
        static let lengthMask: UInt64 = 0x00FF_FFFF_FFFF_FFFF
        static let sealedPrivateID = 0
        static let sealedLogicalAddress = 8
    }

    /// POSIX `st_mode` bits.
    enum Mode {
        static let typeMask: UInt16 = 0o170000
        static let permissionMask: UInt16 = 0o7777
        static let directory: UInt16 = 0o040000
        static let regular: UInt16 = 0o100000
        static let symlink: UInt16 = 0o120000
    }
}

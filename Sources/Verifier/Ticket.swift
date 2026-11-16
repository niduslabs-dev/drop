import DiskImage
import Foundation
import ReaderCore

/// A notarization ticket: Apple's signed list of the cdhashes it notarized.
///
/// The same bytes live in three places: a DMG's code signature (ticket slot), an app's
/// `Contents/CodeResources`, and Apple's CloudKit ticket service. The format isn't
/// documented; this layout was read from three tickets (Rectangle's DMG ticket, the one
/// `stapler staple` wrote into Rectangle.app, and Stats.app's) and matches all of them.
/// Little-endian throughout:
///
/// ```
/// s8ch  magic "s8ch", u32 version (1), u32 certificatesLength, u32 ticketLength
///       certificates (DER, certificatesLength bytes)
///       g8tk ticket (ticketLength bytes):
///           magic "g8tk", u16 version (2), u16 hashLength (20), u32 count, u32 reserved,
///           u64 issued (Unix seconds), then count × (u8 hashType, hashLength bytes)
///       signature over the ticket (DER ECDSA, zero padded to the end)
/// ```
///
/// Drop never checks the signature itself: Gatekeeper does at launch, and a forged
/// ticket would only fail there. Parsing the entries is what lets Drop refuse to staple a
/// ticket that doesn't name the app (the wrong app in the DMG, or a different build).
public struct NotarizationTicket: Sendable, Equatable {
    static let magic: [UInt8] = Array("s8ch".utf8)
    private static let ticketMagic: [UInt8] = Array("g8tk".utf8)
    private static let headerSize = 16
    private static let ticketHeaderSize = 24
    /// Real tickets are about 2 KB (Zed's, with dozens of nested binaries, is still small).
    /// The cap keeps a hostile DMG from making Drop parse or write megabytes.
    public static let maxSize = 1024 * 1024

    private enum Offset {
        static let certificatesLength = 8
        static let ticketLength = 12
        static let hashLength = 6
        static let count = 8
        static let issued = 16
    }

    /// The whole ticket, exactly as `stapler staple` writes it to `Contents/CodeResources`.
    public let bytes: [UInt8]
    /// Every cdhash the ticket lists: the app's slices, its nested code, and the DMG.
    public let entries: [CDHash]
    /// When Apple issued it.
    public let issued: Date

    /// Parses `bytes`; throws `ReaderError.corrupt` when they aren't a ticket this code
    /// understands (a new format version is treated the same: Drop then just doesn't staple).
    public init(bytes: [UInt8]) throws {
        guard bytes.count <= Self.maxSize else { throw ReaderError.corrupt("ticket is \(bytes.count) bytes") }
        let reader = ByteReader(bytes)
        guard try reader.slice(0, Self.magic.count) == Self.magic else { throw ReaderError.corrupt("no s8ch magic") }
        let certificates = Int(try reader.le32(Offset.certificatesLength))
        let ticketLength = Int(try reader.le32(Offset.ticketLength))
        let start = Self.headerSize + certificates
        guard try reader.slice(start, Self.ticketMagic.count) == Self.ticketMagic else {
            throw ReaderError.corrupt("no g8tk magic")
        }
        let hashLength = Int(try reader.le16(start + Offset.hashLength))
        let count = Int(try reader.le32(start + Offset.count))
        guard hashLength == CDHash.length, Self.ticketHeaderSize + count * (1 + hashLength) == ticketLength else {
            throw ReaderError.corrupt("ticket lists \(count) hashes of \(hashLength) bytes in \(ticketLength)")
        }
        _ = try reader.slice(start, ticketLength)

        var entries: [CDHash] = []
        entries.reserveCapacity(count)
        var offset = start + Self.ticketHeaderSize
        for _ in 0..<count {
            let type = try reader.u8(offset)
            entries.append(CDHash(hashType: type, bytes: try reader.slice(offset + 1, hashLength)))
            offset += 1 + hashLength
        }
        self.bytes = bytes
        self.entries = entries
        issued = Date(timeIntervalSince1970: TimeInterval(try reader.le64(start + Offset.issued)))
    }

    /// True when the ticket names any of `cdhashes` (same digest type and bytes).
    public func covers(_ cdhashes: [CDHash]) -> Bool {
        let listed = Set(entries)
        return cdhashes.contains(where: listed.contains)
    }
}

extension Verifier {
    /// The code signature SuperBlob (`CSMAGIC_EMBEDDED_SIGNATURE`) a DMG's `koly` trailer points to.
    static let superBlobMagic: UInt32 = 0xFADE_0CC0
    /// The wrapper blob a ticket is stored in (`CSMAGIC_BLOBWRAPPER`).
    static let blobWrapperMagic: UInt32 = 0xFADE_0B01
    /// The ticket's slot in the SuperBlob index: `CSSLOT_TICKETSLOT` in xnu's
    /// `osfmk/kern/cs_blobs.h`. Seen in every stapled DMG tested: alone in Rectangle's and
    /// KeePassXC's (stapled, not signed) and after the code directory, requirements and CMS
    /// slots in Clipy's (signed and stapled).
    static let ticketSlot: UInt32 = 0x10002
    /// Code signatures of DMGs are a few KB; anything far larger is not a signature.
    static let maxSignatureSize: UInt64 = 16 * 1024 * 1024

    private static let blobHeaderSize = 8
    private static let indexEntrySize = 8
    private static let superBlobHeaderSize = 12

    /// The ticket stapled to the DMG at `path`, or nil when it carries none.
    ///
    /// Reads only the `koly` trailer, the plist and the signature area: no decoding, no
    /// mount. Throws `ReaderError` when the image or its signature area is malformed.
    public static func ticket(fromDMG path: String) throws -> NotarizationTicket? {
        let image = try DiskImage.open(path: path)
        guard let area = image.codeSignature else { return nil }
        let file = try FileDevice(path: path)
        let (end, overflow) = area.offset.addingReportingOverflow(area.length)
        guard !overflow, end <= file.size, area.length <= maxSignatureSize else {
            throw ReaderError.corrupt("code signature area runs past the file")
        }
        return try ticket(inSuperBlob: try file.read(at: area.offset, count: Int(area.length)))
    }

    /// The ticket in a code signature SuperBlob, found through its index.
    static func ticket(inSuperBlob bytes: [UInt8]) throws -> NotarizationTicket? {
        let reader = ByteReader(bytes)
        guard try reader.be32(0) == superBlobMagic else { throw ReaderError.corrupt("no SuperBlob magic") }
        let length = Int(try reader.be32(4))
        let count = Int(try reader.be32(8))
        guard length <= bytes.count, count <= (length - superBlobHeaderSize) / indexEntrySize else {
            throw ReaderError.corrupt("SuperBlob index runs past its length")
        }
        for index in 0..<count {
            let entry = superBlobHeaderSize + index * indexEntrySize
            guard try reader.be32(entry) == ticketSlot else { continue }
            let offset = Int(try reader.be32(entry + 4))
            guard try reader.be32(offset) == blobWrapperMagic else {
                throw ReaderError.corrupt("ticket slot isn't a wrapper blob")
            }
            let blobLength = Int(try reader.be32(offset + 4))
            guard blobLength >= blobHeaderSize, offset + blobLength <= length else {
                throw ReaderError.corrupt("ticket blob runs past the SuperBlob")
            }
            return try NotarizationTicket(bytes: try reader.slice(offset + blobHeaderSize, blobLength - blobHeaderSize))
        }
        return nil
    }

    /// The ticket already stapled to `app`, or nil.
    public static func ticket(inApp app: URL) throws -> NotarizationTicket? {
        let url = ticketURL(app: app)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try NotarizationTicket(bytes: Array(data))
    }

    /// True when `ticket` names one of `cdhashes` (from `signingInfo(app:).cdhashes`).
    public static func ticketCovers(_ ticket: NotarizationTicket, _ cdhashes: [CDHash]) -> Bool {
        ticket.covers(cdhashes)
    }

    public enum StapleError: Error, Sendable, Equatable {
        /// The app already has a stapled ticket; Drop keeps the developer's.
        case alreadyStapled
        /// Something other than a ticket sits at `Contents/CodeResources` (very old apps
        /// have a symlink to their resource seal there). Writing would break the app.
        case pathOccupied
        /// The ticket doesn't list any of the app's cdhashes.
        case notCovered
        case unsigned
        case io(errno: Int32, context: String)
    }

    /// Permissions `stapler staple` gives `Contents/CodeResources` (checked on a copy of
    /// Rectangle.app: 0644, owner's uid, no extended attributes of its own).
    static let ticketFileMode: mode_t = 0o644

    /// Writes `ticket` into `app` as `Contents/CodeResources`, as `stapler staple` does,
    /// with no network.
    ///
    /// Only when the app has no ticket and nothing at that path, and the ticket lists one
    /// of the app's cdhashes. The file isn't part of the code signature's seal, so the
    /// signature stays valid. Atomic: written to a temporary file in `Contents`, synced,
    /// then renamed into place with `RENAME_EXCL`, so a crash leaves either no ticket or
    /// the whole ticket, and a ticket that appears meanwhile is never overwritten.
    /// Stapler always creates the file fresh, so there is no earlier mode to keep: the new
    /// file gets stapler's 0644 regardless of umask.
    public static func staple(_ ticket: NotarizationTicket, into app: URL) throws(StapleError) {
        let info: SigningInfo
        do { info = try signingInfo(app: app) } catch { throw .unsigned }
        guard info.kind != .unsigned else { throw .unsigned }
        let destination = ticketURL(app: app)
        var existing = stat()
        if lstat(destination.path, &existing) == 0 {
            // Code Signing reports whatever sits at the path as a stapled ticket, so look at
            // the file itself to tell a real ticket from, say, an old symlink to the seal.
            let isFile = existing.st_mode & S_IFMT == S_IFREG
            throw isFile && hasTicketFile(app: app) ? .alreadyStapled : .pathOccupied
        }
        if info.hasStapledTicket { throw .alreadyStapled }
        guard ticket.covers(info.cdhashes) else { throw .notCovered }
        try writeAtomically(ticket.bytes, to: destination)
    }

    private static func writeAtomically(_ bytes: [UInt8], to destination: URL) throws(StapleError) {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(destination.lastPathComponent).drop-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, ticketFileMode)
        guard fd >= 0 else { throw .io(errno: errno, context: "create \(temporary.path)") }
        var failure: StapleError?
        if fchmod(fd, ticketFileMode) != 0 { failure = .io(errno: errno, context: "fchmod") }
        var written = 0
        while failure == nil, written < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + written, bytes.count - written) }
            if n < 0 {
                if errno == EINTR { continue }
                failure = .io(errno: errno, context: "write \(temporary.path)")
            } else {
                written += n
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = .io(errno: errno, context: "fsync") }
        close(fd)
        if failure == nil, renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            failure = errno == EEXIST ? .pathOccupied : .io(errno: errno, context: "rename to \(destination.path)")
        }
        if let failure {
            unlink(temporary.path)
            throw failure
        }
    }
}

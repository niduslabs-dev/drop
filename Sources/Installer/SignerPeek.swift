import DMGReader
import Foundation
import ReaderCore
import Verifier

/// The fast signer read: who signed the app, read straight from the image right after the
/// app is identified, without staging it.
///
/// Code Signing reports signing information (the certificates, Team ID and cdhashes) from
/// the signature embedded in the main executable plus the bundle's `Info.plist`; it needs no
/// resources and no `_CodeSignature` folder when nothing is validated (checked against
/// Ghostty, IINA and Proxyman, 2026-11-26). So this writes a skeleton bundle into a small temp
/// folder: `Contents/Info.plist`, the main executable as a sparse file holding only its
/// Mach-O headers and code signature (a few hundred KB of a 45 MB binary), and the stapled
/// ticket (`Contents/CodeResources`) when the app has one. Then `Verifier.signingInfo` reads
/// it with no executable or resource hashing.
///
/// Nothing here decides whether to install: the full check on the staged copy still gates
/// that. A peek that can't read something returns nil and the panel waits for the full check.
enum SignerPeek {
    /// What the peek found.
    struct Result: Sendable, Equatable {
        var signing: SigningInfo
        /// A stapled ticket (in the app, or on the disk image) lists one of the app's cdhashes.
        var hasStapledTicket: Bool
    }

    /// Mach-O header plus load commands is a few KB; real apps stay far below this.
    static let maxHeaderSize = 1 << 20
    /// Fat binaries carry two or three slices; more than this is not an app.
    static let maxArchitectures = 16
    /// Where peek folders go; each read makes and deletes its own subfolder.
    static let defaultRoot = FileManager.default.temporaryDirectory.appending(
        path: "dev.niduslabs.drop.peek", directoryHint: .isDirectory)

    /// Reads `app`'s signer through `fileSystem` (the image's reader, or a hidden mount's).
    /// `dmgTicket` is the disk image's stapled ticket, if it has one. Leaves nothing behind.
    static func read(
        app: Entry, in fileSystem: any FileSystem, dmgTicket: NotarizationTicket?, root: URL = defaultRoot
    ) -> Result? {
        guard let info = BundleInfo.read(app: app, in: fileSystem), let executable = info.executable,
            !executable.contains("/"), executable != "..", executable != ".",
            let plist = try? fileSystem.lookup([app.name, "Contents", "Info.plist"]),
            let binary = try? fileSystem.lookup([app.name, "Contents", "MacOS", executable]),
            binary.kind == .file, !binary.isCompressed
        else { return nil }

        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = folder.appending(path: app.name, directoryHint: .isDirectory)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: contents.appending(path: "MacOS", directoryHint: .isDirectory), withIntermediateDirectories: true)
            try Data(try fileSystem.contents(of: plist)).write(to: contents.appending(path: "Info.plist"))
            try writeSparseExecutable(
                binary, from: fileSystem, to: contents.appending(path: "MacOS").appending(path: executable))
            if let ticket = try? fileSystem.lookup([app.name, "Contents", "CodeResources"]), ticket.kind == .file,
                ticket.size <= UInt64(NotarizationTicket.maxSize)
            {
                try Data(try fileSystem.contents(of: ticket)).write(to: contents.appending(path: "CodeResources"))
            }
        } catch {
            return nil
        }
        guard let signing = try? Verifier.signingInfo(app: bundle) else { return nil }
        let appTicket = (try? Verifier.ticket(inApp: bundle)) ?? nil
        let stapled = [appTicket, dmgTicket].contains { $0?.covers(signing.cdhashes) == true }
        return Result(signing: signing, hasStapledTicket: stapled)
    }

    /// Writes a file of `binary`'s size holding only the byte ranges Code Signing reads for
    /// signing information (`signatureRanges`); everything else is a hole.
    static func writeSparseExecutable(_ binary: Entry, from fileSystem: any FileSystem, to url: URL) throws {
        let ranges = try signatureRanges(size: binary.size) { offset, count in
            try readRange(of: binary, at: offset, count: count, in: fileSystem)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o755)
        guard fd >= 0 else { throw ReaderError.io(errno: errno, context: "create \(url.path)") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(binary.size)) == 0 else {
            throw ReaderError.io(errno: errno, context: "ftruncate \(url.path)")
        }
        for range in ranges {
            let bytes = try readRange(of: binary, at: range.offset, count: range.count, in: fileSystem)
            let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, off_t(range.offset)) }
            guard written == bytes.count else { throw ReaderError.io(errno: errno, context: "write \(url.path)") }
        }
    }

    struct ByteRange: Sendable, Equatable {
        var offset: UInt64
        var count: Int
    }

    private enum MachO {
        static let fatMagic: UInt32 = 0xCAFE_BABE
        static let fatMagic64: UInt32 = 0xCAFE_BABF
        static let magic32: UInt32 = 0xFEED_FACE
        static let magic64: UInt32 = 0xFEED_FACF
        static let fatHeaderSize = 8
        static let fatArchSize = 20
        static let fatArch64Size = 32
        static let headerSize32 = 28
        static let headerSize64 = 32
        static let loadCommandHeader = 8
        /// `LC_CODE_SIGNATURE`: a `linkedit_data_command` whose data is the embedded signature.
        static let codeSignature: UInt32 = 0x1D
    }

    /// The byte ranges of a Mach-O (thin or fat) executable that hold its headers, load
    /// commands and embedded code signatures: all signing information is read from these.
    /// `read` fetches bytes of the file. Throws `ReaderError.corrupt` for anything that isn't
    /// a Mach-O this understands, or whose ranges run past `size`.
    static func signatureRanges(size: UInt64, read: (UInt64, Int) throws -> [UInt8]) throws -> [ByteRange] {
        func check(_ range: ByteRange) throws -> ByteRange {
            let (end, overflow) = range.offset.addingReportingOverflow(UInt64(range.count))
            guard !overflow, end <= size else { throw ReaderError.corrupt("Mach-O range runs past the file") }
            return range
        }
        let head = ByteReader(try read(0, min(MachO.fatHeaderSize, Int(clamping: size))))
        let magic = try head.be32(0)
        guard magic == MachO.fatMagic || magic == MachO.fatMagic64 else {
            return try thinRanges(at: 0, size: size, read: read).map(check)
        }
        let count = Int(try head.be32(4))
        guard count > 0, count <= maxArchitectures else { throw ReaderError.corrupt("\(count) architectures") }
        let entrySize = magic == MachO.fatMagic64 ? MachO.fatArch64Size : MachO.fatArchSize
        let tableSize = MachO.fatHeaderSize + count * entrySize
        let table = ByteReader(try read(0, tableSize))
        var ranges = [try check(ByteRange(offset: 0, count: tableSize))]
        for index in 0..<count {
            let entry = MachO.fatHeaderSize + index * entrySize
            let offset = magic == MachO.fatMagic64 ? try table.be64(entry + 8) : UInt64(try table.be32(entry + 8))
            ranges += try thinRanges(at: offset, size: size, read: read).map(check)
        }
        return ranges
    }

    private static func thinRanges(at base: UInt64, size: UInt64, read: (UInt64, Int) throws -> [UInt8]) throws
        -> [ByteRange]
    {
        guard base < size else { throw ReaderError.corrupt("slice starts past the file") }
        let first = ByteReader(try read(base, min(MachO.headerSize64, Int(clamping: size - base))))
        let magic = try first.le32(0)
        guard magic == MachO.magic32 || magic == MachO.magic64 else { throw ReaderError.corrupt("not a Mach-O") }
        let headerSize = magic == MachO.magic64 ? MachO.headerSize64 : MachO.headerSize32
        let commandCount = Int(try first.le32(16))
        let commandsSize = Int(try first.le32(20))
        let total = headerSize + commandsSize
        guard total <= maxHeaderSize else { throw ReaderError.corrupt("load commands of \(commandsSize) bytes") }
        let header = ByteReader(try read(base, total))
        var ranges = [ByteRange(offset: base, count: total)]
        var offset = headerSize
        for _ in 0..<commandCount {
            let command = try header.le32(offset)
            let length = Int(try header.le32(offset + 4))
            guard length >= MachO.loadCommandHeader else { throw ReaderError.corrupt("load command of \(length)") }
            if command == MachO.codeSignature {
                let dataOffset = UInt64(try header.le32(offset + 8))
                let dataSize = Int(try header.le32(offset + 12))
                guard UInt64(dataSize) <= Verifier.maxSignatureSize else {
                    throw ReaderError.corrupt("code signature of \(dataSize) bytes")
                }
                ranges.append(ByteRange(offset: base + dataOffset, count: dataSize))
            }
            offset += length
        }
        return ranges
    }

    /// `count` bytes of `file` from `offset`, across extents, with holes as zeros.
    static func readRange(of file: Entry, at offset: UInt64, count: Int, in fileSystem: any FileSystem) throws
        -> [UInt8]
    {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
        guard !overflow, end <= file.size else { throw ReaderError.corrupt("read past the end of \(file.name)") }
        var out = [UInt8](repeating: 0, count: count)
        for extent in try fileSystem.extents(of: file) where !extent.isHole {
            let start = max(extent.fileOffset, offset)
            let stop = min(extent.fileOffset + extent.length, end)
            guard start < stop else { continue }
            try out.withUnsafeMutableBytes { all in
                let window = UnsafeMutableRawBufferPointer(
                    rebasing: all[Int(start - offset)..<Int(stop - offset)])
                try fileSystem.readData(of: file, in: extent, at: start, into: window)
            }
        }
        return out
    }
}

import CryptoKit
import Foundation
import ReaderCore
import Testing

@testable import APFS

/// Locations of the images and manifests that `scripts/fixtures-apfs.sh` writes.
enum Fixtures {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let directory = packageRoot.appendingPathComponent(".build/fixtures/apfs")

    struct Missing: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "APFS fixture missing: \(path). Run scripts/fixtures-apfs.sh (add --corpus for the corpus tests)."
        }
    }

    static func path(_ name: String) throws -> String {
        let path = directory.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else { throw Missing(path: path) }
        return path
    }

    static func manifest(_ name: String) throws -> [[UInt8]: ManifestRow] {
        let text = try String(contentsOfFile: try path(name), encoding: .utf8)
        var rows: [[UInt8]: ManifestRow] = [:]
        for line in text.split(separator: "\n") {
            let row = try JSONDecoder().decode(ManifestRow.self, from: Data(line.utf8))
            rows[Array(row.path.utf8)] = row
        }
        return rows
    }

    static var corpusEnabled: Bool { ProcessInfo.processInfo.environment["DROP_CORPUS"] == "1" }
    static var timingEnabled: Bool { ProcessInfo.processInfo.environment["DROP_TIMING"] == "1" }
}

/// One line of a fixture manifest: an item as macOS reports it on the mounted image.
struct ManifestRow: Decodable {
    struct Xattr: Decodable {
        let size: Int
        let sha256: String
    }

    let path: String
    let kind: String
    let mode: UInt16
    let size: UInt64
    let flags: UInt32
    let nlink: Int
    let ino: UInt64
    let xattrs: [String: Xattr]
    let sha256: String?
    let target: String?

    static let compressedFlag: UInt32 = 0x20
    var isCompressed: Bool { flags & Self.compressedFlag != 0 }
}

/// Finds the APFS container inside a raw GPT disk (as `hdiutil convert -format UDTO`
/// writes it): the partition whose first sector carries `NXSB` at byte 32.
func apfsPartition(of disk: any BlockDevice) throws -> SliceDevice {
    let sector: UInt64 = 512
    let header = ByteReader(try disk.read(at: sector, count: Int(sector)))
    guard try header.slice(0, 8) == Array("EFI PART".utf8) else {
        throw ReaderError.unsupportedPartitionScheme("no GPT header")
    }
    let entriesLBA = try header.le64(72)
    let entryCount = Int(try header.le32(80))
    let entrySize = Int(try header.le32(84))
    let table = ByteReader(try disk.read(at: entriesLBA * sector, count: entryCount * entrySize))
    for index in 0..<entryCount {
        let base = index * entrySize
        let first = try table.le64(base + 32)
        let last = try table.le64(base + 40)
        guard first != 0, last >= first else { continue }
        let magic = ByteReader(try disk.read(at: first * sector + 32, count: 4))
        if try magic.le32(0) == Format.Container.magicValue {
            return try SliceDevice(base: disk, start: first * sector, size: (last - first + 1) * sector)
        }
    }
    throw ReaderError.unsupportedFileSystem("no APFS partition")
}

/// Every entry under the root, keyed by its path's UTF-8 bytes (names compared exactly,
/// not by canonical equivalence).
func walk(_ fs: any FileSystem) throws -> [[UInt8]: Entry] {
    var result: [[UInt8]: Entry] = [:]
    func visit(_ directory: Entry, prefix: [UInt8]) throws {
        for child in try fs.children(of: directory) {
            let path = prefix.isEmpty ? Array(child.name.utf8) : prefix + [UInt8(ascii: "/")] + Array(child.name.utf8)
            result[path] = child
            if child.kind == .directory { try visit(child, prefix: path) }
        }
    }
    try visit(try fs.root, prefix: [])
    return result
}

func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// Runs `body` and requires it to throw `ReaderError.corrupt`.
func expectCorrupt(_ comment: Comment, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected corrupt, got success: \(comment)")
    } catch let error as ReaderError {
        guard case .corrupt = error else {
            Issue.record("expected corrupt, got \(error): \(comment)")
            return
        }
    } catch {
        Issue.record("expected ReaderError.corrupt, got \(error): \(comment)")
    }
}

extension Array where Element == UInt8 {
    mutating func storeLE64(_ value: UInt64, at offset: Int) {
        for byte in 0..<8 { self[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(byte))) }
    }
}

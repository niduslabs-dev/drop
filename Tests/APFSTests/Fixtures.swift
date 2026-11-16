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
            "APFS fixture missing: \(path). Run scripts/fixtures-apfs.sh."
        }
    }

    /// The first `.dmg` in `.claude/samples/<name>/`, the untrusted real-app corpus.
    static func sample(_ name: String) throws -> String {
        let folder = packageRoot.appendingPathComponent(".claude/samples/\(name)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let dmg = files.sorted().first(where: { $0.hasSuffix(".dmg") }) else {
            throw Missing(path: folder.path)
        }
        return folder.appendingPathComponent(dmg).path
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

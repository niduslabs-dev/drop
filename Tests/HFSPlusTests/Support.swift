import CryptoKit
import Foundation
import ReaderCore
import Testing

@testable import HFSPlus

/// Where `scripts/fixtures-hfsplus.sh` puts its output.
enum Fixtures {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let directory = packageRoot.appendingPathComponent(".build/fixtures/hfsplus")

    static let missingMessage: Comment =
        "HFS+ fixtures missing: run scripts/fixtures-hfsplus.sh from the package root first"

    /// The first `.dmg` in `.claude/samples/<name>/`, the untrusted real-app corpus.
    static func sample(_ name: String) throws -> String {
        let folder = packageRoot.appendingPathComponent(".claude/samples/\(name)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let dmg = files.sorted().first(where: { $0.hasSuffix(".dmg") }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        return folder.appendingPathComponent(dmg).path
    }

    static func path(_ name: String) throws -> String {
        let path = directory.appendingPathComponent(name).path
        try #require(FileManager.default.fileExists(atPath: path), missingMessage)
        return path
    }

    static func volume(_ name: String) throws -> HFSPlusVolume {
        try HFSPlusVolume(device: try FileDevice(path: try path("\(name).cdr")))
    }

    static func manifest(_ name: String) throws -> [String: ManifestEntry] {
        let text = try String(contentsOfFile: try path("manifest-\(name).jsonl"), encoding: .utf8)
        var entries: [String: ManifestEntry] = [:]
        for line in text.split(separator: "\n") {
            let entry = try JSONDecoder().decode(ManifestEntry.self, from: Data(line.utf8))
            entries[entry.path] = entry
        }
        return entries
    }
}

/// One line of a fixture manifest: what the kernel showed for a path with the volume mounted.
struct ManifestEntry: Decodable {
    let path: String
    let kind: String
    let mode: UInt16
    let size: UInt64?
    let sha256: String?
    let target: String?
    let xattrs: [String]
    let compressed: Bool
    let nlink: Int
    let ino: UInt64
}

/// Every entry under the root, keyed by its slash-joined path.
func walk(_ volume: some FileSystem, limit: Int = 1_000_000) throws -> [(path: String, entry: Entry)] {
    var out: [(String, Entry)] = []
    var stack: [(String, Entry)] = [("", try volume.root)]
    while let (prefix, directory) = stack.popLast() {
        for child in try volume.children(of: directory) {
            let path = prefix.isEmpty ? child.name : prefix + "/" + child.name
            out.append((path, child))
            guard out.count <= limit else { throw ReaderError.corrupt("walk exceeded \(limit) entries") }
            if child.kind == .directory { stack.append((path, child)) }
        }
    }
    return out
}

func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// Reads an xattr's bytes whether stored inline or in extents.
func xattrBytes(_ value: XattrValue, device: any BlockDevice) throws -> [UInt8] {
    switch value {
    case .inline(let bytes): return bytes
    case .extents(let extents, let size):
        var out: [UInt8] = []
        for extent in extents where UInt64(out.count) < size {
            let count = Int(min(extent.length, size - UInt64(out.count)))
            out += try device.read(at: extent.deviceOffset, count: count)
        }
        return out
    }
}

func isCorrupt(_ error: any Error) -> Bool {
    if case .corrupt = error as? ReaderError { return true }
    return false
}

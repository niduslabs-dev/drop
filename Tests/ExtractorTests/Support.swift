import CryptoKit
import Foundation
import ReaderCore
import Synchronization
import Testing

@testable import Extractor

/// The package root, from this file's path.
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A fresh folder under `.build/extractor-tests/`, never in /Applications or the Trash.
func scratchFolder(_ label: String) throws -> URL {
    let url = packageRoot.appendingPathComponent(".build/extractor-tests/\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A path compared byte for byte: `String` equality would merge NFC and NFD spellings.
struct BytePath: Hashable, CustomStringConvertible, Comparable {
    let bytes: [UInt8]
    init(_ string: String) { bytes = Array(string.utf8) }
    var description: String { String(decoding: bytes, as: UTF8.self) }
    static func < (a: BytePath, b: BytePath) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }
}

/// What an item on disk looks like, read without following symlinks.
struct DiskItem {
    enum Kind: String { case directory, file, symlink, other }
    let kind: Kind
    let mode: UInt16
    let size: UInt64
    let sha256: String?
    let target: String?
    let xattrs: [String: [UInt8]]
    let inode: UInt64
    let nlink: UInt16
    let mtime: timespec
    let crtime: timespec
    let blocks: Int64
}

/// Every item under `root` (not `root` itself), keyed by its path relative to `root`.
func snapshot(_ root: URL) throws -> [BytePath: DiskItem] {
    var out: [BytePath: DiskItem] = [:]
    func visit(_ path: String, _ relative: String) throws {
        let dir = try #require(opendir(path), "opendir \(path)")
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        for name in names {
            let full = path + "/" + name
            let rel = relative.isEmpty ? name : relative + "/" + name
            let item = try diskItem(full)
            out[BytePath(rel)] = item
            if item.kind == .directory { try visit(full, rel) }
        }
    }
    try visit(root.path, "")
    return out
}

func diskItem(_ path: String) throws -> DiskItem {
    var info = stat()
    try #require(lstat(path, &info) == 0, "lstat \(path)")
    let kind: DiskItem.Kind =
        switch info.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .file
        case S_IFLNK: .symlink
        default: .other
        }
    var digest: String?
    if kind == .file {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    var target: String?
    if kind == .symlink {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        target = String(decoding: buffer.prefix(max(count, 0)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    return DiskItem(
        kind: kind, mode: UInt16(info.st_mode & 0o7777), size: kind == .file ? UInt64(info.st_size) : 0,
        sha256: digest, target: target, xattrs: try readXattrs(path), inode: info.st_ino, nlink: info.st_nlink,
        mtime: info.st_mtimespec, crtime: info.st_birthtimespec, blocks: info.st_blocks)
}

/// The kernel tags every file a process writes with `com.apple.provenance`, so extracted
/// items always carry it; it isn't part of what the extractor copies.
let kernelAddedXattrs: Set<String> = ["com.apple.provenance"]

func readXattrs(_ path: String) throws -> [String: [UInt8]] {
    let options = XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION
    let size = listxattr(path, nil, 0, options)
    guard size > 0 else { return [:] }
    var names = [CChar](repeating: 0, count: size)
    let got = listxattr(path, &names, size, options)
    var out: [String: [UInt8]] = [:]
    for raw in names.prefix(max(got, 0)).split(separator: 0) {
        let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if kernelAddedXattrs.contains(name) { continue }
        let length = getxattr(path, name, nil, 0, 0, options)
        var value = [UInt8](repeating: 0, count: max(length, 0))
        let read = getxattr(path, name, &value, value.count, 0, options)
        out[name] = Array(value.prefix(max(read, 0)))
    }
    return out
}

func sha256Hex(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// Discards and waits for the delete, so the test process doesn't exit with it half done.
func discardAndWait(_ staged: StagedApp) { discardAndWait(staged.area) }

func discardAndWait(_ area: StagingArea) {
    let done = DispatchSemaphore(value: 0)
    Extractor.discard(area) { done.signal() }
    #expect(done.wait(timeout: .now() + 60) == .success, "discard took over 60 s")
}

/// Waits for `discard`'s background delete, with a deadline so a hang fails instead.
func waitForDiscard(_ area: StagingArea, timeout: TimeInterval = 20) -> Bool {
    let aside = area.url.deletingLastPathComponent()
        .appendingPathComponent(Extractor.discardedPrefix + area.url.lastPathComponent)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !exists(aside) && !exists(area.url) { return true }
        usleep(20_000)
    }
    return false
}

// MARK: - Filesystems for tests

/// Presents another filesystem's root as an app folder named `rootName`, minus
/// `hiddenRootNames`, so a whole fixture volume can be staged in one go.
struct RootAsApp: FileSystem {
    let base: any FileSystem
    let rootName: String
    let hiddenRootNames: Set<String>

    var kind: String { base.kind }
    var volumeName: String { base.volumeName }
    var device: any BlockDevice { base.device }
    var root: Entry {
        get throws {
            let real = try base.root
            return Entry(
                id: real.id, name: rootName, kind: .directory, mode: real.mode, size: 0,
                modificationTime: real.modificationTime, creationTime: real.creationTime)
        }
    }
    func children(of directory: Entry) throws -> [Entry] {
        let all = try base.children(of: directory)
        return directory.id == (try base.root.id) ? all.filter { !hiddenRootNames.contains($0.name) } : all
    }
    func extents(of file: Entry) throws -> [Extent] { try base.extents(of: file) }
    func symlinkTarget(of link: Entry) throws -> String { try base.symlinkTarget(of: link) }
    func xattrs(of entry: Entry) throws -> [String: XattrValue] { try base.xattrs(of: entry) }
}

/// A tiny in-memory filesystem whose contents a test controls completely, including
/// names and kinds no real volume would hold.
struct FakeFileSystem: FileSystem {
    struct Node: Sendable {
        var entry: Entry
        var children: [Entry] = []
        var extents: [Extent] = []
        var target = ""
        var xattrs: [String: XattrValue] = [:]
    }

    final class Calls: Sendable {
        let xattrs = Atomic<Int>(0)
        let extents = Atomic<Int>(0)
    }

    let nodes: [UInt64: Node]
    let device: any BlockDevice
    let calls = Calls()
    var kind: String { "Fake" }
    var volumeName: String { "Fake" }
    var root: Entry { get throws { try node(FakeBuilder.rootID).entry } }

    func node(_ id: UInt64) throws -> Node {
        guard let node = nodes[id] else { throw ReaderError.corrupt("no node \(id)") }
        return node
    }
    func children(of directory: Entry) throws -> [Entry] {
        guard directory.kind == .directory else { throw ReaderError.notADirectory }
        return try node(directory.id).children
    }
    func extents(of file: Entry) throws -> [Extent] {
        calls.extents.add(1, ordering: .relaxed)
        return try node(file.id).extents
    }
    func symlinkTarget(of link: Entry) throws -> String { try node(link.id).target }
    func xattrs(of entry: Entry) throws -> [String: XattrValue] {
        calls.xattrs.add(1, ordering: .relaxed)
        return try node(entry.id).xattrs
    }
}

/// Builds a `FakeFileSystem`: a root folder holding `App.app` (returned by `app`).
final class FakeBuilder {
    static let rootID: UInt64 = 1
    private var nodes: [UInt64: FakeFileSystem.Node] = [:]
    private var data: [UInt8] = []
    private var nextID: UInt64 = 2
    private(set) var app: Entry

    init(appName: String = "App.app") {
        nodes[Self.rootID] = .init(entry: Entry(id: Self.rootID, name: "", kind: .directory, mode: 0o755, size: 0))
        app = Entry(id: 0, name: appName, kind: .directory, mode: 0o755, size: 0)
        app = directory(appName, in: Self.rootID)
    }

    var appID: UInt64 { app.id }

    @discardableResult
    func directory(
        _ name: String, in parent: UInt64? = nil, mode: UInt16 = 0o755, time: Entry.Timestamp? = nil,
        created: Entry.Timestamp? = nil
    ) -> Entry {
        add(
            Entry(
                id: newID(), name: name, kind: .directory, mode: mode, size: 0, modificationTime: time,
                creationTime: created), parent)
    }

    @discardableResult
    func file(
        _ name: String, in parent: UInt64? = nil, contents: [UInt8], mode: UInt16 = 0o644,
        xattrs: [String: XattrValue] = [:], time: Entry.Timestamp? = nil, created: Entry.Timestamp? = nil,
        compressed: Bool = false
    ) -> Entry {
        let entry = Entry(
            id: newID(), name: name, kind: .file, mode: mode, size: UInt64(contents.count),
            isCompressed: compressed, modificationTime: time, creationTime: created)
        var node = FakeFileSystem.Node(entry: entry, xattrs: xattrs)
        if !contents.isEmpty {
            node.extents = [Extent(fileOffset: 0, deviceOffset: UInt64(data.count), length: UInt64(contents.count))]
            data += contents
        }
        return add(node, parent)
    }

    /// Bytes stored on the fake device, for xattrs that come as extents.
    func store(_ bytes: [UInt8]) -> Extent {
        defer { data += bytes }
        return Extent(fileOffset: 0, deviceOffset: UInt64(data.count), length: UInt64(bytes.count))
    }

    /// A second name for an existing file, as a hard link. Marks both names `isHardLink`.
    func hardLink(_ name: String, to file: Entry, in parent: UInt64? = nil) {
        let linked = { (name: String) in
            Entry(
                id: file.id, name: name, kind: .file, mode: file.mode, size: file.size, isHardLink: true,
                modificationTime: file.modificationTime, creationTime: file.creationTime)
        }
        for (id, node) in nodes {
            nodes[id]?.children = node.children.map { $0.id == file.id ? linked($0.name) : $0 }
        }
        nodes[parent ?? appID]?.children.append(linked(name))
    }

    @discardableResult
    func symlink(
        _ name: String, in parent: UInt64? = nil, target: String, time: Entry.Timestamp? = nil,
        created: Entry.Timestamp? = nil
    ) -> Entry {
        var node = FakeFileSystem.Node(
            entry: Entry(
                id: newID(), name: name, kind: .symlink, mode: 0o755, size: 0, modificationTime: time,
                creationTime: created))
        node.target = target
        return add(node, parent)
    }

    @discardableResult
    func other(_ name: String, in parent: UInt64? = nil) -> Entry {
        add(Entry(id: newID(), name: name, kind: .other, mode: 0o644, size: 0), parent)
    }

    func build() -> FakeFileSystem {
        FakeFileSystem(nodes: nodes, device: MemoryDevice(data))
    }

    private func newID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }

    private func add(_ entry: Entry, _ parent: UInt64?) -> Entry {
        add(FakeFileSystem.Node(entry: entry), parent)
    }

    private func add(_ node: FakeFileSystem.Node, _ parent: UInt64?) -> Entry {
        nodes[node.entry.id] = node
        nodes[parent ?? appID]?.children.append(node.entry)
        return node.entry
    }
}

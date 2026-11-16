import DMGReader
import Foundation
import Synchronization
import Testing

@testable import Extractor

private let dmgQuarantine = "0083;6734abcd;Helium;1B2C3D4E-0000-4000-8000-123456789ABC"

/// Stages `app` from `fileSystem` into a new scratch destination.
private func stageFake(
    _ fileSystem: any FileSystem, app: Entry, options: StageOptions = StageOptions(), label: String = "fake"
) throws -> (StagedApp, URL) {
    let destination = try scratchFolder(label)
    let area = try Extractor.makeStagingArea(for: destination)
    return (try Extractor.stage(app: app, from: fileSystem, into: area, options: options), destination)
}

// MARK: - Quarantine

@Suite struct QuarantineTests {
    @Test func flagMath() throws {
        let staged = try Quarantine.staged(from: dmgQuarantine)
        #expect(staged == "0183;6734abcd;Helium;1B2C3D4E-0000-4000-8000-123456789ABC")
        let approved = try Quarantine.adding(Quarantine.userApprovedFlag, to: staged)
        #expect(approved == "01c3;6734abcd;Helium;1B2C3D4E-0000-4000-8000-123456789ABC")
        #expect(try Quarantine.staged(from: "0001") == "0101")
        #expect(try Quarantine.staged(from: "0183;x;;") == "0183;x;;")
    }

    @Test(arguments: ["", "83;a;b", "zz83;a", "00083;a", ";a;b"])
    func invalidValuesThrow(_ raw: String) {
        #expect(throws: ExtractorError.invalidQuarantine(raw)) { try Quarantine.staged(from: raw) }
    }

    private func sampleApp() -> (FakeFileSystem, Entry) {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        builder.file("Info.plist", in: contents.id, contents: Array("plist".utf8))
        builder.file("readonly.txt", in: contents.id, contents: [1, 2, 3], mode: 0o444)
        let locked = builder.directory("Locked", in: contents.id, mode: 0o555)
        let inner = builder.file("inner", in: locked.id, contents: [9], mode: 0o444)
        builder.hardLink("inner-link", to: inner, in: contents.id)
        builder.symlink("Current", in: contents.id, target: "Locked")
        builder.symlink("dangling", in: contents.id, target: "/nowhere/at/all")
        builder.file("empty", in: contents.id, contents: [])
        return (builder.build(), builder.app)
    }

    @Test func everyItemCarriesIt() throws {
        let (fileSystem, app) = sampleApp()
        let (staged, _) = try stageFake(fileSystem, app: app, options: StageOptions(quarantine: dmgQuarantine))
        defer { discardAndWait(staged) }
        let expected = Array(try Quarantine.staged(from: dmgQuarantine).utf8)
        var items = try snapshot(staged.url)
        items[BytePath("")] = try diskItem(staged.url.path)
        #expect(items.count == 10)
        for (path, item) in items {
            #expect(item.xattrs[Quarantine.attributeName] == expected, "\(path)")
        }

        try Extractor.markApproved(staged)
        let approved = Array("01c3;6734abcd;Helium;1B2C3D4E-0000-4000-8000-123456789ABC".utf8)
        var after = try snapshot(staged.url)
        after[BytePath("")] = try diskItem(staged.url.path)
        for (path, item) in after {
            #expect(item.xattrs[Quarantine.attributeName] == approved, "\(path)")
            #expect(item.mode == items[path]?.mode, "\(path) mode changed")
        }
    }

    @Test func noSourceValueWritesNone() throws {
        let (fileSystem, app) = sampleApp()
        let (staged, _) = try stageFake(fileSystem, app: app)
        defer { discardAndWait(staged) }
        for (path, item) in try snapshot(staged.url) {
            #expect(item.xattrs[Quarantine.attributeName] == nil, "\(path)")
        }
        #expect(try diskItem(staged.url.path).xattrs.isEmpty)
    }
}

// MARK: - What gets written

@Suite struct WriteTests {
    @Test func modesXattrsTimesAndLinks() throws {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents", time: .init(seconds: 1_600_000_000, nanoseconds: 123_456_789))
        let resourceFork = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let finderInfo =
            [UInt8](repeating: 0, count: 16) + [0, 0, 0, 0, 0x65, 0x43, 0x21, 0] + [UInt8](repeating: 0, count: 8)
        let bigExtent = builder.store(resourceFork)
        let file = builder.file(
            "tool", in: contents.id, contents: Array("#!/bin/sh\n".utf8), mode: 0o6755,
            xattrs: [
                "com.apple.ResourceFork": .extents([bigExtent], size: UInt64(resourceFork.count)),
                "com.apple.FinderInfo": .inline(finderInfo),
                "com.apple.cs.CodeSignature": .inline([1, 2, 3]),
                "com.example.empty": .inline([]),
                "com.apple.quarantine": .inline(Array("0083;0;x;y".utf8)),
                "com.apple.provenance": .inline([1]),
                "com.apple.macl": .inline([1]),
                "com.apple.rootless": .inline([1]),
                "com.apple.decmpfs": .inline([1]),
                "com.apple.system.Security": .inline([1]),
            ],
            time: .init(seconds: 1_500_000_000, nanoseconds: 42))
        builder.hardLink("tool-link", to: file, in: builder.appID)
        builder.directory("Sticky", in: contents.id, mode: 0o1777)
        builder.symlink("link", in: contents.id, target: "tool", time: .init(seconds: 1_400_000_000))
        let (staged, _) = try stageFake(builder.build(), app: builder.app)
        defer { discardAndWait(staged) }
        let items = try snapshot(staged.url)

        let tool = try #require(items[BytePath("Contents/tool")])
        #expect(tool.mode == 0o755)
        #expect(
            Set(tool.xattrs.keys)
                == [
                    "com.apple.ResourceFork", "com.apple.FinderInfo", "com.apple.cs.CodeSignature", "com.example.empty",
                ])
        #expect(tool.xattrs["com.apple.ResourceFork"] == resourceFork)
        #expect(tool.xattrs["com.apple.FinderInfo"] == finderInfo)
        #expect(tool.xattrs["com.example.empty"] == [])
        #expect(tool.mtime.tv_sec == 1_500_000_000 && tool.mtime.tv_nsec == 42)
        #expect(tool.nlink == 2)
        #expect(items[BytePath("tool-link")]?.inode == tool.inode)
        #expect(items[BytePath("Contents/Sticky")]?.mode == 0o777)
        let link = try #require(items[BytePath("Contents/link")])
        #expect(link.kind == .symlink && link.target == "tool")
        #expect(link.mtime.tv_sec == 1_400_000_000)
        let dir = try #require(items[BytePath("Contents")])
        #expect(dir.mtime.tv_sec == 1_600_000_000 && dir.mtime.tv_nsec == 123_456_789)
        var owner = stat()
        stat(staged.url.appendingPathComponent("Contents/tool").path, &owner)
        #expect(owner.st_uid == getuid())
    }

    /// Creation times land on files, folders and symlinks, including ones later than the
    /// mtime, which a separate `utimes` could drag back to it.
    @Test func creationTimes() throws {
        let early = Entry.Timestamp(seconds: 1_300_000_000, nanoseconds: 5)
        let late = Entry.Timestamp(seconds: 1_700_000_000, nanoseconds: 987_654_321)
        let middle = Entry.Timestamp(seconds: 1_500_000_000)
        let builder = FakeBuilder()
        let contents = builder.directory("Contents", mode: 0o555, time: middle, created: early)
        builder.file("newer-created", in: contents.id, contents: [1], mode: 0o444, time: middle, created: late)
        builder.file("older-created", in: contents.id, contents: [2], time: middle, created: early)
        builder.file("created-only", in: contents.id, contents: [3], created: early)
        builder.file("neither", in: contents.id, contents: [4])
        builder.symlink("link", in: contents.id, target: "neither", time: middle, created: late)
        let started = time(nil)
        let (staged, _) = try stageFake(builder.build(), app: builder.app)
        defer { discardAndWait(staged) }
        let items = try snapshot(staged.url)
        func check(_ path: String, created: Entry.Timestamp, modified: Entry.Timestamp?) throws {
            let item = try #require(items[BytePath(path)], "\(path) missing")
            #expect(
                item.crtime.tv_sec == created.seconds && item.crtime.tv_nsec == Int(created.nanoseconds),
                "\(path) crtime \(item.crtime)")
            if let modified {
                #expect(
                    item.mtime.tv_sec == modified.seconds && item.mtime.tv_nsec == Int(modified.nanoseconds),
                    "\(path) mtime \(item.mtime)")
            }
        }
        try check("Contents", created: early, modified: middle)
        try check("Contents/newer-created", created: late, modified: middle)
        try check("Contents/older-created", created: early, modified: middle)
        try check("Contents/created-only", created: early, modified: nil)
        try check("Contents/link", created: late, modified: middle)
        #expect(items[BytePath("Contents/newer-created")]?.mode == 0o444)
        #expect(items[BytePath("Contents")]?.mode == 0o555)
        let neither = try #require(items[BytePath("Contents/neither")])
        #expect(neither.crtime.tv_sec >= started - 1, "a missing creation time keeps the write time")
    }

    @Test func progressReachesTotal() throws {
        let builder = FakeBuilder()
        for index in 0..<20 {
            builder.file("f\(index)", contents: [UInt8](repeating: UInt8(index), count: 1000 * index))
        }
        let last = Mutex<StageProgress?>(nil)
        let destination = try scratchFolder("progress")
        let area = try Extractor.makeStagingArea(for: destination)
        let staged = try Extractor.stage(
            app: builder.app, from: builder.build(), into: area, options: StageOptions(bufferSize: 4096)
        ) { progress in last.withLock { $0 = progress } }
        defer { discardAndWait(staged) }
        let total = UInt64((0..<20).reduce(0) { $0 + 1000 * $1 })
        #expect(last.withLock { $0 } == StageProgress(bytesDone: total, bytesTotal: total))
    }

    @Test func stagingIsOnTheDestinationVolume() throws {
        let destination = try scratchFolder("volume")
        let area = try Extractor.makeStagingArea(for: destination)
        defer { discardAndWait(area) }
        var a = stat()
        var b = stat()
        stat(destination.path, &a)
        stat(area.url.path, &b)
        #expect(a.st_dev == b.st_dev)
        #expect(area.url.lastPathComponent.hasSuffix(".noindex"))
    }
}

// MARK: - Hostile input

@Suite struct HostileInputTests {
    /// Stages and expects `error`; the area must be gone and `outside` untouched.
    private func expectRejected(
        _ fileSystem: FakeFileSystem, app: Entry, outside: URL? = nil, _ check: (any Error) -> Bool
    ) throws {
        let destination = try scratchFolder("hostile")
        let area = try Extractor.makeStagingArea(for: destination)
        var thrown: (any Error)?
        do {
            _ = try Extractor.stage(app: app, from: fileSystem, into: area)
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "staging should have failed")
        #expect(check(error), "unexpected \(error)")
        #expect(!exists(area.url), "staging area left behind")
        #expect(waitForDiscard(area))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        if let outside {
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "wrote outside staging")
        }
    }

    private static func isCorrupt(_ error: any Error) -> Bool {
        if case ReaderError.corrupt = error { return true }
        return false
    }

    @Test(arguments: ["..", ".", "", "a/b", "a\u{0}b", "../../escape"])
    func unsafeNamesAreCorrupt(_ name: String) throws {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        builder.file(name, in: contents.id, contents: [1])
        try expectRejected(builder.build(), app: builder.app, Self.isCorrupt)
    }

    @Test(arguments: ["..", "a/b"])
    func unsafeAppNamesAreCorrupt(_ name: String) throws {
        let builder = FakeBuilder(appName: name)
        builder.file("x", contents: [1])
        try expectRejected(builder.build(), app: builder.app, Self.isCorrupt)
    }

    @Test func devicesAndSocketsAreCorrupt() throws {
        let builder = FakeBuilder()
        builder.other("fifo")
        try expectRejected(builder.build(), app: builder.app, Self.isCorrupt)
    }

    @Test func compressedFileFailsBeforeWritingAnything() throws {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        let resources = builder.directory("Resources", in: contents.id)
        builder.file("a", in: contents.id, contents: [1])
        builder.file("packed.dat", in: resources.id, contents: [2], compressed: true)
        let fileSystem = builder.build()
        try expectRejected(fileSystem, app: builder.app) {
            ($0 as? ReaderError) == .compressedFile(path: "App.app/Contents/Resources/packed.dat")
        }
        #expect(fileSystem.calls.xattrs.load(ordering: .relaxed) == 0)
        #expect(fileSystem.calls.extents.load(ordering: .relaxed) == 0)
    }

    @Test func symlinkOutsideIsKeptButNeverFollowed() throws {
        let outside = try scratchFolder("outside")
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        builder.symlink("escape", in: contents.id, target: outside.path)
        builder.symlink("up", in: contents.id, target: "../../../../..")
        let (staged, _) = try stageFake(builder.build(), app: builder.app)
        defer { discardAndWait(staged) }
        let items = try snapshot(staged.url)
        #expect(items[BytePath("Contents/escape")]?.target == outside.path)
        #expect(items[BytePath("Contents/up")]?.target == "../../../../..")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func fileBehindASymlinkOfTheSameNameIsRefused() throws {
        let outside = try scratchFolder("outside")
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        builder.symlink("escape", in: contents.id, target: outside.path + "/pwned")
        builder.file("escape", in: contents.id, contents: Array("evil".utf8))
        try expectRejected(builder.build(), app: builder.app, outside: outside) {
            ($0 as? ExtractorError)
                == .nameCollision(
                    paths: ["App.app/Contents/escape", "App.app/Contents/escape"], volumeIsCaseSensitive: false)
        }
    }

    @Test func folderBehindASymlinkOfTheSameNameIsRefused() throws {
        let outside = try scratchFolder("outside")
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        builder.symlink("escape", in: contents.id, target: outside.path)
        let folder = builder.directory("escape", in: contents.id)
        builder.file("pwned", in: folder.id, contents: Array("evil".utf8))
        try expectRejected(builder.build(), app: builder.app, outside: outside) { $0 is ExtractorError }
    }

    @Test func caseAndNormalisationVariantsCollideUpFront() throws {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        builder.file("README", in: contents.id, contents: [1])
        builder.file("Readme", in: contents.id, contents: [2])
        builder.file("caf\u{E9}", in: contents.id, contents: [3])
        builder.file("cafe\u{301}", in: contents.id, contents: [4])
        builder.file("unique", in: contents.id, contents: [5])
        let fileSystem = builder.build()
        try expectRejected(fileSystem, app: builder.app) {
            ($0 as? ExtractorError)
                == .nameCollision(
                    paths: [
                        "App.app/Contents/README", "App.app/Contents/Readme", "App.app/Contents/cafe\u{301}",
                        "App.app/Contents/caf\u{E9}",
                    ].sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, volumeIsCaseSensitive: false)
        }
        #expect(fileSystem.calls.extents.load(ordering: .relaxed) == 0, "read file data before refusing")
    }

    @Test func caseSensitiveRulesKeepCaseButNotNormalisation() {
        let rules = NameRules(caseSensitive: true)
        #expect(rules.collisions(among: ["README", "readme", "ReadMe"]).isEmpty)
        #expect(rules.collisions(among: ["caf\u{E9}", "cafe\u{301}", "x"]) == ["caf\u{E9}", "cafe\u{301}"])
        let insensitive = NameRules(caseSensitive: false)
        #expect(insensitive.collisions(among: ["README", "readme", "other"]) == ["README", "readme"])
        #expect(insensitive.collisions(among: ["\u{C9}T\u{C9}", "e\u{301}te\u{301}"]).count == 2)
        #expect(insensitive.collisions(among: ["a", "b"]).isEmpty)
    }

    @Test func duplicateNamesAreRefused() throws {
        let builder = FakeBuilder()
        builder.file("twice", contents: [1])
        builder.file("twice", contents: [2])
        try expectRejected(builder.build(), app: builder.app) { $0 is ExtractorError }
    }
}

// MARK: - Install, discard, cancel

@Suite struct InstallTests {
    private func app(_ marker: String) -> (FakeFileSystem, Entry) {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents", mode: 0o555)
        builder.file("marker", in: contents.id, contents: Array(marker.utf8), mode: 0o444)
        return (builder.build(), builder.app)
    }

    private func marker(_ app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    @Test func freshInstall() throws {
        let destination = try scratchFolder("install")
        let (fileSystem, entry) = app("new")
        let area = try Extractor.makeStagingArea(for: destination)
        let staged = try Extractor.stage(app: entry, from: fileSystem, into: area)
        let installed = try Extractor.install(staged, into: destination) { _ in Issue.record("nothing to trash") }
        #expect(installed == destination.appendingPathComponent("App.app", isDirectory: true))
        #expect(try marker(installed) == "new")
        #expect(!exists(area.url))
    }

    @Test func replacingSwapsAndTrashesTheOldCopy() throws {
        let destination = try scratchFolder("replace")
        let trashFolder = try scratchFolder("trash")
        let (oldFS, oldEntry) = app("old")
        let first = try Extractor.stage(
            app: oldEntry, from: oldFS, into: try Extractor.makeStagingArea(for: destination))
        _ = try Extractor.install(first, into: destination) { _ in }

        let (newFS, newEntry) = app("new")
        let area = try Extractor.makeStagingArea(for: destination)
        let staged = try Extractor.stage(app: newEntry, from: newFS, into: area)
        var trashed: URL?
        let installed = try Extractor.install(staged, into: destination) { old in
            let target = trashFolder.appendingPathComponent(old.lastPathComponent)
            try FileManager.default.moveItem(at: old, to: target)
            trashed = target
        }
        #expect(try marker(installed) == "new")
        #expect(try marker(try #require(trashed)) == "old")
        #expect(!exists(area.url))
    }

    @Test func missingDestination() throws {
        let missing = try scratchFolder("missing").appendingPathComponent("nope")
        #expect(throws: ExtractorError.destinationNotWritable(path: missing.path, errno: ENOENT)) {
            try Extractor.makeStagingArea(for: missing)
        }
    }

    @Test func unwritableDestination() throws {
        let destination = try scratchFolder("readonly")
        let (fileSystem, entry) = app("new")
        let staged = try Extractor.stage(
            app: entry, from: fileSystem, into: try Extractor.makeStagingArea(for: destination))
        defer { discardAndWait(staged) }
        chmod(destination.path, 0o555)
        defer { chmod(destination.path, 0o755) }
        #expect(throws: ExtractorError.destinationNotWritable(path: destination.path, errno: EACCES)) {
            try Extractor.makeStagingArea(for: destination)
        }
        #expect(throws: ExtractorError.destinationNotWritable(path: destination.path, errno: EACCES)) {
            try Extractor.install(staged, into: destination) { _ in }
        }
        #expect(exists(staged.url))
    }

    @Test func cancellingMidStageLeavesNothing() throws {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        for index in 0..<200 {
            builder.file("f\(index)", in: contents.id, contents: [UInt8](repeating: 7, count: 64 << 10))
        }
        let checks = Atomic<Int>(0)
        let options = StageOptions(bufferSize: 4096) { checks.add(1, ordering: .relaxed).newValue > 300 }
        let destination = try scratchFolder("cancel")
        let area = try Extractor.makeStagingArea(for: destination)
        #expect(throws: ExtractorError.cancelled) {
            try Extractor.stage(app: builder.app, from: builder.build(), into: area, options: options)
        }
        #expect(!exists(area.url))
        #expect(waitForDiscard(area))
    }

    @Test func discardDeletesReadOnlyTrees() throws {
        let (fileSystem, entry) = app("x")
        let (staged, _) = try stageFake(fileSystem, app: entry)
        let done = DispatchSemaphore(value: 0)
        Extractor.discard(staged) { done.signal() }
        #expect(done.wait(timeout: .now() + 20) == .success)
        #expect(waitForDiscard(staged.area))
    }
}

// MARK: - Fixture images

/// Every entry of `fileSystem` under its root, by path from the root.
private func readerEntries(_ fileSystem: any FileSystem) throws -> [BytePath: Entry] {
    var out: [BytePath: Entry] = [:]
    try DMGReader.walk(fileSystem) { path, entry in out[BytePath(path.joined(separator: "/"))] = entry }
    return out
}

/// One manifest line from either fixture script (HFS+ lists xattr names; APFS adds hashes).
private struct ManifestLine: Decodable {
    struct XattrInfo: Decodable {
        let size: Int
        let sha256: String
    }
    let path: String
    let kind: String
    let mode: UInt16
    let size: UInt64?
    let sha256: String?
    let target: String?
    let ino: UInt64
    let xattrNames: Set<String>
    let xattrHashes: [String: String]?
    /// `[seconds, nanoseconds]` of the item's creation time as the mounted volume shows it.
    let birthtime: [Int64]?

    enum CodingKeys: String, CodingKey { case path, kind, mode, size, sha256, target, ino, xattrs, birthtime }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decode(String.self, forKey: .kind)
        mode = try c.decode(UInt16.self, forKey: .mode)
        size = try c.decodeIfPresent(UInt64.self, forKey: .size)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        ino = try c.decode(UInt64.self, forKey: .ino)
        birthtime = try c.decodeIfPresent([Int64].self, forKey: .birthtime)
        if let names = try? c.decode([String].self, forKey: .xattrs) {
            xattrNames = Set(names)
            xattrHashes = nil
        } else {
            let info = try c.decode([String: XattrInfo].self, forKey: .xattrs)
            xattrNames = Set(info.keys)
            xattrHashes = info.mapValues(\.sha256)
        }
    }
}

struct FixtureImage: Sendable, CustomStringConvertible {
    let image: String
    let manifest: String
    var description: String { image }

    static let all = [
        FixtureImage(image: "hfsplus/hfsplus.cdr", manifest: "hfsplus/manifest-hfsplus.jsonl"),
        FixtureImage(image: "hfsplus/hfsx.cdr", manifest: "hfsplus/manifest-hfsx.jsonl"),
        FixtureImage(image: "apfs/ci.img", manifest: "apfs/ci-manifest.jsonl"),
        FixtureImage(image: "apfs/cs.img", manifest: "apfs/cs-manifest.jsonl"),
    ]
}

/// The decmpfs folders the fixture scripts make; staging them must fail over to the mount path.
private let compressedFolders: Set<String> = ["compressed", "compressed-in-image"]
/// Names that differ only by case (case-sensitive images): they can't coexist in the
/// case-insensitive staging folder, so `caseOnlyNamesCollide` covers them instead.
private let caseOnlyFolder = "case"

@Suite struct FixtureFidelityTests {
    @Test(arguments: FixtureImage.all)
    func everyTopLevelItemMatchesTheManifest(_ fixture: FixtureImage) throws {
        let fixtures = packageRoot.appendingPathComponent(".build/fixtures")
        let imagePath = fixtures.appendingPathComponent(fixture.image).path
        try #require(
            FileManager.default.fileExists(atPath: imagePath),
            "run scripts/fixtures-hfsplus.sh and scripts/fixtures-apfs.sh first")
        let base = try DMGReader.open(path: imagePath).fileSystem
        let topLevel = try base.children(of: base.root).map(\.name)
        let hidden = compressedFolders.union([caseOnlyFolder]).intersection(topLevel)
        let fileSystem = RootAsApp(base: base, rootName: "Volume.app", hiddenRootNames: hidden)
        let staged = try Extractor.stage(
            app: try fileSystem.root, from: fileSystem,
            into: try Extractor.makeStagingArea(for: try scratchFolder("fixture")))
        defer { discardAndWait(staged) }

        let text = try String(contentsOf: fixtures.appendingPathComponent(fixture.manifest), encoding: .utf8)
        let manifest = try text.split(separator: "\n").map {
            try JSONDecoder().decode(ManifestLine.self, from: Data($0.utf8))
        }.filter { line in !hidden.contains(where: { line.path == $0 || line.path.hasPrefix($0 + "/") }) }
        let disk = try snapshot(staged.url)
        let entries = try readerEntries(fileSystem)
        var problems: [String] = []
        var birthtimes = 0
        let expectedPaths = Set(manifest.map { BytePath($0.path) })
        for missing in expectedPaths.subtracting(disk.keys).sorted() { problems.append("missing \(missing)") }
        for extra in Set(disk.keys).subtracting(expectedPaths).sorted() { problems.append("extra \(extra)") }

        var groupsExpected: [UInt64: Set<BytePath>] = [:]
        var groupsActual: [UInt64: Set<BytePath>] = [:]
        for line in manifest {
            let key = BytePath(line.path)
            guard let item = disk[key] else { continue }
            func check(_ what: String, _ ok: Bool) { if !ok { problems.append("\(line.path): \(what)") } }
            check("kind \(item.kind) vs \(line.kind)", item.kind.rawValue == line.kind)
            check("mode \(String(item.mode, radix: 8))", item.mode == line.mode & 0o777)
            if line.kind == "file" {
                check("size", item.size == line.size)
                check("sha256", item.sha256 == line.sha256)
                groupsExpected[line.ino, default: []].insert(key)
                groupsActual[item.inode, default: []].insert(key)
            }
            check("target", item.target == line.target)
            let expectedNames = line.xattrNames.filter(Writer.copies)
            check(
                "xattrs \(item.xattrs.keys.sorted()) vs \(expectedNames.sorted())",
                Set(item.xattrs.keys) == expectedNames)
            for (name, hash) in line.xattrHashes ?? [:] where expectedNames.contains(name) {
                check("xattr \(name) value", item.xattrs[name].map(sha256Hex) == hash)
            }
            if let time = entries[key]?.modificationTime {
                check("mtime", item.mtime.tv_sec == time.seconds && item.mtime.tv_nsec == Int(time.nanoseconds))
            } else {
                check("reader has no mtime", false)
            }
            let crtime = "crtime \(item.crtime.tv_sec).\(item.crtime.tv_nsec)"
            if let time = entries[key]?.creationTime {
                check(
                    "\(crtime) vs reader \(time.seconds).\(time.nanoseconds)",
                    item.crtime.tv_sec == time.seconds && item.crtime.tv_nsec == Int(time.nanoseconds))
            } else {
                check("reader has no creation time", false)
            }
            if let birth = line.birthtime, birth.count == 2 {
                birthtimes += 1
                check(
                    "\(crtime) vs mounted \(birth[0]).\(birth[1])",
                    item.crtime.tv_sec == birth[0] && Int64(item.crtime.tv_nsec) == birth[1])
            }
        }
        #expect(birthtimes == manifest.count, "manifest has creation times for \(birthtimes) of \(manifest.count)")
        #expect(Set(groupsExpected.values) == Set(groupsActual.values), "hard link groups differ")
        #expect(groupsExpected.values.contains { $0.count > 1 }, "fixture has no hard links")
        #expect(problems.isEmpty, "\(problems.count) differences: \(problems.prefix(30))")
    }

    @Test(arguments: FixtureImage.all)
    func compressedFoldersSendToTheMountPath(_ fixture: FixtureImage) throws {
        let imagePath = packageRoot.appendingPathComponent(".build/fixtures/\(fixture.image)").path
        try #require(FileManager.default.fileExists(atPath: imagePath))
        let fileSystem = try DMGReader.open(path: imagePath).fileSystem
        let folders = try fileSystem.children(of: fileSystem.root).filter { compressedFolders.contains($0.name) }
        try #require(!folders.isEmpty)
        for folder in folders {
            let area = try Extractor.makeStagingArea(for: try scratchFolder("compressed"))
            do {
                discardAndWait(try Extractor.stage(app: folder, from: fileSystem, into: area))
                if folder.name == "compressed-in-image" || fixture.image.hasPrefix("hfsplus") {
                    Issue.record("\(folder.name) staged without a compressedFile error")
                }
            } catch let error as ReaderError {
                guard case .compressedFile(let path) = error else {
                    Issue.record("\(error)")
                    continue
                }
                #expect(path.hasPrefix(folder.name + "/"))
                #expect(error.wantsMountFallback)
            }
            #expect(waitForDiscard(area) || exists(area.url))
        }
    }

    /// A case-sensitive image whose app holds names differing only by case can't be
    /// staged on a case-insensitive volume: `stage` sees it in the plan and throws
    /// `nameCollision` before writing anything.
    @Test(arguments: [FixtureImage.all[1], FixtureImage.all[3]])
    func caseOnlyNamesCollide(_ fixture: FixtureImage) throws {
        let imagePath = packageRoot.appendingPathComponent(".build/fixtures/\(fixture.image)").path
        try #require(FileManager.default.fileExists(atPath: imagePath))
        let fileSystem = try DMGReader.open(path: imagePath).fileSystem
        let folder = try #require(try fileSystem.children(of: fileSystem.root).first { $0.name == caseOnlyFolder })
        let destination = try scratchFolder("case")
        try #require(pathconf(destination.path, _PC_CASE_SENSITIVE) == 0, "this test needs a case-insensitive volume")
        let area = try Extractor.makeStagingArea(for: destination)
        do {
            discardAndWait(try Extractor.stage(app: folder, from: fileSystem, into: area))
            Issue.record("case-only names staged on a case-insensitive volume")
        } catch let error as ExtractorError {
            // hfsx.cdr holds readme/README/ReadMe.txt, cs.img Name/name.txt.
            let names = try fileSystem.children(of: folder).map { "case/" + $0.name }
            #expect(
                error
                    == .nameCollision(
                        paths: names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
                        volumeIsCaseSensitive: false))
            #expect(names.count >= 2)
        }
        #expect(waitForDiscard(area))
    }
}

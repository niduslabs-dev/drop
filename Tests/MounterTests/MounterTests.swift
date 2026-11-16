import Foundation
import ReaderCore
import Testing

@testable import Extractor
@testable import Mounter

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The images `scripts/fixtures-mount.sh` builds, and where these tests mount them.
enum MountFixtures {
    static let root = packageRoot.appending(path: ".build/fixtures/mount")
    static let source = root.appending(path: "source/Tiny.app")
    /// Matches `THROWAWAY_PASSWORD` in the script.
    static let password = "drop-mount-fixture-only"
    static let mountRoot = FileManager.default.temporaryDirectory.appending(
        path: "dev.niduslabs.drop.mounts-mounter-tests", directoryHint: .isDirectory)

    /// For the suite that runs alongside `HiddenMountTests`, so its mounts never show up in
    /// that suite's leftover checks.
    static let readerMountRoot = FileManager.default.temporaryDirectory.appending(
        path: "dev.niduslabs.drop.mounts-reader-tests", directoryHint: .isDirectory)

    static func image(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "run scripts/fixtures-verifier.sh, then scripts/fixtures-mount.sh (\(name))")
        return url
    }

    static var leftovers: [(device: String, mountPoint: String)] {
        HiddenMount.attachedImages(mountedUnder: mountRoot)
    }

    /// The image copied into `folder`, for a suite that runs alongside `HiddenMountTests`.
    /// One image file attaches as one device however often it is asked for, so two suites
    /// sharing the fixture would share, and detach, each other's mount.
    static func copy(_ name: String, in folder: URL) throws -> URL {
        let copy = folder.appending(path: name)
        try FileManager.default.copyItem(at: try image(name), to: copy)
        return copy
    }
}

/// A scratch folder under `.build/` for staged copies.
func scratchFolder(_ label: String) throws -> URL {
    let url = packageRoot.appending(path: ".build/mounter-tests/\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Every item under `app`, as relative path to (kind, mode, bytes or link target), never
/// following symlinks.
func snapshot(_ app: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    func visit(_ path: String, _ relative: String) throws {
        var info = stat()
        try #require(lstat(path, &info) == 0, "lstat \(path)")
        let mode = String(info.st_mode & 0o777, radix: 8)
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            result[relative] = "dir \(mode)"
            for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                try visit(path + "/" + name, relative + "/" + name)
            }
        case S_IFLNK:
            result[relative] = "link " + (try FileManager.default.destinationOfSymbolicLink(atPath: path))
        default:
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            result[relative] = "file \(mode) \(data.count) \(data.hashValue)"
        }
    }
    try visit(app.path, app.lastPathComponent)
    return result
}

@Suite(.serialized)
struct HiddenMountTests {
    @Test func encryptedImageMountsWithItsPasswordAndDetaches() throws {
        let image = try MountFixtures.image("encrypted.dmg")
        let mount = try HiddenMount.attach(
            image, password: MountPassword(MountFixtures.password), root: MountFixtures.mountRoot)
        #expect(mount.deviceNode.hasPrefix("/dev/disk"))
        #expect(mount.mountPoint.path.contains("dev.niduslabs.drop.mounts-mounter-tests"))
        #expect(mount.volumeName == "Encrypted")
        #expect(MountFixtures.leftovers.map(\.device) == [mount.deviceNode])
        let fileSystem = try mount.fileSystem()
        #expect(try fileSystem.children(of: fileSystem.root).map(\.name).contains("Tiny.app"))
        try mount.detach()
        try mount.detach()
        #expect(mount.isDetached)
        #expect(MountFixtures.leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mount.directory.path), "the private folder is removed")
    }

    @Test func wrongPasswordIsItsOwnError() throws {
        let image = try MountFixtures.image("encrypted.dmg")
        #expect(throws: MountError.wrongPassword) {
            try HiddenMount.attach(image, password: MountPassword("not it"), root: MountFixtures.mountRoot)
        }
        #expect(throws: MountError.wrongPassword) {
            try HiddenMount.attach(image, password: MountPassword(""), root: MountFixtures.mountRoot)
        }
        #expect(MountFixtures.leftovers.isEmpty)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: MountFixtures.mountRoot.path)) ?? []
        #expect(folders.isEmpty, "no mount folder left: \(folders)")
    }

    @Test(arguments: ["sparse.sparseimage", "bundle.sparsebundle", "compressed.dmg"])
    func unreadableFormatsMount(_ name: String) throws {
        let mount = try HiddenMount.attach(try MountFixtures.image(name), root: MountFixtures.mountRoot)
        defer { try? mount.detach() }
        let fileSystem = try mount.fileSystem()
        #expect(try fileSystem.children(of: fileSystem.root).map(\.name).contains("Tiny.app"))
        try mount.detach()
        #expect(MountFixtures.leftovers.isEmpty)
    }

    /// diskutil asks to accept the licence on stdin. Unanswered, it declines and attaches
    /// nothing; Drop answers only after the user agreed to the licence Drop showed.
    @Test func licenceIsNeverAcceptedUnlessTheUserAgreed() throws {
        let image = try MountFixtures.image("licence.dmg")
        #expect(throws: MountError.licenceNotShown) {
            try HiddenMount.attach(image, root: MountFixtures.mountRoot)
        }
        #expect(MountFixtures.leftovers.isEmpty)
        let mount = try HiddenMount.attach(image, licenceAccepted: true, root: MountFixtures.mountRoot)
        try mount.detach()
        #expect(MountFixtures.leftovers.isEmpty)
    }

    @Test func notADiskImageFailsToAttach() throws {
        let folder = try scratchFolder("garbage")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "garbage.dmg")
        try Data(repeating: 0x5A, count: 64 * 1024).write(to: file)
        #expect {
            try HiddenMount.attach(file, root: MountFixtures.mountRoot)
        } throws: { error in
            if case MountError.attachFailed = error { true } else { false }
        }
        #expect(MountFixtures.leftovers.isEmpty)
    }

    @Test func sweepDetachesALeakedMountUnderItsRootOnly() throws {
        let mount = try HiddenMount.attach(try MountFixtures.image("sparse.sparseimage"), root: MountFixtures.mountRoot)
        // A sweep of another root never touches it.
        let elsewhere = FileManager.default.temporaryDirectory.appending(path: "dev.niduslabs.drop.mounts-nothing-here")
        #expect(HiddenMount.sweepLeftoverMounts(root: elsewhere).isEmpty)
        #expect(MountFixtures.leftovers.count == 1)
        // As after a crash: the mount object is never asked to detach.
        let swept = HiddenMount.sweepLeftoverMounts(root: MountFixtures.mountRoot)
        #expect(swept == [mount.deviceNode])
        #expect(MountFixtures.leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mount.directory.path))
        try mount.detach()  // Already gone: a no-op, not an error.
    }

    @Test func passwordIsRedactedAndWipes() {
        let password = MountPassword("secret")
        #expect(!"\(password)".contains("secret"))
        password.wipe()
        #expect(password.isEmpty)
        var bytes = Array("secret".utf8)
        let taken = MountPassword(bytes: &bytes)
        #expect(bytes.allSatisfy { $0 == 0 })
        #expect(!taken.isEmpty)
    }
}

struct AttachOutputTests {
    @Test func picksTheWholeDiskAndTheOneMountPoint() throws {
        // An APFS image: the GPT disk, its APFS partition, the synthesized container, its volume.
        let entities: [[String: Any]] = [
            ["dev-entry": "disk6", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "disk6s1", "content-hint": "Apple_APFS"],
            ["dev-entry": "disk7", "content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC"],
            ["dev-entry": "disk7s1", "mount-point": "/private/var/x/volume", "volume-name": "Zed"],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
        let prefixed = Data("Licence text printed first.\n".utf8) + data
        let parsed = try HiddenMount.parseAttach(prefixed)
        #expect(
            parsed == HiddenMount.Attached(device: "/dev/disk6", mountPoint: "/private/var/x/volume", volumeName: "Zed")
        )
    }

    @Test func refusesNoOrSeveralVolumes() throws {
        for entities: [[String: Any]] in [
            [["dev-entry": "disk6"]],
            [
                ["dev-entry": "disk6"], ["dev-entry": "disk6s1", "mount-point": "/a"],
                ["dev-entry": "disk6s2", "mount-point": "/b"],
            ],
        ] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
            #expect(throws: MountError.self) { try HiddenMount.parseAttach(data) }
        }
        #expect(throws: MountError.self) { try HiddenMount.parseAttach(Data("Error: nope".utf8)) }
    }

    @Test func classifiesToolErrors() {
        func result(_ stderr: String) -> ProcessResult {
            ProcessResult(status: 1, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false)
        }
        #expect(HiddenMount.classify(result("Error: Incorrect passphrase")) == .wrongPassword)
        #expect(HiddenMount.classify(result("Error: Passphrase cannot be empty")) == .wrongPassword)
        #expect(
            HiddenMount.classify(
                result("WARNING: this disk image contains a software license agreement\nError: Operation canceled"))
                == .licenceNotShown)
        #expect(HiddenMount.classify(result("Error: something else")) == .attachFailed("Error: something else"))
    }
}

@Suite(.serialized)
struct MountedFileSystemTests {
    /// decmpfs files on the mount read back decompressed through the kernel: staged as
    /// plain files with identical bytes, no `com.apple.decmpfs`, not compressed on disk.
    @Test func compressedAppStagesUncompressedAndIdentical() throws {
        let images = try scratchFolder("compressed-image")
        defer { Extractor.removeTree(images.path) }
        let mount = try HiddenMount.attach(
            try MountFixtures.copy("compressed.dmg", in: images), root: MountFixtures.readerMountRoot)
        defer { try? mount.detach() }
        let fileSystem = try mount.fileSystem()
        let app = try #require(try fileSystem.children(of: fileSystem.root).first { $0.name == "Tiny.app" })

        // The fixture really is compressed on the mount.
        var info = stat()
        let binary = mount.mountPoint.appending(path: "Tiny.app/Contents/MacOS").path
        let names = try FileManager.default.contentsOfDirectory(atPath: binary)
        let executable = try #require(names.first)
        #expect(lstat(binary + "/" + executable, &info) == 0)
        #expect(info.st_flags & UInt32(UF_COMPRESSED) != 0, "fixture file should be decmpfs-compressed")

        let folder = try scratchFolder("compressed")
        defer { Extractor.removeTree(folder.path) }
        let area = try Extractor.makeStagingArea(for: folder)
        let staged = try Extractor.stage(app: app, from: fileSystem, into: area)
        defer { Extractor.discard(staged) }
        try mount.detach()

        #expect(try snapshot(staged.url) == snapshot(MountFixtures.source))
        var stagedInfo = stat()
        #expect(lstat(staged.url.path + "/Contents/MacOS/" + executable, &stagedInfo) == 0)
        #expect(stagedInfo.st_flags & UInt32(UF_COMPRESSED) == 0)
        let size = getxattr(
            staged.url.path + "/Contents/MacOS/" + executable, "com.apple.decmpfs", nil, 0, 0, XATTR_SHOWCOMPRESSION)
        #expect(size < 0, "no decmpfs attribute copied")
    }

    @Test func symlinksAreReportedNotFollowed() throws {
        let images = try scratchFolder("encrypted-image")
        defer { Extractor.removeTree(images.path) }
        let mount = try HiddenMount.attach(
            try MountFixtures.copy("encrypted.dmg", in: images), password: MountPassword(MountFixtures.password),
            root: MountFixtures.readerMountRoot)
        defer { try? mount.detach() }
        let fileSystem = try mount.fileSystem()
        var links: [Entry] = []
        var stack = [fileSystem.root]
        while let entry = stack.popLast() {
            for child in try fileSystem.children(of: entry) {
                if child.kind == .directory { stack.append(child) }
                if child.kind == .symlink { links.append(child) }
            }
        }
        let sourceLinks = try snapshot(MountFixtures.source).values.filter { $0.hasPrefix("link ") }.sorted()
        #expect(try links.map { "link " + (try fileSystem.symlinkTarget(of: $0)) }.sorted() == sourceLinks)
        #expect(throws: ReaderError.self) { try fileSystem.device.read(at: 0, count: 1) }
    }
}

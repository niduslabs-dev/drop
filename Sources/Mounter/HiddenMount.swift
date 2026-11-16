import Foundation
import ReaderCore
import Synchronization

/// Why a hidden mount couldn't be made or removed.
public enum MountError: Error, Sendable, Equatable {
    /// The image is encrypted and the password was wrong (or empty).
    case wrongPassword
    /// The image carries a licence agreement Drop couldn't show (its container isn't
    /// readable, so the licence wasn't parsed). The attach tool asked to accept it and got
    /// no answer, so nothing was attached. The panel offers "Open disk image", where macOS
    /// shows the licence itself.
    case licenceNotShown
    /// The tool refused the image (not a disk image, several volumes, a filesystem macOS
    /// can't mount). The message is the tool's own last line.
    case attachFailed(String)
    /// The tool ran past its timeout and was stopped.
    case timedOut(String)
    /// The image is still attached after a normal and a forced detach.
    case detachFailed(device: String, reason: String)
}

/// An image attached read-only and invisibly (`nobrowse`: not in Finder, the sidebar or the
/// desktop) at a private mount point, for the fallback when Drop can't read an image itself.
///
/// **Tool.** `diskutil image attach`, chosen over `hdiutil attach` (deprecated on macOS 27)
/// after measuring both (`drop/.claude/research/hidden-mount.md`): diskutil skips the
/// first-attach checksum pass that hdiutil runs without `-noverify` (Docker 0.54 s vs
/// 20.9 s, Firefox 0.41 s vs 5.7 s), refuses a licence agreement when stdin gives no answer
/// where `hdiutil attach -plist` silently accepts it, and takes `--mountPoint`, which it
/// removes again on unmount. The signature check on the staged copy covers what the
/// checksum pass would have caught.
///
/// **Where.** Each mount gets a fresh 0700 folder under `defaultRoot` (in the per-user
/// temporary directory), and the volume is mounted at `volume` inside it. That prefix is how
/// `sweepLeftoverMounts` finds mounts a crash left behind; no other mount is ever touched.
///
/// **Detach.** By the image's whole-disk device node (`diskutil eject /dev/diskN`),
/// retried once, then forced. `detach()` is idempotent; call it on every path out.
public final class HiddenMount: Sendable {
    public let image: URL
    /// The image's whole disk, such as `/dev/disk6` (an APFS image's synthesized container
    /// goes with it).
    public let deviceNode: String
    public let mountPoint: URL
    public let volumeName: String
    /// The private folder holding `mountPoint`.
    public let directory: URL
    private let detached = Mutex(false)

    static let diskutil = "/usr/sbin/diskutil"
    static let hdiutil = "/usr/bin/hdiutil"
    /// diskutil attaches without a checksum pass, so even Docker's 570 MB takes under a
    /// second; the cap only stops a wedged tool.
    public static let attachTimeout: Duration = .seconds(120)
    public static let detachTimeout: Duration = .seconds(30)
    static let infoTimeout: Duration = .seconds(30)
    /// Pause before retrying a detach: a busy volume (Spotlight, a file still closing)
    /// usually frees up within a moment.
    static let detachRetryDelay: TimeInterval = 0.5
    static let mountPointName = "volume"
    static let directoryPrefix = "mount-"
    static let privateMode: mode_t = 0o700
    /// Sent on stdin when the user agreed to the licence Drop showed. Without it diskutil
    /// reads EOF and declines.
    static let licenceAgreement = Array("Y\n".utf8)

    /// `<per-user temporary directory>/dev.niduslabs.drop.mounts`.
    public static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "dev.niduslabs.drop.mounts", directoryHint: .isDirectory)
    }

    init(image: URL, deviceNode: String, mountPoint: URL, volumeName: String, directory: URL) {
        self.image = image
        self.deviceNode = deviceNode
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.directory = directory
    }

    deinit { try? detach() }

    /// Attaches `image` read-only and hidden. Blocking; run it off the main thread.
    ///
    /// - Parameters:
    ///   - password: for an encrypted image. Written to the tool's stdin, never its arguments.
    ///   - licenceAccepted: the user clicked Agree on the licence Drop showed for this image.
    ///     Only then is the tool's licence prompt answered; otherwise it is declined and the
    ///     attach fails with `licenceNotShown`. Ignored with a password: an encrypted image's
    ///     licence can't be read beforehand, so it is never accepted.
    ///   - root: the folder mount folders go in (`defaultRoot`; tests pass their own).
    public static func attach(
        _ image: URL, password: MountPassword? = nil, licenceAccepted: Bool = false, root: URL = defaultRoot,
        timeout: Duration = attachTimeout
    ) throws -> HiddenMount {
        let directory = try makePrivateDirectory(in: root)
        let mountPoint = directory.appending(path: mountPointName, directoryHint: .isDirectory)
        var arguments = ["image", "attach", "--readOnly", "--nobrowse", "--plist"]
        if password != nil { arguments.append("--stdinpassphrase") }
        arguments += ["--mountPoint", mountPoint.path, image.path]

        let result: ProcessResult
        do {
            result = try BoundedProcess.run(diskutil, arguments, timeout: timeout) { write in
                if let password {
                    password.withBytes(write)
                } else if licenceAccepted {
                    licenceAgreement.withUnsafeBytes(write)
                }
            }
        } catch {
            removeDirectory(directory)
            throw MountError.attachFailed("could not run diskutil: \(error)")
        }

        guard !result.timedOut, result.status == 0 else {
            // A stopped or failed tool may still have mounted something under our folder.
            _ = detachAll(under: directory)
            removeDirectory(directory)
            if result.timedOut { throw MountError.timedOut("diskutil image attach") }
            throw classify(result)
        }
        do {
            let parsed = try parseAttach(result.stdout)
            return HiddenMount(
                image: image, deviceNode: parsed.device, mountPoint: URL(fileURLWithPath: parsed.mountPoint),
                volumeName: parsed.volumeName ?? image.deletingPathExtension().lastPathComponent, directory: directory)
        } catch {
            _ = detachAll(under: directory)
            removeDirectory(directory)
            throw error
        }
    }

    /// The mounted volume as a `FileSystem`.
    public func fileSystem() throws -> MountedFileSystem {
        try MountedFileSystem(mountPoint: mountPoint, volumeName: volumeName)
    }

    /// Detaches by device node and removes the private folder. Safe to call again; later
    /// calls do nothing once a detach succeeded.
    ///
    /// Checks first that `deviceNode` still has a volume mounted in this mount's folder:
    /// after a sweep (or someone else's eject) the node number may already belong to
    /// another image, which must never be ejected.
    public func detach() throws {
        try detached.withLock { done in
            guard !done else { return }
            if stillOurs() {
                try Self.detach(device: deviceNode)
            }
            Self.removeDirectory(directory)
            done = true
        }
    }

    /// True while `deviceNode` is this image's: still attached from `image`'s file, or with
    /// a volume mounted in this mount's folder. When `hdiutil info` can't be read, true:
    /// leaving our mount behind is the worse risk.
    func stillOurs() -> Bool {
        guard let images = Self.attachedImageList() else { return true }
        let imagePath = Self.resolved(image.path)
        let folder = Self.resolved(directory.path)
        return images.contains { attached in
            attached.device == deviceNode
                && (attached.imagePath.map(Self.resolved) == imagePath
                    || attached.mountPoints.contains { $0 == folder || $0.hasPrefix(folder + "/") })
        }
    }

    public var isDetached: Bool { detached.withLock { $0 } }

    /// Detaches every image mounted under `root` (left by a crash) and removes leftover
    /// mount folders there. Mounts elsewhere are never touched. Returns the device nodes
    /// detached.
    @discardableResult
    public static func sweepLeftoverMounts(root: URL = defaultRoot) -> [String] {
        let devices = detachAll(under: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(directoryPrefix) {
            removeDirectory(root.appending(path: name, directoryHint: .isDirectory))
        }
        return devices
    }

    /// Attached images with a volume mounted under `prefix`, from `hdiutil info -plist`
    /// (diskutil has no listing of attached images).
    public static func attachedImages(mountedUnder prefix: URL) -> [(device: String, mountPoint: String)] {
        listAttached(mountedUnder: prefix) ?? []
    }

    struct AttachedImage {
        var device: String
        var imagePath: String?
        var mountPoints: [String]
    }

    /// `attachedImages`, or nil when `hdiutil info` couldn't be run or read.
    static func listAttached(mountedUnder prefix: URL) -> [(device: String, mountPoint: String)]? {
        guard let images = attachedImageList() else { return nil }
        let base = resolved(prefix.path)
        return images.flatMap { image in
            image.mountPoints.filter { $0 == base || $0.hasPrefix(base + "/") }.map { (image.device, $0) }
        }
    }

    /// Every attached image: its whole disk, file and mount points (resolved), from
    /// `hdiutil info -plist`. Nil when that can't be run or read.
    static func attachedImageList() -> [AttachedImage]? {
        guard
            let result = try? BoundedProcess.run(hdiutil, ["info", "-plist"], timeout: infoTimeout),
            !result.timedOut, result.status == 0,
            let root = try? plist(from: result.stdout)
        else { return nil }
        let images = root["images"] as? [[String: Any]] ?? []
        return images.compactMap { image in
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            guard let device = wholeDisk(entities) else { return nil }
            return AttachedImage(
                device: device, imagePath: image["image-path"] as? String,
                mountPoints: entities.compactMap { $0["mount-point"] as? String }.map(resolved))
        }
    }

    // MARK: - Helpers

    @discardableResult
    static func detachAll(under prefix: URL) -> [String] {
        var seen: Set<String> = []
        var detached: [String] = []
        for (device, _) in attachedImages(mountedUnder: prefix) where seen.insert(device).inserted {
            if (try? detach(device: device)) != nil { detached.append(device) }
        }
        return detached
    }

    /// `diskutil eject <dev>`, once more after a pause, then `diskutil eject force <dev>`.
    /// A device that is already gone counts as detached.
    static func detach(device: String) throws {
        var lastError = ""
        for (attempt, arguments) in [["eject", device], ["eject", device], ["eject", "force", device]].enumerated() {
            if attempt > 0 { Thread.sleep(forTimeInterval: detachRetryDelay) }
            let result = try? BoundedProcess.run(diskutil, arguments, timeout: detachTimeout)
            if let result, !result.timedOut, result.status == 0 { return }
            guard isAttached(device) else { return }
            lastError = result.map { lastLine($0.stderrText.isEmpty ? $0.stdoutText : $0.stderrText) } ?? "not run"
        }
        throw MountError.detachFailed(device: device, reason: lastError)
    }

    /// True while `device` (a whole disk like `/dev/disk6`) is still a node.
    static func isAttached(_ device: String) -> Bool {
        var info = stat()
        return stat(device, &info) == 0
    }

    static func classify(_ result: ProcessResult) -> MountError {
        let text = result.stderrText + "\n" + result.stdoutText
        let lower = text.lowercased()
        if lower.contains("incorrect passphrase") || lower.contains("passphrase cannot be empty")
            || lower.contains("authentication error")
        {
            return .wrongPassword
        }
        if lower.contains("license agreement") || lower.contains("licence agreement") { return .licenceNotShown }
        return .attachFailed(lastLine(text))
    }

    struct Attached: Equatable {
        var device: String
        var mountPoint: String
        var volumeName: String?
    }

    /// The whole-disk device and the one mount point from `diskutil image attach --plist`.
    /// diskutil prints `disk6` without `/dev/`; the whole disk is the lowest-numbered
    /// `diskN` (an APFS image also lists its synthesized container, attached after it).
    static func parseAttach(_ output: Data) throws -> Attached {
        guard let root = try? plist(from: output), let entities = root["system-entities"] as? [[String: Any]] else {
            throw MountError.attachFailed("diskutil printed no attach plist")
        }
        guard let device = wholeDisk(entities) else { throw MountError.attachFailed("no whole-disk device listed") }
        let mounted = entities.filter { $0["mount-point"] is String }
        guard mounted.count == 1, let point = mounted[0]["mount-point"] as? String else {
            // Detached by the caller: nothing of it is used.
            throw MountError.attachFailed("expected one mounted volume, found \(mounted.count)")
        }
        return Attached(device: device, mountPoint: point, volumeName: mounted[0]["volume-name"] as? String)
    }

    static func wholeDisk(_ entities: [[String: Any]]) -> String? {
        let numbers = entities.compactMap { entity -> Int? in
            guard let entry = entity["dev-entry"] as? String else { return nil }
            let name = entry.hasPrefix("/dev/") ? String(entry.dropFirst("/dev/".count)) : entry
            guard name.hasPrefix("disk") else { return nil }
            return Int(name.dropFirst("disk".count))
        }
        return numbers.min().map { "/dev/disk\($0)" }
    }

    /// Parses a plist that may follow other text (a licence printed before it).
    static func plist(from data: Data) throws -> [String: Any]? {
        let start = data.range(of: Data("<?xml".utf8))?.lowerBound ?? data.startIndex
        let object = try PropertyListSerialization.propertyList(from: data[start...], format: nil)
        return object as? [String: Any]
    }

    static func makePrivateDirectory(in root: URL) throws -> URL {
        if mkdir(root.path, privateMode) != 0, errno != EEXIST {
            throw MountError.attachFailed("could not create \(root.path): errno \(errno)")
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw MountError.attachFailed("\(root.path) is not a folder of this user")
        }
        chmod(root.path, privateMode)
        var template = Array(root.appending(path: directoryPrefix + "XXXXXXXX").path.utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw MountError.attachFailed("mkdtemp in \(root.path): errno \(errno)")
        }
        return URL(fileURLWithPath: String(cString: made), isDirectory: true)
    }

    /// Removes a mount folder once nothing is mounted in it. diskutil already removes the
    /// mount point on unmount; a declined attach can leave it with a `.autodiskmounted` file.
    static func removeDirectory(_ directory: URL) {
        var folder = stat()
        guard lstat(directory.path, &folder) == 0 else { return }
        let point = directory.appending(path: mountPointName).path
        var inner = stat()
        if lstat(point, &inner) == 0 {
            // Still a mount (another device): never delete through it.
            guard inner.st_dev == folder.st_dev else { return }
            try? FileManager.default.removeItem(atPath: point)
        }
        rmdir(directory.path)
    }

    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

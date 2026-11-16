import DiskImage
import Foundation
import ReaderCore
import Synchronization
import Testing

@testable import Extractor
@testable import Installer
@testable import Mounter

/// The package root, from this file's path.
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Hidden mounts made by tests go here, apart from the app's own `HiddenMount.defaultRoot`.
let testMountRoot = FileManager.default.temporaryDirectory.appending(
    path: "dev.niduslabs.drop.mounts-installer-tests", directoryHint: .isDirectory)

let corpusEnabled = ProcessInfo.processInfo.environment["DROP_CORPUS"] == "1"

enum Fixtures {
    static let root = packageRoot.appending(path: ".build/fixtures/installer")
    static let missing =
        "Installer fixtures missing: run scripts/fixtures-verifier.sh, then scripts/fixtures-installer.sh"

    static func dmg(_ name: String) throws -> URL {
        let url = root.appending(path: "\(name).dmg")
        try #require(FileManager.default.fileExists(atPath: url.path), "\(missing) (\(name).dmg)")
        return url
    }

    static let encrypted = packageRoot.appending(path: ".build/fixtures/diskimage/encrypted.dmg")

    /// A sample DMG from `.claude/samples/<folder>/`. Untrusted: read, never run.
    static func sample(_ folder: String, _ file: String) throws -> URL {
        let url = packageRoot.appending(path: ".claude/samples/\(folder)/\(file)")
        try #require(FileManager.default.fileExists(atPath: url.path), "sample \(folder)/\(file) missing")
        return url
    }
}

/// A scratch destination and a stand-in Trash, both under `.build/installer-tests/`, so
/// no test ever touches /Applications, ~/Applications or the real Trash.
struct Scratch {
    let root: URL
    let destination: URL
    let trash: URL
    /// This test's own folder for hidden mounts. Suites run in parallel, so checks for
    /// leftover mounts look only here, never at other tests' mounts.
    let mountRoot: URL

    init(_ label: String) throws {
        root = packageRoot.appending(path: ".build/installer-tests/\(label)-\(UUID().uuidString)")
        destination = root.appending(path: "Applications")
        trash = root.appending(path: "Trash")
        mountRoot = testMountRoot.appending(path: root.lastPathComponent, directoryHint: .isDirectory)
        for folder in [destination, trash] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Moves an item into the stand-in Trash, as `FileManager.trashItem` would.
    var trashItem: @Sendable (URL) throws -> Void {
        let trash = trash
        return { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
        }
    }

    func options(
        policy: DecodePolicyChoice = .background, skipPrompt: Bool = false, mountFallback: MountFallbackSpy? = nil
    ) -> InstallOptions {
        var hook: (@Sendable (URL, ReaderError) -> Void)?
        if let mountFallback { hook = { _, reason in mountFallback.record(reason) } }
        var options = InstallOptions(
            destination: destination, backgroundDecodePolicy: policy.policy, skipFirstLaunchPrompt: skipPrompt,
            trash: trashItem, mountFallback: hook, conditions: .unconstrained)
        options.mountRoot = mountRoot
        return options
    }

    func trashed() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted()
    }

    func installed() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).sorted()
    }

    /// Images still attached under this test's mount folder.
    var leftovers: [(device: String, mountPoint: String)] {
        HiddenMount.attachedImages(mountedUnder: mountRoot)
    }

    func remove() {
        Extractor.removeTree(root.path)
        try? FileManager.default.removeItem(at: mountRoot)
    }
}

enum DecodePolicyChoice {
    case background, utility, fast
    var policy: DecodePolicy {
        switch self {
        case .background: .background
        case .utility: .utility
        case .fast: .fast
        }
    }
}

final class MountFallbackSpy: Sendable {
    private let reasons = Mutex<[ReaderError]>([])
    func record(_ reason: ReaderError) { reasons.withLock { $0.append(reason) } }
    var recorded: [ReaderError] { reasons.withLock { $0 } }
}

/// Polls the session until `matches` holds or `timeout` passes; returns the last state.
@discardableResult
func waitFor(
    _ session: InstallSession, timeout: Duration = .seconds(120), _ matches: (InstallState) -> Bool
) async -> InstallState {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let state = await session.state
        if matches(state) { return state }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await session.state
}

/// The first `identified` summary on the session's stream, and the name of the state
/// right after it ("preparing" when staging follows). Iterates `updates`, its one consumer.
func earlySummary(_ session: InstallSession) async -> (identified: AppSummary?, nextState: String?) {
    var identified: AppSummary?
    for await state in session.updates {
        if let found = identified { return (found, String(describing: state).prefix { $0 != "(" }.description) }
        if case .identified(let summary) = state { identified = summary }
        if state.isFinal { break }
    }
    return (identified, nil)
}

/// True once neither the staging area nor its discarded sibling exists, within `timeout`.
func waitUntilGone(_ area: StagingArea, timeout: Duration = .seconds(30)) async -> Bool {
    let aside = area.url.deletingLastPathComponent()
        .appending(path: Extractor.discardedPrefix + area.url.lastPathComponent)
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if !exists(area.url) && !exists(aside) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

extension InstallState {
    var summary: AppSummary? {
        switch self {
        case .preparing(let s, _), .waitingToPrepare(let s), .ready(let s), .warning(let s, _), .refused(let s, _),
            .installing(let s, _):
            s
        default: nil
        }
    }
    var isPreparing: Bool { if case .preparing = self { true } else { false } }
    var isSettled: Bool {
        switch self {
        case .ready, .warning, .needsLicence, .needsPassword: true
        default: isFinal
        }
    }
}

/// Reads an item's `com.apple.quarantine` without following symlinks.
func quarantine(_ url: URL) throws -> String? { try Quarantine.read(at: url) }

/// Writes a quarantine value onto a file, as a browser does to a download.
func setQuarantine(_ value: String, on url: URL) throws {
    let bytes = Array(value.utf8)
    let result = bytes.withUnsafeBytes {
        setxattr(url.path, Quarantine.attributeName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
    }
    try #require(result == 0, "setxattr: \(errno)")
}

import Foundation
import Testing

@testable import Extractor
@testable import Installer
@testable import Mounter

/// The images `scripts/fixtures-mount.sh` builds. Each holds the same ad hoc app as
/// `Tiny.app`, so every session ends in the not-notarized warning.
enum MountFixtures {
    static let root = packageRoot.appending(path: ".build/fixtures/mount")
    static let source = root.appending(path: "source/Tiny.app")
    /// Matches `THROWAWAY_PASSWORD` in the script.
    static let password = "drop-mount-fixture-only"

    static func image(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "run scripts/fixtures-verifier.sh, then scripts/fixtures-mount.sh (\(name))")
        return url
    }

    /// A copy of the image in the scratch folder, quarantined as a browser would.
    static func quarantinedCopy(_ name: String, in scratch: Scratch) throws -> URL {
        let copy = scratch.root.appending(path: name)
        try FileManager.default.copyItem(at: try image(name), to: copy)
        try setQuarantine(quarantineValue, on: copy)
        return copy
    }

    static let quarantineValue = "0083;6560a8f2;Safari;7A4B1F5C-1111-2222-3333-444455556666"

}

/// Every item under `app`: kind, permission bits and contents or link target.
func tree(_ app: URL) throws -> [String: String] {
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

/// Every path under `app` whose quarantine doesn't carry the DMG's value with `0x0100`.
func wronglyQuarantined(_ app: URL) throws -> [String] {
    let expected = "0183;6560a8f2;Safari;7A4B1F5C-1111-2222-3333-444455556666"
    var wrong: [String] = []
    let enumerator = FileManager.default.enumerator(atPath: app.path)
    var paths = [app.path]
    while let next = enumerator?.nextObject() as? String { paths.append(app.path + "/" + next) }
    for path in paths where try quarantine(URL(fileURLWithPath: path)) != expected { wrong.append(path) }
    return wrong
}

@Suite(.serialized)
struct MountFallbackSessionTests {
    /// Runs a session to the warning, installs, and checks the installed copy and that
    /// nothing stays mounted.
    func installThroughTheMount(
        _ name: String, password: String? = nil, force: Bool = false, label: String
    ) async throws {
        let scratch = try Scratch(label)
        defer { scratch.remove() }
        let dmg = try MountFixtures.quarantinedCopy(name, in: scratch)
        var options = scratch.options()
        options.forceMountFallback = force
        let session = InstallSession(dmg: dmg, options: options)
        await session.start()
        var settled = await waitFor(session) { $0.isSettled }
        if case .needsLicence = settled {
            await session.acceptLicence()
            settled = await waitFor(session) { $0.isSettled && !($0.isLicence) }
        }
        if let password {
            #expect(settled == .needsPassword(attempt: 1))
            await session.providePassword(password)
            settled = await waitFor(session) { $0.isSettled && $0 != .needsPassword(attempt: 1) }
        }
        guard case .warning(let summary, .notNotarized) = settled else {
            Issue.record("\(name): expected the not-notarized warning, got \(settled)")
            return
        }
        #expect(summary.bundleName == "Tiny.app")
        #expect(summary.version == "1.0", "the summary comes from the mounted app's Info.plist")
        #expect(summary.bundleIdentifier == "dev.niduslabs.drop.fixture.tiny")
        #expect(await session.mount == nil, "detached once staged")
        #expect(scratch.leftovers.isEmpty)
        await session.install()
        let app = scratch.destination.appending(path: "Tiny.app")
        #expect(await session.state == .installed(app.standardizedFileURL) || scratch.installed() == ["Tiny.app"])
        #expect(try tree(app) == tree(MountFixtures.source), "\(name): installed copy differs from the source")
        #expect(try wronglyQuarantined(app).isEmpty)
        let timings = await session.timings
        #expect(timings.mounted != nil && timings.unmounted != nil)
    }

    @Test func encryptedImageInstallsWithItsPassword() async throws {
        try await installThroughTheMount("encrypted.dmg", password: MountFixtures.password, label: "m-encrypted")
    }

    @Test func sparseImageInstalls() async throws {
        try await installThroughTheMount("sparse.sparseimage", label: "m-sparse")
    }

    @Test func sparseBundleInstalls() async throws {
        try await installThroughTheMount("bundle.sparsebundle", label: "m-bundle")
    }

    /// The reader finds the decmpfs files while planning, then the session mounts.
    @Test func compressedFilesInstallUncompressed() async throws {
        let spy = MountFallbackSpy()
        let scratch = try Scratch("m-compressed-spy")
        defer { scratch.remove() }
        let session = InstallSession(
            dmg: try MountFixtures.image("compressed.dmg"), options: scratch.options(mountFallback: spy))
        await session.start()
        await waitFor(session) { $0.isSettled }
        #expect(spy.recorded.count == 1)
        if case .compressedFile = spy.recorded.first {
        } else {
            Issue.record("expected compressedFile, got \(spy.recorded)")
        }
        await session.cancel()
        try await installThroughTheMount("compressed.dmg", label: "m-compressed")
    }

    /// The licence is shown by Drop before the attach, and the attach answers diskutil's
    /// prompt only because the user accepted.
    @Test func licenceIsShownBeforeTheMount() async throws {
        try await installThroughTheMount("licence.dmg", force: true, label: "m-licence")
    }

    @Test func decliningTheLicenceMountsNothing() async throws {
        let scratch = try Scratch("m-decline")
        defer { scratch.remove() }
        var options = scratch.options()
        options.forceMountFallback = true
        let session = InstallSession(dmg: try MountFixtures.image("licence.dmg"), options: options)
        await session.start()
        let settled = await waitFor(session) { $0.isSettled }
        guard case .needsLicence = settled else {
            Issue.record("expected the licence, got \(settled)")
            return
        }
        #expect(scratch.leftovers.isEmpty)
        await session.decline()
        #expect(await waitFor(session) { $0.isFinal } == .cancelled)
        #expect(scratch.leftovers.isEmpty)
    }

    @Test func wrongPasswordThenRightOne() async throws {
        let scratch = try Scratch("m-wrong")
        defer { scratch.remove() }
        let session = InstallSession(dmg: try MountFixtures.image("encrypted.dmg"), options: scratch.options())
        await session.start()
        #expect(await waitFor(session) { $0.isSettled } == .needsPassword(attempt: 1))
        await session.providePassword("wrong")
        #expect(await waitFor(session) { $0 == .needsPassword(attempt: 2) } == .needsPassword(attempt: 2))
        #expect(scratch.leftovers.isEmpty)
        await session.providePassword(MountPassword(MountFixtures.password))
        let settled = await waitFor(session) { $0.isSettled && $0 != .needsPassword(attempt: 2) }
        guard case .warning = settled else {
            Issue.record("expected warning, got \(settled)")
            return
        }
        await session.cancel()
        #expect(scratch.leftovers.isEmpty)
    }

    /// Staging held between files (as in Low Power Mode) keeps the image attached; cancel
    /// then detaches it.
    @Test func cancelMidStagingLeavesNoMount() async throws {
        let scratch = try Scratch("m-cancel")
        defer { scratch.remove() }
        var options = scratch.options()
        options.conditions = FakeConditions(constrained: true).conditions
        let session = InstallSession(dmg: try MountFixtures.image("sparse.sparseimage"), options: options)
        await session.start()
        let held = await waitFor(session) { if case .waitingToPrepare = $0 { true } else { $0.isFinal } }
        guard case .waitingToPrepare = held else {
            Issue.record("expected waitingToPrepare, got \(held)")
            return
        }
        #expect(await session.mount != nil)
        #expect(scratch.leftovers.count == 1)
        await session.cancel()
        #expect(await session.state == .cancelled)
        #expect(await session.mount == nil)
        #expect(scratch.leftovers.isEmpty)
        let area = try #require(await session.stagingArea)
        #expect(await waitUntilGone(area))
    }

    /// Staging fails part-way (a read of the mounted volume fails: the device is ejected
    /// under it); the session fails and the image is still detached.
    @Test func failureDuringStagingStillDetaches() async throws {
        let scratch = try Scratch("m-fail")
        defer { scratch.remove() }
        let conditions = FakeConditions(constrained: true)
        var options = scratch.options()
        options.conditions = conditions.conditions
        let session = InstallSession(dmg: try MountFixtures.image("sparse.sparseimage"), options: options)
        await session.start()
        await waitFor(session) { if case .waitingToPrepare = $0 { true } else { $0.isFinal } }
        let mount = try #require(await session.mount)
        // Unmount the volume only (the disk stays attached), so the next read fails.
        let unmounted = try runTool("/usr/sbin/diskutil", ["unmount", "force", mount.mountPoint.path])
        #expect(unmounted == 0)
        conditions.set(false)
        // A read error from the volume ends the session (as unreadable: the reader's `io`).
        let final = await waitFor(session) { $0.isFinal || $0.isSettled }
        switch final {
        case .failed, .cannotInstall(.unreadable): break
        default: Issue.record("expected the session to fail, got \(final)")
        }
        await session.waitUntilDone()
        #expect(await session.mount == nil)
        #expect(!mount.stillOurs(), "the disk was detached")
    }

    @Test func imageThatWontAttachCannotBeInstalled() async throws {
        let scratch = try Scratch("m-garbage")
        defer { scratch.remove() }
        let file = scratch.root.appending(path: "garbage.dmg")
        try Data(repeating: 0x5A, count: 64 * 1024).write(to: file)
        var options = scratch.options()
        options.forceMountFallback = true
        let session = InstallSession(dmg: file, options: options)
        await session.start()
        let final = await waitFor(session) { $0.isFinal }
        guard case .cannotInstall(.wontAttach) = final else {
            Issue.record("expected wontAttach, got \(final)")
            return
        }
        #expect(scratch.leftovers.isEmpty)
    }
}

/// Opt-in timings (`DROP_TIMING=1`): start to installed through the hidden mount, against
/// the direct path for the same image.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROP_TIMING"] == "1", "set DROP_TIMING=1"), .serialized)
struct MountFallbackTimingTests {
    func timeToInstalled(_ dmg: URL, force: Bool, password: String? = nil, label: String) async throws -> Double {
        let scratch = try Scratch(label)
        defer { scratch.remove() }
        var options = scratch.options()
        options.forceMountFallback = force
        options.stagingPriority = .userInitiated
        let clock = ContinuousClock()
        let start = clock.now
        let session = InstallSession(dmg: dmg, options: options)
        await session.start()
        var settled = await waitFor(session, timeout: .seconds(600)) { $0.isSettled }
        if case .needsLicence = settled {
            await session.acceptLicence()
            settled = await waitFor(session, timeout: .seconds(600)) { $0.isSettled && !$0.isLicence }
        }
        if let password, case .needsPassword = settled {
            await session.providePassword(password)
            settled = await waitFor(session, timeout: .seconds(600)) {
                $0.isSettled && $0 != .needsPassword(attempt: 1)
            }
        }
        await session.install()
        let state = await session.state
        guard case .installed = state else {
            Issue.record("\(dmg.lastPathComponent): expected installed, got \(state)")
            return 0
        }
        let timings = await session.timings
        let duration = clock.now - start
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        print(
            "timing \(dmg.lastPathComponent) \(timings.mounted == nil ? "direct" : "mount"): \(String(format: "%.2f", seconds)) s "
                + "(mounted \(timings.mounted.map { String(format: "%.2f", $0) } ?? "-"), "
                + "unmounted \(timings.unmounted.map { String(format: "%.2f", $0) } ?? "-"))")
        await session.waitUntilDone()
        #expect(scratch.leftovers.isEmpty)
        return seconds
    }

    @Test func encryptedFixture() async throws {
        _ = try await timeToInstalled(
            try MountFixtures.image("encrypted.dmg"), force: false, password: MountFixtures.password, label: "t-enc")
        _ = try await timeToInstalled(try Fixtures.dmg("one-app"), force: false, label: "t-direct-tiny")
    }

    @Test(arguments: [("firefox", "Firefox-160.0.dmg"), ("docker", "Docker.dmg")])
    func sampleForcedThroughTheMount(_ folder: String, _ file: String) async throws {
        let dmg = try Fixtures.sample(folder, file)
        _ = try await timeToInstalled(dmg, force: false, label: "t-direct-\(folder)")
        _ = try await timeToInstalled(dmg, force: true, label: "t-mount-\(folder)")
    }
}

/// The Zed sample's licence (RTF) on the hidden-mount path. Opt in with `DROP_CORPUS=1`.
@Suite(.enabled(if: corpusEnabled, "set DROP_CORPUS=1"), .serialized)
struct MountFallbackCorpusTests {
    @Test func zedLicenceIsShownThenMounted() async throws {
        let scratch = try Scratch("m-zed")
        defer { scratch.remove() }
        var options = scratch.options()
        options.forceMountFallback = true
        let session = InstallSession(dmg: try Fixtures.sample("zed", "Zed-aarch64.dmg"), options: options)
        await session.start()
        let shown = await waitFor(session) { $0.isSettled }
        guard case .needsLicence(let licence, _) = shown else {
            Issue.record("expected Zed's licence first, got \(shown)")
            return
        }
        #expect(!licence.languages.isEmpty)
        #expect(scratch.leftovers.isEmpty, "nothing attached before Agree")
        await session.acceptLicence()
        let settled = await waitFor(session, timeout: .seconds(300)) { $0.isSettled && !$0.isLicence }
        switch settled {
        case .ready(let summary), .warning(let summary, _): #expect(summary.bundleName == "Zed.app")
        default: Issue.record("expected ready, got \(settled)")
        }
        await session.cancel()
        await session.waitUntilDone()
        #expect(scratch.leftovers.isEmpty)
    }
}

extension InstallState {
    var isLicence: Bool { if case .needsLicence = self { true } else { false } }
}

/// Runs a tool without a shell and returns its exit status.
func runTool(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

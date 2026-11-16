import DiskImage
import Foundation
import ReaderCore
import Testing
import Verifier

@testable import Extractor
@testable import Installer

/// Sessions over the small DMGs `scripts/fixtures-installer.sh` builds.
@Suite(.serialized)
struct InstallSessionFixtureTests {
    @Test func adHocAppWarnsThenInstallsAnyway() async throws {
        let scratch = try Scratch("adhoc")
        defer { scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: scratch.options())
        await session.start()
        let settled = await waitFor(session) { $0.isSettled }
        guard case .warning(let summary, let warning) = settled else {
            Issue.record("expected warning, got \(settled)")
            return
        }
        #expect(warning == .notNotarized)
        #expect(summary.bundleName == "Tiny.app")
        #expect(summary.name == "Tiny")
        #expect(summary.version == "1.0")
        #expect(summary.bundleIdentifier == "dev.niduslabs.drop.fixture.tiny")
        #expect(summary.size > 0)
        #expect(summary.teamID == nil)
        #expect(!summary.isNotarized)
        #expect(summary.update == nil)
        #expect(scratch.installed().isEmpty, "nothing installed before install()")

        await session.install()
        let final = await session.state
        #expect(final == .installed(scratch.destination.appending(path: "Tiny.app", directoryHint: .isDirectory)))
        #expect(scratch.installed() == ["Tiny.app"])
        #expect(try quarantine(scratch.destination.appending(path: "Tiny.app")) == nil, "the DMG had none")
        let timings = await session.timings
        #expect(timings.opened != nil && timings.staged != nil && timings.verified != nil)
    }

    @Test func statesArriveInOrderOnTheStream() async throws {
        let scratch = try Scratch("stream")
        defer { scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: scratch.options())
        await session.start()
        var seen: [String] = []
        for await state in session.updates {
            seen.append(String(describing: state).prefix { $0 != "(" }.description)
            if case .warning = state { break }
        }
        #expect(seen.first == "reading")
        #expect(seen.contains("preparing"))
        #expect(seen.last == "warning")
        await session.cancel()
    }

    @Test func quarantineFromTheDMGIsKeptWithDoNotTranslocate() async throws {
        let scratch = try Scratch("quarantine")
        defer { scratch.remove() }
        let dmg = scratch.root.appending(path: "one-app.dmg")
        try FileManager.default.copyItem(at: try Fixtures.dmg("one-app"), to: dmg)
        let value = "0083;6560a8f2;Safari;7A4B1F5C-1111-2222-3333-444455556666"
        try setQuarantine(value, on: dmg)
        // The setting is on, but an ad hoc app never gets pre-approval.
        let session = InstallSession(dmg: dmg, options: scratch.options(skipPrompt: true))
        await session.start()
        await waitFor(session) { $0.isSettled }
        await session.install()
        let app = scratch.destination.appending(path: "Tiny.app")
        #expect(try quarantine(app) == "0183;6560a8f2;Safari;7A4B1F5C-1111-2222-3333-444455556666")
        #expect(try quarantine(app.appending(path: "Contents/Info.plist"))?.hasPrefix("0183;") == true)
    }

    @Test func updateSwapsAndTrashesTheOldCopy() async throws {
        let scratch = try Scratch("update")
        defer { scratch.remove() }
        let first = InstallSession(dmg: try Fixtures.dmg("one-app"), options: scratch.options())
        await first.start()
        await waitFor(first) { $0.isSettled }
        await first.install()

        let second = InstallSession(dmg: try Fixtures.dmg("one-app"), options: scratch.options())
        await second.start()
        let settled = await waitFor(second) { $0.isSettled }
        let update = try #require(settled.summary?.update)
        #expect(update.installedVersion == "1.0")
        #expect(update.developer == .installedUnsigned, "ad hoc: no Team ID to compare")
        await second.install()
        #expect(
            await second.state
                == .installed(scratch.destination.appending(path: "Tiny.app", directoryHint: .isDirectory)))
        #expect(scratch.installed() == ["Tiny.app"])
        #expect(scratch.trashed().count == 1)
        #expect(scratch.trashed().first?.hasSuffix("-Tiny.app") == true)
    }

    @Test func damagedAppIsRefusedAndNothingStays() async throws {
        let scratch = try Scratch("tampered")
        defer { scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.dmg("tampered"), options: scratch.options())
        await session.start()
        let final = await waitFor(session) { $0.isFinal }
        guard case .refused(_, .damaged) = final else {
            Issue.record("expected refused(damaged), got \(final)")
            return
        }
        let area = try #require(await session.stagingArea)
        #expect(await waitUntilGone(area))
        await session.install()
        #expect(scratch.installed().isEmpty)
    }

    @Test(arguments: [
        ("pkg-only", CannotInstallReason.packageOnly(names: ["Tiny Installer.pkg"])),
        ("two-apps", .multipleApps(names: ["Other.app", "Tiny.app"])),
        ("no-app", .noApp),
    ])
    func cannotInstall(_ name: String, _ reason: CannotInstallReason) async throws {
        let scratch = try Scratch(name)
        defer { scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.dmg(name), options: scratch.options())
        await session.start()
        #expect(await waitFor(session) { $0.isFinal } == .cannotInstall(reason))
        #expect(await session.stagingArea == nil, "nothing staged")
    }

    @Test func notADiskImageCannotBeInstalled() async throws {
        let scratch = try Scratch("garbage")
        defer { scratch.remove() }
        let file = scratch.root.appending(path: "garbage.dmg")
        try Data(repeating: 0x5A, count: 64 * 1024).write(to: file)
        let spy = MountFallbackSpy()
        let session = InstallSession(dmg: file, options: scratch.options(mountFallback: spy))
        await session.start()
        let final = await waitFor(session) { $0.isFinal }
        // Raw bytes with no partition map or filesystem: either verdict is acceptable, but
        // never a crash, a hang or a staged copy.
        switch final {
        case .cannotInstall(.unreadable), .cannotInstall(.wontAttach): break
        default: Issue.record("unexpected \(final)")
        }
    }

    @Test func encryptedImageAsksForAPassword() async throws {
        try #require(
            FileManager.default.fileExists(atPath: Fixtures.encrypted.path), "run scripts/fixtures-diskimage.sh")
        let scratch = try Scratch("encrypted")
        defer { scratch.remove() }
        let spy = MountFallbackSpy()
        let session = InstallSession(dmg: Fixtures.encrypted, options: scratch.options(mountFallback: spy))
        await session.start()
        #expect(await waitFor(session) { $0.isSettled } == .needsPassword(attempt: 1))
        #expect(spy.recorded == [.encrypted])
        await session.cancel()
        #expect(await session.state == .cancelled)
    }

    @Test func notNowDeletesTheStagedCopy() async throws {
        let scratch = try Scratch("notnow")
        defer { scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: scratch.options())
        await session.start()
        await waitFor(session) { $0.isSettled }
        let area = try #require(await session.stagingArea)
        #expect(exists(area.url))
        await session.notNow()
        #expect(await session.state == .cancelled)
        #expect(!exists(area.url))
        #expect(await waitUntilGone(area))
        await session.install()
        #expect(scratch.installed().isEmpty, "install after cancel does nothing")
    }

    @Test func unwritableDestinationFails() async throws {
        let scratch = try Scratch("missing")
        defer { scratch.remove() }
        var options = scratch.options()
        options.destination = scratch.root.appending(path: "does-not-exist")
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: options)
        await session.start()
        let final = await waitFor(session) { $0.isFinal }
        guard case .failed(.extractor(.destinationNotWritable)) = final else {
            Issue.record("expected destinationNotWritable, got \(final)")
            return
        }
    }
}

struct ProgressThrottleTests {
    @Test func letsThroughOnePerStep() {
        let throttle = ProgressThrottle(steps: 10)
        var emitted = 0
        for done in stride(from: UInt64(0), through: 1000, by: 1) {
            if throttle.shouldEmit(StageProgress(bytesDone: done, bytesTotal: 1000)) { emitted += 1 }
        }
        #expect(emitted == 11, "0 %, 10 %, ... 100 %")
        #expect(!throttle.shouldEmit(StageProgress(bytesDone: 500, bytesTotal: 1000)), "never goes backwards")
    }

    @Test func emptyAppIsOneUpdate() {
        let throttle = ProgressThrottle(steps: 100)
        #expect(throttle.shouldEmit(StageProgress(bytesDone: 0, bytesTotal: 0)))
        #expect(!throttle.shouldEmit(StageProgress(bytesDone: 0, bytesTotal: 0)))
    }
}

struct BundleInfoTests {
    private func plist(_ dictionary: [String: String]) throws -> [UInt8] {
        Array(try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0))
    }

    @Test func readsTheKeysThePanelShows() throws {
        let info = try #require(
            BundleInfo(
                plist: try plist([
                    "CFBundleName": "Thing", "CFBundleDisplayName": "The Thing", "CFBundleShortVersionString": "2.1",
                    "CFBundleIdentifier": "com.example.thing", "CFBundleIconFile": "AppIcon",
                ])))
        #expect(info.displayName == "The Thing")
        #expect(info.shortVersion == "2.1")
        #expect(info.identifier == "com.example.thing")
    }

    @Test func rejectsWhatIsNotADictionaryPlist() {
        #expect(BundleInfo(plist: Array("not a plist".utf8)) == nil)
        #expect(BundleInfo(plist: [UInt8](repeating: 0, count: Int(BundleInfo.maxPlistSize) + 1)) == nil)
    }

    @Test func iconMustBeARegularFileInsideResources() throws {
        let scratch = try Scratch("icon")
        defer { scratch.remove() }
        let app = scratch.root.appending(path: "Thing.app")
        let resources = app.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data([1]).write(to: resources.appending(path: "AppIcon.icns"))
        try FileManager.default.createSymbolicLink(
            at: resources.appending(path: "Linked.icns"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        func icon(_ name: String) throws -> URL? {
            try #require(BundleInfo(plist: try plist(["CFBundleIconFile": name]))).iconURL(inStagedApp: app)
        }
        #expect(try icon("AppIcon")?.lastPathComponent == "AppIcon.icns")
        #expect(try icon("AppIcon.icns")?.lastPathComponent == "AppIcon.icns")
        #expect(try icon("Linked") == nil, "a symlink is not followed")
        #expect(try icon("../../../etc/hosts") == nil)
        #expect(try icon("Missing") == nil)
    }
}

import DiskImage
import Foundation
import Testing
import Verifier

@testable import Extractor
@testable import Installer

/// End-to-end sessions on real DMGs from `.claude/samples/`. Opt in with `DROP_CORPUS=1`.
/// The samples are untrusted: staged, checked and renamed, never launched.
@Suite(.enabled(if: corpusEnabled, "set DROP_CORPUS=1"), .serialized)
struct InstallSessionCorpusTests {
    /// Rectangle's DMG is stapled and its app is not: the session staples it.
    @Test func rectangleIsStapledAndReady() async throws {
        let scratch = try Scratch("rectangle")
        defer { scratch.remove() }
        let session = InstallSession(
            dmg: try Fixtures.sample("rectangle", "Rectangle2.0.4.dmg"), options: scratch.options())
        await session.start()
        let settled = await waitFor(session) { $0.isSettled }
        guard case .ready(let summary) = settled else {
            Issue.record("expected ready, got \(settled)")
            return
        }
        #expect(summary.name == "Rectangle")
        #expect(summary.version == "2.0.4")
        #expect(summary.bundleIdentifier == "com.knollsoft.Rectangle")
        #expect(summary.teamID == "XSYZ3E4B7D")
        #expect(summary.isNotarized)
        #expect(summary.iconData?.prefix(4) == Data("icns".utf8))
        await session.install()
        let app = scratch.destination.appending(path: "Rectangle.app")
        #expect(try Verifier.ticket(inApp: app) != nil, "the DMG's ticket was stapled into the app")
        #expect(await Verifier.validate(app: app) == .valid)
    }

    /// A quarantined, notarized app with the skip-prompt setting on gets the approved flag.
    @Test func skipPromptPreApprovesANotarizedApp() async throws {
        let scratch = try Scratch("approved")
        defer { scratch.remove() }
        let dmg = scratch.root.appending(path: "Rectangle.dmg")
        try FileManager.default.copyItem(at: try Fixtures.sample("rectangle", "Rectangle2.0.4.dmg"), to: dmg)
        try setQuarantine("0083;6560a8f2;Safari;7A4B1F5C-1111-2222-3333-444455556666", on: dmg)
        let session = InstallSession(dmg: dmg, options: scratch.options(skipPrompt: true))
        await session.start()
        await waitFor(session) { $0.isSettled }
        await session.install()
        let app = scratch.destination.appending(path: "Rectangle.app")
        #expect(try quarantine(app)?.hasPrefix("01c3;") == true, "0x0083 | 0x0100 | 0x0040")
    }

    @Test func zedAsksForTheLicenceFirst() async throws {
        let scratch = try Scratch("zed")
        defer { scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.sample("zed", "Zed-aarch64.dmg"), options: scratch.options())
        await session.start()
        let first = await waitFor(session) { $0.isSettled }
        guard case .needsLicence(let licence, let preview) = first else {
            Issue.record("expected needsLicence, got \(first)")
            return
        }
        #expect(!licence.languages.isEmpty)
        #expect(preview?.name == "Zed", "the licence screen names the app, not the file")
        #expect(await session.stagingArea == nil, "nothing staged before the licence is accepted")
        await session.acceptLicence()
        let settled = await waitFor(session) {
            if case .needsLicence = $0 { return false }
            return $0.isSettled
        }
        guard case .ready(let summary) = settled else {
            Issue.record("expected ready, got \(settled)")
            return
        }
        #expect(summary.name == "Zed")
        await session.cancel()
    }

    @Test func zedDeclinedLeavesNothing() async throws {
        let scratch = try Scratch("zed-decline")
        defer { scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.sample("zed", "Zed-aarch64.dmg"), options: scratch.options())
        await session.start()
        await waitFor(session) { $0.isSettled }
        await session.decline()
        #expect(await waitFor(session) { $0.isFinal } == .cancelled)
        #expect(await session.stagingArea == nil)
    }

    /// Slack staged earlier stands in for the installed copy: same version, same team.
    @Test func slackUpdateSwapsAndTrashesTheOldCopy() async throws {
        let scratch = try Scratch("slack")
        defer { scratch.remove() }
        let dmg = try Fixtures.sample("slack", "Slack-4.53.287-macOS.dmg")
        let first = InstallSession(dmg: dmg, options: scratch.options())
        await first.start()
        await waitFor(first) { $0.isSettled }
        await first.install()
        try #require(scratch.installed() == ["Slack.app"])

        let second = InstallSession(dmg: dmg, options: scratch.options())
        await second.start()
        let settled = await waitFor(second) { $0.isSettled }
        guard case .ready(let summary) = settled else {
            Issue.record("expected ready, got \(settled)")
            return
        }
        #expect(summary.update?.installedVersion == summary.version)
        #expect(summary.version == "4.53.287")
        #expect(summary.update?.developer == .same(teamID: "BQR82RBBHL"))
        print("slack timings: first \(await first.timings), second \(await second.timings)")
        await second.install()
        #expect(scratch.installed() == ["Slack.app"])
        #expect(scratch.trashed().count == 1, "the old copy went to the test trash")
    }

    /// Cancelling Docker partway through staging leaves no staged files behind.
    @Test func cancelMidPreparingLeavesNothing() async throws {
        let scratch = try Scratch("cancel")
        defer { scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.sample("docker", "Docker.dmg"), options: scratch.options())
        await session.start()
        let preparing = await waitFor(session) {
            if case .preparing(_, let progress) = $0 { return progress.bytesDone > 0 }
            return $0.isFinal
        }
        try #require(preparing.isPreparing, "got \(preparing)")
        let area = try #require(await session.stagingArea)
        await session.cancel()
        #expect(await session.state == .cancelled)
        #expect(await waitUntilGone(area), "staging area still on disk")
        #expect(scratch.installed().isEmpty)
    }

    /// Install mid-preparing switches the image's decode policy from background to fast.
    @Test func boostSwitchesTheDecodePolicy() async throws {
        let scratch = try Scratch("boost")
        defer { scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.sample("docker", "Docker.dmg"), options: scratch.options())
        await session.start()
        let preparing = await waitFor(session) {
            if case .preparing(_, let progress) = $0 { return progress.bytesDone > 0 }
            return $0.isFinal
        }
        try #require(preparing.isPreparing, "got \(preparing)")
        #expect(await session.decodePolicy == .background)
        let install = Task { await session.install() }
        await waitFor(session, timeout: .seconds(5)) {
            if case .installing = $0 { return true }
            return false
        }
        #expect(await session.decodePolicy == .fast)
        await install.value
        let docker = scratch.destination.appending(path: "Docker.app", directoryHint: .isDirectory)
        #expect(await session.state == .installed(docker))
        #expect(await session.timings.boosted != nil)
    }
}

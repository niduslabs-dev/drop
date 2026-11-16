import Foundation
import Installer
import Testing

@testable import DropApp

/// Drop's own disk image: which board it gets, and what Check for Updates does.
struct SelfImageTests {
    private static let release = SelfImage.Running(
        bundleIdentifier: SelfImage.releaseIdentifier, version: "1.0.0", build: "1.0.0")
    private static let debug = SelfImage.Running(
        bundleIdentifier: SelfImage.debugIdentifier, version: "1.0.0", build: "1.0.0")

    private func summary(_ identifier: String?, _ version: String?, build: String? = nil) -> AppSummary {
        AppSummary(
            bundleName: "Drop.app", name: "Drop", version: version, bundleIdentifier: identifier, size: nil,
            buildVersion: build)
    }

    @Test func aNewerDropPointsToCheckForUpdates() throws {
        let offer = try #require(SelfImage.offer(for: summary("dev.niduslabs.drop", "1.0.1"), running: Self.release))
        #expect(offer.kind == .newer)
        #expect(offer.title == "Drop 1.0.1")
        #expect(offer.subtitle == "You have 1.0.0")
        #expect(offer.message == "Drop updates itself. Check for Updates installs this version and restarts Drop.")
        #expect(offer.primary == .init(title: "Check for Updates", action: .checkForUpdates))
        #expect(offer.secondary == .init(title: "Not now", action: .notNow))
    }

    @Test func theSameDropHasNothingToInstall() throws {
        let offer = try #require(SelfImage.offer(for: summary("dev.niduslabs.drop", "1.0.0"), running: Self.release))
        #expect(offer.kind == .notNewer)
        #expect(offer.title == "Drop 1.0.0")
        #expect(offer.subtitle == "You have 1.0.0")
        #expect(offer.message == "This is your copy of Drop or an older one. There's nothing to install.")
        #expect(offer.primary == .init(title: "Done", action: .close))
        #expect(offer.secondary == nil)
    }

    @Test func anOlderDropHasNothingToInstall() throws {
        let running = SelfImage.Running(bundleIdentifier: SelfImage.releaseIdentifier, version: "1.0.1", build: "1.0.1")
        let offer = try #require(SelfImage.offer(for: summary("dev.niduslabs.drop", "1.0.0"), running: running))
        #expect(offer.kind == .notNewer)
        #expect(offer.title == "Drop 1.0.0")
        #expect(offer.subtitle == "You have 1.0.1")
    }

    @Test func versionsCompareAsNumbersThenBuilds() {
        #expect(SelfImage.isNewer(version: "1.0.10", build: nil, than: "1.0.9", build: nil))
        #expect(!SelfImage.isNewer(version: "1.0.9", build: nil, than: "1.0.10", build: nil))
        #expect(SelfImage.isNewer(version: "1.1", build: nil, than: "1.0.5", build: nil))
        #expect(!SelfImage.isNewer(version: "1.0", build: nil, than: "1.0.0", build: nil), "1.0 is 1.0.0")
        #expect(SelfImage.isNewer(version: "1.0.0", build: "12", than: "1.0.0", build: "9"))
        #expect(!SelfImage.isNewer(version: "1.0.0", build: "9", than: "1.0.0", build: "12"))
        #expect(!SelfImage.isNewer(version: "1.0.0", build: nil, than: "1.0.0", build: "9"))
        #expect(!SelfImage.isNewer(version: nil, build: "99", than: "1.0.0", build: "1"), "no version: never newer")
    }

    @Test func releaseAndDebugIDsAreDropForBothBuilds() {
        for running in [Self.release, Self.debug] {
            for identifier in [SelfImage.releaseIdentifier, SelfImage.debugIdentifier] {
                #expect(SelfImage.offer(for: summary(identifier, "1.0.1"), running: running)?.kind == .newer)
            }
        }
        // A test build with another ID still recognises an image of itself.
        let other = SelfImage.Running(bundleIdentifier: "dev.example.drop-fork", version: "1.0.0", build: nil)
        #expect(SelfImage.offer(for: summary("dev.example.drop-fork", "1.0.0"), running: other)?.kind == .notNewer)
    }

    @Test func otherAppsAreUnaffected() {
        #expect(SelfImage.offer(for: summary("com.example.linea", "9.9"), running: Self.release) == nil)
        #expect(SelfImage.offer(for: summary(nil, "9.9"), running: Self.release) == nil)
        #expect(SelfImage.offer(for: summary("dev.niduslabs.dropper", "9.9"), running: Self.release) == nil)
    }

    @Test @MainActor func checkForUpdatesRunsTheInjectedChecker() {
        var checks = 0
        let enabled = UpdateCheck(isAvailable: { true }, start: { checks += 1 })
        #expect(enabled.run())
        #expect(checks == 1)

        // Debug builds have no updater: it only logs.
        let disabled = UpdateCheck(isAvailable: { false }, start: { checks += 1 })
        #expect(!disabled.run())
        #expect(checks == 1)
    }

    @Test @MainActor func theLiveCheckUsesSettingsCheckForUpdates() {
        let updates = UpdateModel(currentVersion: "1.0.0", isEnabled: true)
        var requested = 0
        updates.requestCheck = { requested += 1 }
        #expect(UpdateCheck.live(updates).run())
        #expect(requested == 1)
        updates.isEnabled = false
        #expect(!UpdateCheck.live(updates).run())
        #expect(requested == 1)
    }

    @Test @MainActor func theModelShowsTheSelfImageBoard() throws {
        let model = PanelModel(
            dmg: URL(filePath: "/tmp/Drop-1.0.1.dmg"), origin: .watched(folderName: "Downloads"),
            location: .applications, trashImage: false)
        model.state = .identified(summary("dev.niduslabs.drop", "1.0.1"))
        #expect(model.board == .main)
        model.selfImage = SelfImage.offer(for: try #require(model.summary), running: Self.release)
        #expect(model.board == .selfImage)
    }
}

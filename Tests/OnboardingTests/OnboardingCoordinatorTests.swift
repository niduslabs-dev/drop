import Foundation
import Onboarding
import Testing

/// Folder access that answers as told and counts how often it was asked.
private final class FakeFolderAccess: FolderAccessChecking, @unchecked Sendable {
    var result: FolderAccessResult
    private(set) var requests: [URL] = []

    init(_ result: FolderAccessResult) { self.result = result }

    func requestAccess(to folder: URL) async -> FolderAccessResult {
        requests.append(folder)
        return result
    }
}

@MainActor
private final class FakeDefaultHandler: DefaultHandlerSetting {
    var becomesDefault: Bool
    private(set) var calls = 0

    init(becomesDefault: Bool) { self.becomesDefault = becomesDefault }

    func makeDropDefault() async -> Bool {
        calls += 1
        return becomesDefault
    }
}

private struct RegisterFailed: Error {}

@MainActor
private final class FakeLoginItem: LoginItemRegistering {
    var fails: Bool
    private(set) var calls = 0

    init(fails: Bool) { self.fails = fails }

    func register() throws {
        calls += 1
        if fails { throw RegisterFailed() }
    }
}

/// One coordinator over a private defaults domain, with its fakes and what its callbacks saw.
@MainActor
private final class Harness {
    let suite = "dev.niduslabs.drop.onboarding-tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let folder = FakeFolderAccess(.granted)
    let handler = FakeDefaultHandler(becomesDefault: true)
    let login = FakeLoginItem(fails: false)
    let downloads = URL(filePath: "/Users/Shared/Downloads", directoryHint: .isDirectory)
    var watchingAllowed = 0
    var chosenFolders: [URL] = []
    var defaultResults: [Bool] = []
    var loginChoices: [Bool] = []
    var ended = 0

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    /// A coordinator as the app makes one at launch, reading what earlier ones saved.
    func launch() -> OnboardingCoordinator {
        let coordinator = OnboardingCoordinator(
            defaults: defaults, folderAccess: folder, defaultHandler: handler, loginItem: login)
        coordinator.onWatchingAllowed = { self.watchingAllowed += 1 }
        coordinator.onFolderChosen = { self.chosenFolders.append($0) }
        coordinator.onDefaultHandlerChanged = { self.defaultResults.append($0) }
        coordinator.onLoginItemChosen = { self.loginChoices.append($0) }
        coordinator.onEnd = { self.ended += 1 }
        return coordinator
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }
}

@MainActor
@Suite struct OnboardingCoordinatorTests {
    @Test func firstLaunchAsksForNothing() {
        let harness = Harness()
        let onboarding = harness.launch()
        #expect(onboarding.showsAtLaunch)
        #expect(!onboarding.allowsWatching)
        #expect(!onboarding.isComplete)
        #expect(onboarding.page == .welcome)
        #expect(harness.folder.requests.isEmpty)
        #expect(harness.handler.calls == 0)
        #expect(harness.login.calls == 0)
    }

    @Test func everythingAllowed() async {
        let harness = Harness()
        let onboarding = harness.launch()
        onboarding.getStarted()
        #expect(harness.folder.requests.isEmpty)
        await onboarding.allowFolder(harness.downloads)
        #expect(harness.folder.requests == [harness.downloads])
        #expect(onboarding.allowsWatching)
        #expect(harness.watchingAllowed == 1)
        #expect(onboarding.page == .diskImages)
        #expect(harness.handler.calls == 0)
        await onboarding.useDrop()
        #expect(harness.defaultResults == [true])
        #expect(onboarding.state.defaultHandler == .madeDefault)
        #expect(harness.login.calls == 0)
        onboarding.startAtLogin()
        #expect(harness.login.calls == 1)
        #expect(harness.loginChoices == [true])
        #expect(onboarding.page == .done)
        onboarding.finish()
        #expect(onboarding.isComplete)
        #expect(harness.ended == 1)

        let relaunched = harness.launch()
        #expect(!relaunched.showsAtLaunch)
        #expect(relaunched.allowsWatching)
        #expect(relaunched.state.reached == .done)
        #expect(relaunched.state.loginItem == .registered)
    }

    @Test func deniedStaysOnThePage() async {
        let harness = Harness()
        harness.folder.result = .denied
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        #expect(onboarding.page == .downloads)
        #expect(onboarding.showsFolderDenied)
        #expect(!onboarding.allowsWatching)
        #expect(harness.watchingAllowed == 0)

        onboarding.continueWithoutFolder()
        #expect(onboarding.page == .diskImages)
        #expect(!onboarding.showsFolderDenied)
        #expect(!onboarding.allowsWatching)
    }

    @Test func allowAgainAfterSystemSettings() async {
        let harness = Harness()
        harness.folder.result = .denied
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        harness.folder.result = .granted
        await onboarding.allowFolder(harness.downloads)
        #expect(onboarding.state.folderAccess == .granted)
        #expect(onboarding.page == .diskImages)
    }

    @Test func otherErrorsCountAsDenied() async {
        let harness = Harness()
        harness.folder.result = .failed(ENOENT)
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        #expect(onboarding.showsFolderDenied)
    }

    @Test func anotherFolder() {
        let harness = Harness()
        let onboarding = harness.launch()
        onboarding.getStarted()
        let other = URL(filePath: "/Users/Shared/Installers", directoryHint: .isDirectory)
        onboarding.useFolder(other)
        #expect(harness.chosenFolders == [other])
        #expect(harness.folder.requests.isEmpty)
        #expect(harness.watchingAllowed == 1)
        #expect(onboarding.allowsWatching)
        #expect(onboarding.page == .diskImages)
    }

    @Test func useDropDeclinedInTheDialogStillMovesOn() async {
        let harness = Harness()
        harness.handler.becomesDefault = false
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        await onboarding.useDrop()
        #expect(harness.defaultResults == [false])
        #expect(onboarding.state.defaultHandler == .declined)
        #expect(onboarding.page == .loginItem)
    }

    @Test func notNowAsksNothing() async {
        let harness = Harness()
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        onboarding.skipDefaultHandler()
        onboarding.skipLoginItem()
        #expect(harness.handler.calls == 0)
        #expect(harness.login.calls == 0)
        #expect(harness.defaultResults.isEmpty)
        #expect(harness.loginChoices == [false])
        #expect(onboarding.state.defaultHandler == .skipped)
        #expect(onboarding.state.loginItem == .skipped)
        #expect(onboarding.page == .done)
    }

    @Test func loginItemFailureMovesOn() async {
        let harness = Harness()
        harness.login.fails = true
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        onboarding.skipDefaultHandler()
        onboarding.startAtLogin()
        #expect(onboarding.state.loginItem == .failed)
        #expect(onboarding.page == .done)
    }

    @Test func closedEarlyWithoutAccessComesBack() async {
        let harness = Harness()
        let onboarding = harness.launch()
        onboarding.getStarted()
        onboarding.windowClosed()
        #expect(harness.ended == 1)
        #expect(onboarding.state.outcome == .dismissed)
        #expect(onboarding.state.reshowReason == .folderAccessNotGranted)
        #expect(!onboarding.allowsWatching)
        #expect(harness.folder.requests.isEmpty)

        let relaunched = harness.launch()
        #expect(relaunched.showsAtLaunch)
        #expect(!relaunched.allowsWatching)
        #expect(relaunched.page == .downloads)
        relaunched.reopened()
        #expect(relaunched.state.outcome == .inProgress)
    }

    @Test func closedOnTheWelcomePageComesBackThere() {
        let harness = Harness()
        harness.launch().windowClosed()
        let relaunched = harness.launch()
        #expect(relaunched.showsAtLaunch)
        #expect(relaunched.page == .welcome)
    }

    @Test func closedEarlyAfterDeniedComesBack() async {
        let harness = Harness()
        harness.folder.result = .denied
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        onboarding.continueWithoutFolder()
        onboarding.windowClosed()
        let relaunched = harness.launch()
        #expect(relaunched.showsAtLaunch)
        #expect(relaunched.page == .downloads)
    }

    @Test func closedEarlyAfterAccessDoesNotComeBack() async {
        let harness = Harness()
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        onboarding.windowClosed()
        #expect(onboarding.state.outcome == .dismissed)
        #expect(onboarding.state.reshowReason == nil)
        #expect(!onboarding.isComplete)

        let relaunched = harness.launch()
        #expect(!relaunched.showsAtLaunch)
        #expect(relaunched.allowsWatching)
        #expect(relaunched.state.defaultHandler == .notAsked)
        #expect(relaunched.state.loginItem == .notAsked)
    }

    @Test func closingOnTheLastPageIsDone() async {
        let harness = Harness()
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        onboarding.skipDefaultHandler()
        onboarding.skipLoginItem()
        onboarding.windowClosed()
        #expect(onboarding.isComplete)
        #expect(harness.ended == 1)
        #expect(!harness.launch().showsAtLaunch)
    }

    @Test func completedAfterContinueAnywayMayWatch() async {
        let harness = Harness()
        harness.folder.result = .denied
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        onboarding.continueWithoutFolder()
        onboarding.skipDefaultHandler()
        onboarding.skipLoginItem()
        onboarding.finish()
        #expect(onboarding.allowsWatching)
        #expect(!harness.launch().showsAtLaunch)
    }

    @Test func closeAfterDoneDoesNothing() async {
        let harness = Harness()
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        onboarding.skipDefaultHandler()
        onboarding.skipLoginItem()
        onboarding.finish()
        onboarding.windowClosed()
        #expect(harness.ended == 1)
        #expect(onboarding.state.outcome == .completed)
    }

    @Test func backKeepsWhatWasReached() async {
        let harness = Harness()
        let onboarding = harness.launch()
        onboarding.goBack()
        #expect(onboarding.page == .welcome)
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        onboarding.goBack()
        #expect(onboarding.page == .downloads)
        #expect(onboarding.state.reached == .diskImages)
        #expect(onboarding.allowsWatching)
    }

    @Test func resetForgetsEverything() async {
        let harness = Harness()
        let onboarding = harness.launch()
        onboarding.getStarted()
        await onboarding.allowFolder(harness.downloads)
        onboarding.windowClosed()
        OnboardingCoordinator.reset(in: harness.defaults)
        let relaunched = harness.launch()
        #expect(relaunched.state == OnboardingState())
        #expect(relaunched.showsAtLaunch)
    }
}

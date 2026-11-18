import AppKit
import Sparkle

/// Runs Sparkle with Drop's own surfaces. Sparkle does the daily check, the download at
/// background priority, the EdDSA and code signature checks and the swap; this object turns
/// its events into `UpdateModel` changes, so none of Sparkle's windows ever appear.
///
/// Only release builds update. Debug and test launches never start Sparkle unless a debug
/// launch passes `--update-feed <url>`, which points it at a local test appcast: a debug
/// copy has its own bundle ID and must never replace itself with a release build.
@MainActor
final class UpdateDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    let model: UpdateModel
    private var updater: SPUUpdater?
    /// `--update-feed`, debug only.
    private let feedOverride: URL?
    /// The download's length, once the server sends it, and what has arrived so far.
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    /// A test feed starts with a background check unless the launch starts its own.
    private let checksAtStart: Bool

    init(model: UpdateModel, feedOverride: URL? = nil, checksAtStart: Bool = true) {
        self.model = model
        self.feedOverride = feedOverride
        self.checksAtStart = checksAtStart
        super.init()
    }

    /// Starts Sparkle's scheduler. A start failure (no feed URL or public key in Info.plist,
    /// a bundle Sparkle can't update) is logged and leaves updates off.
    func start() {
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
        } catch {
            Log.updates.error("Updater didn't start: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.updater = updater
        updater.automaticallyChecksForUpdates = true
        model.isEnabled = true
        model.automatic = updater.automaticallyDownloadsUpdates
        model.lastChecked = updater.lastUpdateCheckDate
        model.requestCheck = { [weak self] in self?.checkNow() }
        model.automaticChanged = { [weak self] in self?.updater?.automaticallyDownloadsUpdates = $0 }
        if feedOverride != nil, checksAtStart { updater.checkForUpdatesInBackground() }
    }

    private func checkNow() {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? { feedOverride?.absoluteString }

    /// A debug copy run against a test feed installs but never relaunches: the relaunch would
    /// be a plain launch, without `--background-test`, and could take focus.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { feedOverride == nil }

    /// A background download is ready. Returning true keeps Sparkle from presenting it
    /// later itself; it still installs when Drop quits (Later), or at once through
    /// `immediateInstallHandler` (Restart to Update).
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Log.updates.info("Update \(item.displayVersionString, privacy: .public) downloaded; installs on quit")
        model.readyOnQuit(Self.update(from: item), installNow: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        model.lastChecked = updater.lastUpdateCheckDate
    }

    // MARK: SPUUserDriver

    /// Never shown: `SUEnableAutomaticChecks` is set, so this is only a fallback.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { model.checkStarted() }

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // An information-only item has nothing to install; Drop has no surface for it.
        guard !appcastItem.isInformationOnlyUpdate else {
            Log.updates.info("Information-only update \(appcastItem.displayVersionString, privacy: .public) ignored")
            model.notFound()
            reply(.dismiss)
            return
        }
        model.found(
            Self.update(from: appcastItem), downloaded: state.stage != .notDownloaded,
            userInitiated: state.userInitiated
        ) { reply(Self.choice($0)) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        model.notFound()
        model.lastChecked = updater?.lastUpdateCheckDate ?? .now
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        model.failed(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        model.downloadStarted()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
        if expectedLength > 0 { model.downloadProgressed(0) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        // No percentage until the length is known ("Downloading 1.1…").
        guard expectedLength > 0 else { return }
        model.downloadProgressed(Double(receivedLength) / Double(expectedLength))
    }

    /// Unpacking, then Sparkle checks both signatures: "Preparing 1.1…".
    func showDownloadDidStartExtractingUpdate() { model.preparing() }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.readyToInstall { reply(Self.choice($0)) }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void
    ) {
        model.installing()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        model.cycleEnded()
    }

    // MARK: Mapping

    private static func choice(_ reply: UpdateReply) -> SPUUserUpdateChoice {
        switch reply {
        case .install: .install
        case .dismiss: .dismiss
        }
    }

    static func update(from item: SUAppcastItem) -> AvailableUpdate {
        AvailableUpdate(
            version: item.displayVersionString,
            size: item.contentLength > 0 ? item.contentLength : nil,
            notes: ReleaseNotes.lines(from: item.itemDescription),
            releaseNotesURL: item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL)
    }
}

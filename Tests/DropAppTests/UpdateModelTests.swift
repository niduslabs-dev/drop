import Foundation
import Testing

@testable import DropApp

/// The update rules from the Updates board, driven through `UpdateModel` the way
/// `UpdateDriver` drives it from Sparkle's events, with Sparkle's replies recorded.
@MainActor
struct UpdateModelTests {
    private let update = AvailableUpdate(
        version: "1.1", size: 4_000_000, notes: ["One", "Two"],
        releaseNotesURL: URL(string: "https://github.com/niduslabs-dev/drop/releases/tag/v1.1"))

    private struct Failure: Error {}

    /// Collects what the model told Sparkle.
    private final class Recorder {
        var replies: [UpdateReply] = []
        var installNowCalls = 0
        var checks = 0
    }

    private func makeModel(automatic: Bool = true) -> (UpdateModel, Recorder) {
        let model = UpdateModel(currentVersion: "1.0", automatic: automatic, isEnabled: true)
        let recorder = Recorder()
        model.requestCheck = { recorder.checks += 1 }
        return (model, recorder)
    }

    // MARK: Ready

    @Test func backgroundDownloadShowsThePopupAndBanner() {
        let (model, recorder) = makeModel()
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        #expect(model.phase == .ready(update, afterLater: false))
        #expect(model.wantsPopup)
        #expect(model.isReady)
        #expect(model.popupTitle == "Drop 1.1 is ready")
        #expect(model.sizeDetail == "4 MB, downloaded")
    }

    @Test func restartInstallsThroughSparklesHandler() {
        let (model, recorder) = makeModel()
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        model.perform(.restart, from: .popup)
        #expect(recorder.installNowCalls == 1)
        #expect(model.phase == .installing(update))
        #expect(!model.wantsPopup)
    }

    @Test func downloadedUpdateFoundIsReadyAndRestartRepliesInstall() {
        let (model, recorder) = makeModel()
        model.found(update, downloaded: true, userInitiated: true) { recorder.replies.append($0) }
        #expect(model.phase == .ready(update, afterLater: false))
        #expect(model.wantsPopup)
        model.perform(.restart)
        #expect(recorder.replies == [.install])
        #expect(model.phase == .installing(update))
    }

    // MARK: Later

    @Test func laterHidesThePopupAndKeepsTheBanner() {
        let (model, recorder) = makeModel()
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        model.perform(.later, from: .popup)
        #expect(!model.wantsPopup)
        #expect(model.isReady, "installs on quit; the Settings banner stays")
        #expect(recorder.installNowCalls == 0)
    }

    @Test func laterAnswersAWaitingPromptWithDismiss() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        model.perform(.download, from: .popup)
        model.readyToInstall { recorder.replies.append($0) }
        model.perform(.later, from: .popup)
        #expect(recorder.replies == [.install, .dismiss])
        #expect(model.isReady)
        // Sparkle ends the cycle after the dismiss; the update still installs on quit.
        model.cycleEnded()
        #expect(model.isReady)
    }

    @Test func restartAfterLaterAsksSparkleAgainAndInstalls() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        model.perform(.download, from: .popup)
        model.readyToInstall { recorder.replies.append($0) }
        model.perform(.later, from: .popup)
        model.cycleEnded()
        // The banner's Restart to Update: nothing to answer, so a check brings the armed
        // update back as a prompt, answered with install.
        model.perform(.restart)
        #expect(recorder.checks == 1)
        model.found(update, downloaded: true, userInitiated: true) { recorder.replies.append($0) }
        #expect(recorder.replies == [.install, .dismiss, .install])
        #expect(model.phase == .installing(update))
        #expect(!model.wantsPopup)
    }

    // MARK: Automatic installs off

    @Test func automaticOffAsksBeforeDownloading() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        #expect(model.phase == .available(update))
        #expect(model.wantsPopup)
        #expect(model.popupTitle == "Drop 1.1 is available")
        #expect(model.sizeDetail == "4 MB")
        #expect(recorder.replies.isEmpty, "nothing downloads until Download")
        model.perform(.download, from: .popup)
        #expect(recorder.replies == [.install])
        #expect(model.phase == .downloading(update, fraction: nil))
        #expect(!model.wantsPopup)
        model.readyToInstall { recorder.replies.append($0) }
        #expect(model.phase == .ready(update, afterLater: false))
        #expect(model.wantsPopup)
    }

    @Test func automaticOnDownloadsAUserCheckStraightAway() {
        let (model, recorder) = makeModel(automatic: true)
        model.checkStarted()
        #expect(model.phase == .checking)
        model.found(update, downloaded: false, userInitiated: true) { recorder.replies.append($0) }
        #expect(recorder.replies == [.install])
        #expect(model.phase == .downloading(update, fraction: nil))
        #expect(!model.wantsPopup)
    }

    @Test func switchChangesReachSparkle() {
        let (model, _) = makeModel(automatic: true)
        var sent: [Bool] = []
        model.automaticChanged = { sent.append($0) }
        model.automatic = false
        model.automatic = false
        model.automatic = true
        #expect(sent == [false, true])
    }

    // MARK: Failures

    @Test func failureIsSilent() {
        let (model, recorder) = makeModel()
        let checked = Date(timeIntervalSince1970: 1_000)
        model.lastChecked = checked
        model.checkStarted()
        model.failed(Failure())
        #expect(model.phase == .idle)
        #expect(!model.wantsPopup)
        #expect(model.lastChecked == checked, "a failed check isn't a check")
        #expect(recorder.replies.isEmpty)
    }

    @Test func failureMidDownloadDropsIt() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        model.perform(.download, from: .popup)
        model.failed(Failure())
        #expect(model.phase == .idle)
        #expect(!model.wantsPopup)
    }

    @Test func failureKeepsAReadyUpdate() {
        let (model, recorder) = makeModel()
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        model.perform(.later, from: .popup)
        model.failed(Failure())
        #expect(model.isReady)
        #expect(!model.wantsPopup)
    }

    @Test func checkFindingNothingGoesBackToIdle() {
        let (model, _) = makeModel()
        model.checkStarted()
        model.notFound()
        #expect(model.phase == .idle)
    }

    @Test func checkIsIgnoredWithoutAnUpdater() {
        let model = UpdateModel(currentVersion: "1.0")
        var checks = 0
        model.requestCheck = { checks += 1 }
        model.perform(.check)
        #expect(checks == 0)
    }

    // MARK: Copy

    /// The time part follows the Mac's clock setting (12 or 24 hours), which overrides the
    /// locale, so the expected time is formatted the same way rather than written out.
    @Test func rowCaptions() throws {
        let (model, _) = makeModel()
        let locale = Locale(identifier: "en_GB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        calendar.locale = locale
        func time(_ date: Date) -> String {
            date.formatted(
                Date.FormatStyle(
                    date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        }
        func row() -> UpdateRowContent { model.row(now: now, locale: locale, calendar: calendar) }
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 15)))
        #expect(row().caption == "Not checked yet")
        #expect(row().title == "Version 1.0")
        model.lastChecked = now.addingTimeInterval(-30)
        #expect(row().caption == "Up to date \u{00B7} checked just now")
        #expect(row().spokenCaption == "Up to date, checked just now")
        let morning = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9, minute: 12)))
        model.lastChecked = morning
        #expect(row().caption == "Up to date \u{00B7} checked today at \(time(morning))")
        let evening = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 18, minute: 40)))
        model.lastChecked = evening
        #expect(row().caption == "Up to date \u{00B7} checked yesterday at \(time(evening))")
        #expect(row().shortCaption == "Up to date \u{00B7} checked yesterday")
        model.lastChecked = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 8))
        #expect(row().caption == "Up to date \u{00B7} checked on 12 Nov")
        #expect(row().button == "Check for updates")
        #expect(row().whatsNewAccessibilityLabel == "What's new in Drop 1.0")
    }

    /// Every state on the UpdatesInRow board: the line, the capsule and whether it's dimmed.
    @Test func rowStates() {
        let (model, _) = makeModel()
        func check(
            _ phase: UpdateModel.Phase, _ caption: String, _ button: String, primary: Bool = false,
            enabled: Bool = true, error: Bool = false, spinner: Bool = false, percent: Int? = nil,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            model.demo(phase, popup: false)
            let row = model.row()
            #expect(row.caption == caption, sourceLocation: sourceLocation)
            #expect(row.button == button, sourceLocation: sourceLocation)
            #expect((row.buttonKind == .primary) == primary, sourceLocation: sourceLocation)
            #expect(row.buttonEnabled == enabled, sourceLocation: sourceLocation)
            #expect(row.isError == error, sourceLocation: sourceLocation)
            #expect((row.lead == .spinner) == spinner, sourceLocation: sourceLocation)
            #expect(row.percent == percent, sourceLocation: sourceLocation)
        }
        check(.checking, "Checking for updates\u{2026}", "Check for updates", enabled: false, spinner: true)
        check(.available(update), "Version 1.1 is available", "Download")
        check(
            .downloading(update, fraction: 0.426), "Downloading 1.1", "Restart to update", primary: true,
            enabled: false, percent: 42)
        check(
            .downloading(update, fraction: nil), "Downloading 1.1\u{2026}", "Restart to update", primary: true,
            enabled: false)
        check(
            .preparing(update), "Preparing 1.1\u{2026}", "Restart to update", primary: true, enabled: false,
            spinner: true)
        check(.ready(update, afterLater: false), "Version 1.1 is ready", "Restart to update", primary: true)
        check(.ready(update, afterLater: true), "1.1 installs when Drop quits", "Restart to update", primary: true)
        check(
            .failed(.restart(update)), "Couldn't restart. It installs on quit.", "Restart to update", primary: true,
            error: true)
        check(
            .installing(update), "Installing 1.1\u{2026}", "Restart to update", primary: true, enabled: false,
            spinner: true)
        check(.failed(.check), "Couldn't check for updates.", "Try again", error: true)
        check(.failed(.download(update)), "Couldn't download 1.1.", "Try again", error: true)
        check(.failed(.verify(update)), "Couldn't verify 1.1.", "Try again", error: true)
        model.demo(.ready(update, afterLater: false), popup: false)
        #expect(model.row().whatsNewAccessibilityLabel == "What's new in Drop 1.1")
        #expect(model.row().buttonAccessibilityLabel == "Restart to update to Drop 1.1")
        model.demo(.available(update), popup: false)
        #expect(model.row().buttonAccessibilityLabel == "Download Drop 1.1")
        #expect(model.row().whatsNewAccessibilityLabel == "What's new in Drop 1.0")
        model.demo(.idle, popup: false)
        model.justUpdated = true
        #expect(model.row().caption == "Updated to 1.0")
    }

    @Test func captionWithoutAnUpdater() {
        let model = UpdateModel(currentVersion: "1.0")
        let row = model.row()
        #expect(row.caption == "Updates are off in test builds.")
        #expect(!row.buttonEnabled)
        #expect(!row.showsWhatsNew)
    }

    // MARK: Release notes

    @Test func releaseNotesFromAList() {
        let html = """
            <h2>Drop 1.1</h2>
            <ul>
              <li>Faster popups for <b>big</b> disk images</li>
              <li>Install to remembers your choice</li>
              <li>Fixes for licence screens &amp; passwords</li>
              <li>A fourth line nobody sees</li>
            </ul>
            """
        #expect(
            ReleaseNotes.lines(from: html) == [
                "Faster popups for big disk images", "Install to remembers your choice",
                "Fixes for licence screens & passwords", "A fourth line nobody sees",
            ], "every line: What's new shows them all")
        #expect(ReleaseNotes.lines(from: html, limit: ReleaseNotes.popupLimit).count == 3)
    }

    @Test func releaseNotesFromPlainLines() {
        let text = "- First change\n\n* Second change<br>Third change\nFourth"
        #expect(ReleaseNotes.lines(from: text) == ["First change", "Second change", "Third change", "Fourth"])
        #expect(ReleaseNotes.lines(from: nil).isEmpty)
        #expect(ReleaseNotes.lines(from: "").isEmpty)
    }

    // MARK: In-row updates (UpdatesInRow board)

    @Test func aCheckFromSettingsNeverRaisesThePopup() {
        let (model, recorder) = makeModel(automatic: false)
        model.perform(.check)
        model.checkStarted()
        model.found(update, downloaded: false, userInitiated: true) { recorder.replies.append($0) }
        #expect(model.phase == .available(update))
        #expect(!model.wantsPopup)
        model.perform(.download)
        model.downloadStarted()
        model.downloadProgressed(0.5)
        #expect(model.phase == .downloading(update, fraction: 0.5))
        model.preparing()
        #expect(model.phase == .preparing(update))
        model.readyToInstall { recorder.replies.append($0) }
        #expect(model.phase == .ready(update, afterLater: false))
        #expect(!model.wantsPopup, "the row shows Ready")
        model.perform(.restart)
        #expect(recorder.replies == [.install, .install])
    }

    @Test func progressChangesOncePerPercent() {
        let (model, _) = makeModel()
        model.demo(.downloading(update, fraction: nil), popup: false)
        model.downloadProgressed(0.421)
        model.downloadProgressed(0.429)
        #expect(model.phase == .downloading(update, fraction: 0.421))
        model.downloadProgressed(0.43)
        #expect(model.phase == .downloading(update, fraction: 0.43))
    }

    @Test func aBackgroundUpdateWhileSettingsIsOpenOnlyChangesTheRow() {
        let (model, recorder) = makeModel()
        model.settingsOpen = true
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        #expect(model.isReady)
        #expect(!model.wantsPopup)
    }

    @Test func openingSettingsClosesThePopupAndKeepsTheReply() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        #expect(model.wantsPopup)
        model.settingsOpen = true
        #expect(!model.wantsPopup)
        #expect(model.row().button == "Download")
        model.perform(.download)
        #expect(recorder.replies == [.install], "the row's Download answers the popup's prompt")
    }

    @Test func laterShowsInTheRow() {
        let (model, recorder) = makeModel()
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        model.perform(.later, from: .popup)
        #expect(model.phase == .ready(update, afterLater: true))
        #expect(model.row().caption == "1.1 installs when Drop quits")
    }

    @Test func aFailedCheckFromSettingsShowsAndRetries() {
        let (model, recorder) = makeModel()
        model.perform(.check)
        model.checkStarted()
        model.failed(Failure())
        #expect(model.phase == .failed(.check))
        model.cycleEnded()
        #expect(model.phase == .failed(.check), "stays until Try again")
        #expect(model.rowAction == .retry)
        model.perform(.retry)
        #expect(recorder.checks == 2)
        model.checkStarted()
        model.notFound()
        #expect(model.phase == .idle)
    }

    @Test func aFailedDownloadFromSettingsRetriesByCheckingThenDownloading() {
        let (model, recorder) = makeModel(automatic: false)
        model.perform(.check)
        model.found(update, downloaded: false, userInitiated: true) { recorder.replies.append($0) }
        model.perform(.download)
        model.downloadProgressed(0.3)
        model.failed(Failure())
        #expect(model.phase == .failed(.download(update)))
        model.perform(.retry)
        #expect(model.phase == .checking)
        model.found(update, downloaded: false, userInitiated: true) { recorder.replies.append($0) }
        #expect(recorder.replies == [.install, .install], "Try again downloads even with the switch off")
        #expect(model.phase == .downloading(update, fraction: nil))
    }

    @Test func aFailureWhilePreparingIsAVerifyFailure() {
        let (model, recorder) = makeModel()
        model.perform(.check)
        model.found(update, downloaded: false, userInitiated: true) { recorder.replies.append($0) }
        model.preparing()
        model.failed(Failure())
        #expect(model.phase == .failed(.verify(update)))
    }

    @Test func restartAfterLaterFailingOfflineShowsAndStaysPending() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        model.perform(.download, from: .popup)
        model.readyToInstall { recorder.replies.append($0) }
        model.perform(.later, from: .popup)
        model.cycleEnded()
        model.perform(.restart)
        #expect(model.phase == .installing(update))
        model.failed(Failure())
        #expect(model.phase == .failed(.restart(update)))
        #expect(model.isReady, "still installs on quit")
        #expect(model.row().caption == "Couldn't restart. It installs on quit.")
    }

    @Test func aBackgroundFailureStaysSilent() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        model.perform(.download, from: .popup)
        model.failed(Failure())
        #expect(model.phase == .idle)
    }

    @Test func whatsNewGroupsNewestFirst() {
        let (model, _) = makeModel()
        let bundled = [
            ReleaseNotesFile.Section(version: "1.2", lines: ["Not out yet"]),
            ReleaseNotesFile.Section(version: "1.1", lines: ["Pending, from the file"]),
            ReleaseNotesFile.Section(version: "1.0", lines: ["Installed line"]),
            ReleaseNotesFile.Section(version: "0.9", lines: ["Older", "Lines"]),
        ]
        #expect(
            model.releaseNoteGroups(bundled: bundled) == [
                ReleaseNoteGroup(version: "1.0", tag: "Installed", lines: ["Installed line"]),
                ReleaseNoteGroup(version: "0.9", tag: nil, lines: ["Older", "Lines"]),
            ])
        model.demo(.ready(update, afterLater: false), popup: false)
        #expect(
            model.releaseNoteGroups(bundled: bundled).first
                == ReleaseNoteGroup(version: "1.1", tag: "Ready to install", lines: ["One", "Two"]))
        #expect(model.releaseNoteGroups(bundled: bundled).count == 3)
        model.demo(.available(update), popup: false)
        #expect(model.releaseNoteGroups(bundled: bundled).first?.tag == nil)
        #expect(model.releaseNoteGroups(bundled: []).count == 1)
    }

    @Test func releaseNotesFileSections() {
        let text = """
            # Release notes

            The intro, with a - dash inside.

            ## 1.0.6

            - Settings shows an update in the version row
            - What's new opens from Settings

            ## 1.0.5

            - One line
            """
        #expect(
            ReleaseNotesFile.parse(text) == [
                .init(
                    version: "1.0.6",
                    lines: ["Settings shows an update in the version row", "What's new opens from Settings"]),
                .init(version: "1.0.5", lines: ["One line"]),
            ])
        #expect(ReleaseNotesFile.isNewer("1.0.10", than: "1.0.9"))
        #expect(!ReleaseNotesFile.isNewer("1.0", than: "1.0.0"))
    }

    @Test func updatedNoticeLastsUntilSettingsWasOpen() throws {
        let suite = "dev.niduslabs.drop.lastrun-test"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!LastRunVersion.launched("1.0.5", defaults: defaults, hasRunBefore: false), "a fresh install")
        #expect(!LastRunVersion.launched("1.0.5", defaults: defaults, hasRunBefore: true))
        #expect(LastRunVersion.launched("1.0.6", defaults: defaults, hasRunBefore: true))
        #expect(LastRunVersion.launched("1.0.6", defaults: defaults, hasRunBefore: true), "until Settings opens")
        LastRunVersion.noticeSeen(defaults: defaults)
        #expect(!LastRunVersion.launched("1.0.6", defaults: defaults, hasRunBefore: true))
        defaults.removeObject(forKey: LastRunVersion.versionKey)
        #expect(LastRunVersion.launched("1.0.7", defaults: defaults, hasRunBefore: true), "from a copy before 1.0.6")
    }
}
